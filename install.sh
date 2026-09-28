#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly MARKER_CONTENT='airreload-installer-v1'
readonly PATH_BEGIN='# >>> airreload installer >>>'
readonly PATH_END='# <<< airreload installer <<<'
readonly SHELL_PATH_REFERENCE="\$PATH"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
manifest="$script_dir/versions.env"
replace=0
setup_path=1
preserve_data=0
lock_dir=''
preserved_paths=()
stage_dir=''
backup_dir=''
rollback_dir=''
committed=0
profile_paths=()
profile_existed=()
profile_backups=()

usage() {
  cat <<'EOF'
Usage: ./install.sh [--replace] [--no-path] [--preserve-data]

  --replace  Replace an installation created by this installer.
  --no-path  Do not add the Airreload launcher directory to shell profiles.
  --preserve-data  Keep pairing state and downloaded SDKs during replacement.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

manifest_value() {
  local key=$1 file=${2:-$manifest}
  awk -F= -v key="$key" '
    $1 == key { count++; value = substr($0, length(key) + 2) }
    END { if (count != 1) exit 1; print value }
  ' "$file"
}

validate_root() {
  local candidate=$1
  [[ "$candidate" == /* ]] || die 'AIRRELOAD_INSTALL_ROOT must be an absolute path.'
  [[ "$candidate" != '/' ]] || die 'Refusing to use the filesystem root.'
  [[ "$candidate" =~ ^/[A-Za-z0-9._/-]+$ ]] || die 'The installation path contains unsupported characters.'
  [[ "/$candidate/" != *'/../'* && "/$candidate/" != *'/./'* ]] || die 'The installation path may not contain . or .. components.'
  [[ ! -L "$candidate" ]] || die 'The installation root may not be a symbolic link.'
}

is_owned_dir() {
  local target=$1
  [[ -d "$target" && ! -L "$target" && -f "$target/.airreload-installer" ]] || return 1
  [[ $(<"$target/.airreload-installer") == "$MARKER_CONTENT" ]]
}

remove_owned_dir() {
  local target=$1
  [[ -n "$target" && "$target" == /* && "$target" != '/' ]] || die "Refusing to remove unsafe path: $target"
  is_owned_dir "$target" || die "Refusing to remove unowned directory: $target"
  rm -rf -- "$target"
}

restore_profiles() {
  local index profile
  for ((index = ${#profile_paths[@]} - 1; index >= 0; index--)); do
    profile=${profile_paths[$index]}
    if [[ ${profile_existed[$index]} == 1 ]]; then
      cp -p -- "${profile_backups[$index]}" "$profile"
    else
      rm -f -- "$profile"
    fi
  done
}

cleanup() {
  local status=$? relative index
  trap - EXIT
  if ((status != 0)); then
    restore_profiles || true
    if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
      for ((index = 0; index < ${#preserved_paths[@]}; index++)); do
        relative=${preserved_paths[$index]}
        if [[ -e "$install_root/$relative" && ! -e "$backup_dir/$relative" ]]; then
          if ! mv -- "$install_root/$relative" "$backup_dir/$relative"; then
            printf 'Rollback could not restore %s. Keeping both %s and %s for recovery.\n' "$relative" "$install_root" "$backup_dir" >&2
            if [[ -n "$lock_dir" ]]; then rmdir -- "$lock_dir" || true; fi
            exit "$status"
          fi
        fi
      done
    fi
    if ((committed == 1)) && is_owned_dir "$install_root"; then
      remove_owned_dir "$install_root" || true
    fi
    if [[ -n "$backup_dir" && -d "$backup_dir" && ! -e "$install_root" ]]; then
      mv -- "$backup_dir" "$install_root" || true
      backup_dir=''
    fi
  fi
  if [[ -n "$stage_dir" && -d "$stage_dir" ]] && is_owned_dir "$stage_dir"; then
    remove_owned_dir "$stage_dir" || true
  fi
  if [[ -n "$rollback_dir" && -d "$rollback_dir" ]]; then
    rm -rf -- "$rollback_dir"
  fi
  if [[ -n "$lock_dir" ]]; then rmdir -- "$lock_dir" || true; fi
  exit "$status"
}

download() {
  curl --fail --location --silent --show-error --retry 3 \
    --connect-timeout 15 --max-time 300 --proto '=https' --proto-redir '=https' \
    --output "$2" "$1"
}

install_binary() {
  local destination=$1 actual_hash
  local asset='airreload-macos-arm64'
  local release_url="https://github.com/Airreload/cli/releases/download/$cli_tag"
  download "$release_url/$asset" "$destination"
  actual_hash=$(shasum -a 256 "$destination")
  actual_hash=${actual_hash%% *}
  [[ "$actual_hash" == "$cli_sha256" ]] || die 'Airreload binary checksum mismatch.'
  chmod 0755 "$destination"
}

validate_installation() {
  local root=$1 version
  version=$(AIRRELOAD_WORKSPACE="$root" AIRRELOAD_NO_UPDATE_CHECK=1 "$root/bin/airreload" version) || die 'CLI version validation failed.'
  [[ "$version" == "Airreload ${cli_tag#v}" ]] || die "Unexpected CLI version: $version"
  printf '%s\n' "$version"
  AIRRELOAD_WORKSPACE="$root" AIRRELOAD_NO_UPDATE_CHECK=1 "$root/bin/airreload" --help >/dev/null
}

profile_files() {
  if [[ -n ${AIRRELOAD_TEST_PROFILE_FILE:-} ]]; then
    [[ ${AIRRELOAD_TEST_PROFILE_FILE} == /* ]] || die 'AIRRELOAD_TEST_PROFILE_FILE must be an absolute path.'
    printf '%s\n' "$AIRRELOAD_TEST_PROFILE_FILE"
  else
    printf '%s\n' "$HOME/.zprofile" "$HOME/.bash_profile"
  fi
}

update_profile() {
  local profile=$1
  local profile_dir temp filtered backup index
  [[ ! -L "$profile" ]] || die "Refusing to edit symbolic-link profile: $profile"
  profile_dir=$(dirname -- "$profile")
  [[ -d "$profile_dir" ]] || die "Profile directory does not exist: $profile_dir"
  temp=$(mktemp "$profile_dir/.airreload-profile.XXXXXX")
  filtered="$temp.filtered"
  index=${#profile_paths[@]}
  backup="$rollback_dir/profile-$index"
  profile_paths+=("$profile")
  profile_backups+=("$backup")

  if [[ -f "$profile" ]]; then
    profile_existed+=(1)
    cp -p -- "$profile" "$backup"
    cp -p -- "$profile" "$temp"
  else
    profile_existed+=(0)
    : >"$temp"
  fi

  awk -v begin="$PATH_BEGIN" -v end="$PATH_END" '
    $0 == begin { if (skipping) exit 2; skipping = 1; next }
    $0 == end { if (!skipping) exit 2; skipping = 0; next }
    !skipping { print }
    END { if (skipping) exit 2 }
  ' "$temp" >"$filtered" || die "Malformed Airreload PATH block in $profile."
  cat "$filtered" >"$temp"
  rm -f -- "$filtered"
  if [[ -s "$temp" ]]; then
    printf '\n' >>"$temp"
  fi
  printf '%s\nexport PATH="%s/bin:%s"\n%s\n' "$PATH_BEGIN" "$install_root" "$SHELL_PATH_REFERENCE" "$PATH_END" >>"$temp"
  mv -f -- "$temp" "$profile"
}

while (($# > 0)); do
  case $1 in
    --replace) replace=1 ;;
    --no-path) setup_path=0 ;;
    --preserve-data) preserve_data=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

[[ $(uname -s) == Darwin ]] || die 'Airreload currently supports macOS only.'
[[ $(uname -m) == arm64 ]] || die 'Airreload currently supports Apple Silicon (arm64) only.'
for prerequisite in curl shasum; do
  command -v "$prerequisite" >/dev/null 2>&1 || die "Required command not found: $prerequisite"
done
[[ -f "$manifest" ]] || die "Version manifest not found: $manifest"

cli_repository=$(manifest_value CLI_REPOSITORY) || die 'Invalid CLI_REPOSITORY in versions.env.'
cli_tag=$(manifest_value CLI_TAG) || die 'Invalid CLI_TAG in versions.env.'
cli_commit=$(manifest_value CLI_COMMIT) || die 'Invalid CLI_COMMIT in versions.env.'
cli_sha256=$(manifest_value CLI_SHA256_MACOS_ARM64) || die 'Invalid CLI_SHA256_MACOS_ARM64 in versions.env.'
[[ "$cli_repository" == 'https://github.com/Airreload/cli.git' ]] || die 'Unexpected CLI repository in versions.env.'
[[ "$cli_tag" =~ ^v[0-9A-Za-z.+-]+$ ]] || die 'Invalid CLI release tag in versions.env.'
[[ "$cli_commit" =~ ^[0-9a-f]{40}$ ]] || die 'Invalid CLI commit in versions.env.'
[[ "$cli_sha256" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid binary SHA-256 checksum in versions.env.'

install_root=${AIRRELOAD_INSTALL_ROOT:-"$HOME/.airreload"}
validate_root "$install_root"
install_parent=$(dirname -- "$install_root")
mkdir -p -- "$install_parent"

lock_candidate="$install_parent/.$(basename -- "$install_root").install-lock"
mkdir -- "$lock_candidate" 2>/dev/null || die "Another installation is in progress (lock: $lock_candidate)."
lock_dir=$lock_candidate
trap cleanup EXIT

if [[ -e "$install_root" ]]; then
  ((replace == 1)) || die "$install_root already exists. Re-run with --replace to replace an installer-owned installation."
  is_owned_dir "$install_root" || die "$install_root is not owned by the Airreload installer; it was not changed."
fi

stage_dir=$(mktemp -d "$install_parent/.airreload-install.XXXXXX")
printf '%s\n' "$MARKER_CONTENT" >"$stage_dir/.airreload-installer"
trap cleanup EXIT
rollback_dir=$(mktemp -d "$install_parent/.airreload-rollback.XXXXXX")

printf 'Installing Airreload into %s\n' "$install_root"
printf 'Downloading Airreload %s...\n' "$cli_tag"
# Keep the state parent for upgrades from source-based installations.
mkdir -p -- "$stage_dir/bin" "$stage_dir/cli"
install_binary "$stage_dir/bin/airreload"

printf 'Validating staged installation...\n'
validate_installation "$stage_dir"

if [[ -e "$install_root" ]]; then
  backup_dir=$(mktemp -d "$install_parent/.airreload-backup.XXXXXX")
  rmdir -- "$backup_dir"
  mv -- "$install_root" "$backup_dir"
fi
mv -- "$stage_dir" "$install_root"
stage_dir=''
committed=1

if ((preserve_data == 1)) && [[ -n "$backup_dir" ]]; then
  for relative in cli/.airreload sdks; do
    if [[ -e "$backup_dir/$relative" || -L "$backup_dir/$relative" ]]; then
      [[ -d "$backup_dir/$relative" && ! -L "$backup_dir/$relative" ]] || die "Refusing to preserve non-directory data: $relative"
      [[ ! -e "$install_root/$relative" ]] || die "Staged release unexpectedly contains user data: $relative"
      preserved_paths+=("$relative")
      mv -- "$backup_dir/$relative" "$install_root/$relative"
    fi
  done
fi

if ((setup_path == 1)); then
  while IFS= read -r profile; do
    update_profile "$profile"
  done < <(profile_files)
fi

printf 'Validating installed command...\n'
validate_installation "$install_root"

if [[ -n "$backup_dir" ]]; then
  remove_owned_dir "$backup_dir"
  backup_dir=''
fi
committed=0
rm -rf -- "$rollback_dir"
rollback_dir=''
rmdir -- "$lock_dir"
lock_dir=''
trap - EXIT

printf '\nAirreload is installed.\n'
if ((setup_path == 1)); then
  printf 'Open a new terminal, then run: airreload doctor\n'
else
  printf 'Run: %s/bin/airreload doctor\n' "$install_root"
fi

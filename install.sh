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
stage_dir=''
backup_dir=''
rollback_dir=''
committed=0
profile_paths=()
profile_existed=()
profile_backups=()

usage() {
  cat <<'EOF'
Usage: ./install.sh [--replace] [--no-path]

  --replace  Replace an installation created by this installer.
  --no-path  Do not add the Airreload launcher directory to shell profiles.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

manifest_value() {
  local key=$1
  awk -F= -v key="$key" '
    $1 == key { count++; value = substr($0, length(key) + 2) }
    END { if (count != 1) exit 1; print value }
  ' "$manifest"
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
  local status=$?
  trap - EXIT
  if ((status != 0)); then
    restore_profiles || true
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
  exit "$status"
}

clone_at_release() {
  local repository=$1
  local tag=$2
  local expected_commit=$3
  local destination=$4
  local depth=$5
  local actual_commit

  git clone --quiet --filter=blob:none --depth "$depth" --single-branch --branch "$tag" -- "$repository" "$destination"
  actual_commit=$(git -C "$destination" rev-parse HEAD)
  [[ "$actual_commit" == "$expected_commit" ]] || die "$repository tag $tag resolved to $actual_commit, expected $expected_commit."
}

write_launcher() {
  local launcher=$1
  cat >"$launcher" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
exec "$root/flutter/bin/dart" \
  "--packages=$root/cli/.dart_tool/package_config.json" \
  "$root/cli/bin/airreload.dart" "$@"
EOF
  chmod 0755 "$launcher"
}

validate_installation() {
  local root=$1
  local flutter_version
  flutter_version=$("$root/flutter/bin/flutter" --version --machine) || die 'Flutter version validation failed.'
  grep -Eq '"frameworkVersion"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+[^"[:space:]]*"' <<<"$flutter_version" || die 'Flutter returned an invalid framework version.'
  if grep -Eq '"frameworkVersion"[[:space:]]*:[[:space:]]*"0\.0\.0-unknown"' <<<"$flutter_version"; then
    die 'Flutter could not determine its framework version. The release clone is missing its numeric base tag.'
  fi
  "$root/bin/airreload" version
  "$root/bin/airreload" --help >/dev/null
  "$root/bin/airreload" doctor
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
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

[[ $(uname -s) == Darwin ]] || die 'Airreload currently supports macOS only.'
[[ $(uname -m) == arm64 ]] || die 'Airreload currently supports Apple Silicon (arm64) only.'
for prerequisite in git openssl curl unzip; do
  command -v "$prerequisite" >/dev/null 2>&1 || die "Required command not found: $prerequisite"
done
[[ -f "$manifest" ]] || die "Version manifest not found: $manifest"

cli_repository=$(manifest_value CLI_REPOSITORY) || die 'Invalid CLI_REPOSITORY in versions.env.'
cli_tag=$(manifest_value CLI_TAG) || die 'Invalid CLI_TAG in versions.env.'
cli_commit=$(manifest_value CLI_COMMIT) || die 'Invalid CLI_COMMIT in versions.env.'
flutter_repository=$(manifest_value FLUTTER_REPOSITORY) || die 'Invalid FLUTTER_REPOSITORY in versions.env.'
flutter_tag=$(manifest_value FLUTTER_TAG) || die 'Invalid FLUTTER_TAG in versions.env.'
flutter_commit=$(manifest_value FLUTTER_COMMIT) || die 'Invalid FLUTTER_COMMIT in versions.env.'
[[ "$cli_repository" == 'https://github.com/Airreload/cli.git' ]] || die 'Unexpected CLI repository in versions.env.'
[[ "$flutter_repository" == 'https://github.com/Airreload/flutter.git' ]] || die 'Unexpected Flutter repository in versions.env.'
[[ "$cli_tag" =~ ^[A-Za-z0-9._-]+$ && "$flutter_tag" =~ ^[A-Za-z0-9._-]+$ ]] || die 'Invalid release tag in versions.env.'
[[ "$cli_commit" =~ ^[0-9a-f]{40}$ && "$flutter_commit" =~ ^[0-9a-f]{40}$ ]] || die 'Invalid commit in versions.env.'

install_root=${AIRRELOAD_INSTALL_ROOT:-"$HOME/.airreload"}
validate_root "$install_root"
install_parent=$(dirname -- "$install_root")
mkdir -p -- "$install_parent"

if [[ -e "$install_root" ]]; then
  ((replace == 1)) || die "$install_root already exists. Re-run with --replace to replace an installer-owned installation."
  is_owned_dir "$install_root" || die "$install_root is not owned by the Airreload installer; it was not changed."
fi

stage_dir=$(mktemp -d "$install_parent/.airreload-install.XXXXXX")
printf '%s\n' "$MARKER_CONTENT" >"$stage_dir/.airreload-installer"
trap cleanup EXIT
rollback_dir=$(mktemp -d "$install_parent/.airreload-rollback.XXXXXX")

printf 'Installing Airreload into %s\n' "$install_root"
printf 'Cloning CLI %s...\n' "$cli_tag"
clone_at_release "$cli_repository" "$cli_tag" "$cli_commit" "$stage_dir/cli" 1
printf 'Cloning Flutter %s...\n' "$flutter_tag"
clone_at_release "$flutter_repository" "$flutter_tag" "$flutter_commit" "$stage_dir/flutter" 2

printf 'Bootstrapping Flutter and Dart...\n'
"$stage_dir/flutter/bin/flutter" --version
(
  cd -- "$stage_dir/cli"
  "$stage_dir/flutter/bin/dart" pub get
)
mkdir -p -- "$stage_dir/bin"
write_launcher "$stage_dir/bin/airreload"

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
trap - EXIT

printf '\nAirreload is installed.\n'
if ((setup_path == 1)); then
  printf 'Open a new terminal, then run: airreload doctor\n'
else
  printf 'Run: %s/bin/airreload doctor\n' "$install_root"
fi

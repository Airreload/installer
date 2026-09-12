#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly MARKER_CONTENT='airreload-installer-v1'
readonly PATH_BEGIN='# >>> airreload installer >>>'
readonly PATH_END='# <<< airreload installer <<<'
assume_yes=0

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--yes]

  --yes  Do not ask for interactive confirmation.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

validate_root() {
  local candidate=$1
  [[ "$candidate" == /* && "$candidate" != '/' ]] || die 'Refusing to use an unsafe installation path.'
  [[ "$candidate" =~ ^/[A-Za-z0-9._/-]+$ ]] || die 'The installation path contains unsupported characters.'
  [[ "/$candidate/" != *'/../'* && "/$candidate/" != *'/./'* ]] || die 'The installation path may not contain . or .. components.'
  [[ ! -L "$candidate" ]] || die 'The installation root may not be a symbolic link.'
}

is_owned_dir() {
  local target=$1
  [[ -d "$target" && ! -L "$target" && -f "$target/.airreload-installer" ]] || return 1
  [[ $(<"$target/.airreload-installer") == "$MARKER_CONTENT" ]]
}

profile_files() {
  if [[ -n ${AIRRELOAD_TEST_PROFILE_FILE:-} ]]; then
    [[ ${AIRRELOAD_TEST_PROFILE_FILE} == /* ]] || die 'AIRRELOAD_TEST_PROFILE_FILE must be an absolute path.'
    printf '%s\n' "$AIRRELOAD_TEST_PROFILE_FILE"
  else
    printf '%s\n' "$HOME/.zprofile" "$HOME/.bash_profile"
  fi
}

remove_path_block() {
  local profile=$1
  local profile_dir temp
  [[ -e "$profile" ]] || return 0
  [[ -f "$profile" && ! -L "$profile" ]] || die "Refusing to edit non-regular profile: $profile"
  profile_dir=$(dirname -- "$profile")
  temp=$(mktemp "$profile_dir/.airreload-profile.XXXXXX")
  cp -p -- "$profile" "$temp"
  awk -v begin="$PATH_BEGIN" -v end="$PATH_END" '
    $0 == begin { if (skipping) exit 2; skipping = 1; next }
    $0 == end { if (!skipping) exit 2; skipping = 0; next }
    !skipping { print }
    END { if (skipping) exit 2 }
  ' "$profile" >"$temp.content" || {
    rm -f -- "$temp" "$temp.content"
    die "Malformed Airreload PATH block in $profile."
  }
  cat "$temp.content" >"$temp"
  rm -f -- "$temp.content"
  mv -f -- "$temp" "$profile"
}

while (($# > 0)); do
  case $1 in
    --yes) assume_yes=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

install_root=${AIRRELOAD_INSTALL_ROOT:-"$HOME/.airreload"}
validate_root "$install_root"

if [[ -e "$install_root" ]] && ! is_owned_dir "$install_root"; then
  die "$install_root is not owned by the Airreload installer; it was not changed."
fi

if ((assume_yes == 0)) && [[ -t 0 ]]; then
  printf 'Remove the installer-owned Airreload directory at %s? [y/N] ' "$install_root"
  read -r answer
  [[ "$answer" == y || "$answer" == Y ]] || {
    printf 'Uninstall cancelled.\n'
    exit 0
  }
fi

while IFS= read -r profile; do
  remove_path_block "$profile"
done < <(profile_files)

if [[ -d "$install_root" ]]; then
  rm -rf -- "$install_root"
  printf 'Removed %s and its marked shell PATH entries.\n' "$install_root"
else
  printf 'No Airreload installation found; removed any marked shell PATH entries.\n'
fi

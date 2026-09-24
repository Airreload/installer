#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# Read expected identities from the release manifest so tests follow releases.
source "$repo_root/versions.env"
export AIRRELOAD_EXPECTED_CLI_COMMIT="$CLI_COMMIT"
export AIRRELOAD_EXPECTED_FLUTTER_COMMIT="$FLUTTER_COMMIT"
export AIRRELOAD_EXPECTED_CLI_VERSION="${CLI_TAG#v}"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/airreload-installer-tests.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fake_bin="$test_root/fake-bin"
install_root="$test_root/install"
profile="$test_root/profile"
mkdir -p -- "$fake_bin"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_contains() {
  grep -F -- "$2" "$1" >/dev/null || fail "expected $1 to contain: $2"
}

assert_count() {
  local expected=$1 file=$2 text=$3 actual
  actual=$(grep -F -c -- "$text" "$file" || true)
  [[ "$actual" == "$expected" ]] || fail "expected $expected occurrences of '$text' in $file, found $actual"
}

cat >"$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == -s ]]; then printf '%s\n' "${FAKE_UNAME_S:-Darwin}"; else printf '%s\n' "${FAKE_UNAME_M:-arm64}"; fi
EOF

cat >"$fake_bin/openssl" <<'EOF'
#!/usr/bin/env bash
printf 'OpenSSL fake\n'
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fake_bin/unzip" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == clone ]]; then
  depth=''
  previous=''
  for argument in "$@"; do
    if [[ $previous == --depth ]]; then depth=$argument; fi
    previous=$argument
    destination=$argument
  done
  if [[ "$destination" == */flutter && $depth != 2 ]]; then
    printf 'Flutter clone depth must be 2, found %s\n' "$depth" >&2
    exit 2
  fi
  if [[ "$destination" == */cli && $depth != 1 ]]; then
    printf 'CLI clone depth must be 1, found %s\n' "$depth" >&2
    exit 2
  fi
  mkdir -p "$destination/bin"
  if [[ "$destination" == */flutter ]]; then
    cat >"$destination/bin/flutter" <<'FLUTTER'
#!/usr/bin/env bash
if [[ ${1:-} == --version && ${2:-} == --machine ]]; then
  printf '{"frameworkVersion":"%s"}\n' "${FAKE_FLUTTER_FRAMEWORK_VERSION:-3.47.5}"
elif [[ ${1:-} == attach && ${2:-} == --help ]]; then
  printf 'Usage: flutter attach --airreload\n'
else
  printf 'Flutter 3.47.5 (fake)\n'
fi
FLUTTER
    cat >"$destination/bin/dart" <<'DART'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == pub && ${2:-} == get ]]; then
  mkdir -p .dart_tool
  printf '{}\n' >.dart_tool/package_config.json
  exit 0
fi
command_name=''
for argument in "$@"; do command_name=$argument; done
case $command_name in
  version) printf 'Airreload %s\n' "$AIRRELOAD_EXPECTED_CLI_VERSION" ;;
  --help) printf 'Build and hot reload a Flutter Android app.\n' ;;
  doctor)
    if [[ ${FAKE_DART_FAIL_DOCTOR:-0} == 1 ]]; then exit 1; fi
    if [[ ${FAKE_DART_FAIL_FINAL_DOCTOR:-0} == 1 && "$2" != *'.airreload-install.'* ]]; then exit 1; fi
    printf 'OK  fake doctor\n'
    ;;
  *) printf 'unexpected fake Dart invocation: %s\n' "$*" >&2; exit 2 ;;
esac
DART
    chmod +x "$destination/bin/flutter" "$destination/bin/dart"
  else
    cat >"$destination/bin/airreload.dart" <<'DART_SOURCE'
void main() {}
DART_SOURCE
  fi
  exit 0
fi
if [[ $1 == -C && $3 == rev-parse && $4 == HEAD ]]; then
  if [[ $2 == */cli ]]; then
    printf '%s\n' "${FAKE_CLI_COMMIT:-$AIRRELOAD_EXPECTED_CLI_COMMIT}"
  else
    printf '%s\n' "$AIRRELOAD_EXPECTED_FLUTTER_COMMIT"
  fi
  exit 0
fi
printf 'unexpected fake git invocation: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$fake_bin"/*

run_install() {
  PATH="$fake_bin:/usr/bin:/bin" \
    AIRRELOAD_INSTALL_ROOT="$install_root" \
    AIRRELOAD_TEST_PROFILE_FILE="$profile" \
    bash "$repo_root/install.sh" "$@"
}

run_uninstall() {
  PATH="$fake_bin:/usr/bin:/bin" \
    AIRRELOAD_INSTALL_ROOT="$install_root" \
    AIRRELOAD_TEST_PROFILE_FILE="$profile" \
    bash "$repo_root/uninstall.sh" --yes
}

printf 'keep-before\n' >"$profile"
run_install
assert_file "$install_root/.airreload-installer"
assert_file "$install_root/bin/airreload"
assert_file "$install_root/cli/.dart_tool/package_config.json"
assert_contains "$profile" '# >>> airreload installer >>>'
assert_count 1 "$profile" '# >>> airreload installer >>>'
"$install_root/bin/airreload" version | grep -F "$AIRRELOAD_EXPECTED_CLI_VERSION" >/dev/null

if run_install >/dev/null 2>&1; then
  fail 'install without --replace unexpectedly succeeded'
fi
run_install --replace >/dev/null
assert_count 1 "$profile" '# >>> airreload installer >>>'

mkdir -p "$install_root/cli/.airreload" "$install_root/sdks/cached-sdk"
printf 'private-key-fixture\n' >"$install_root/cli/.airreload/host-key.pem"
printf 'sdk-fixture\n' >"$install_root/sdks/cached-sdk/sentinel"
cp "$profile" "$test_root/profile-before-update"
run_install --replace --no-path --preserve-data >/dev/null
assert_contains "$install_root/cli/.airreload/host-key.pem" 'private-key-fixture'
assert_contains "$install_root/sdks/cached-sdk/sentinel" 'sdk-fixture'
cmp "$profile" "$test_root/profile-before-update" || fail 'update changed shell profile'
if FAKE_DART_FAIL_FINAL_DOCTOR=1 run_install --replace --no-path --preserve-data >/dev/null 2>&1; then
  fail 'failed preserving update unexpectedly succeeded'
fi
assert_contains "$install_root/cli/.airreload/host-key.pem" 'private-key-fixture'
assert_contains "$install_root/sdks/cached-sdk/sentinel" 'sdk-fixture'
# Fail after the first preserved directory moved; rollback must return it.
mv "$install_root/sdks" "$test_root/cached-sdks"
ln -s "$test_root/cached-sdks" "$install_root/sdks"
if run_install --replace --no-path --preserve-data >/dev/null 2>&1; then
  fail 'symlink SDK preservation unexpectedly succeeded'
fi
assert_contains "$install_root/cli/.airreload/host-key.pem" 'private-key-fixture'
assert_contains "$test_root/cached-sdks/cached-sdk/sentinel" 'sdk-fixture'
rm "$install_root/sdks"
mv "$test_root/cached-sdks" "$install_root/sdks"
# A concurrent replacement must not disturb the existing installation.
mkdir "$test_root/.install.install-lock"
if run_install --replace >/dev/null 2>&1; then
  fail 'concurrent replacement unexpectedly succeeded'
fi
assert_file "$install_root/cli/.airreload/host-key.pem"
rmdir "$test_root/.install.install-lock"

printf 'preserve-me\n' >"$install_root/preserved"
if FAKE_DART_FAIL_DOCTOR=1 run_install --replace >/dev/null 2>&1; then
  fail 'failing staged doctor unexpectedly succeeded'
fi
assert_file "$install_root/preserved"

if FAKE_DART_FAIL_FINAL_DOCTOR=1 run_install --replace >/dev/null 2>&1; then
  fail 'failing final doctor unexpectedly succeeded'
fi
assert_file "$install_root/preserved"
assert_contains "$profile" 'keep-before'
assert_count 1 "$profile" '# >>> airreload installer >>>'

if FAKE_FLUTTER_FRAMEWORK_VERSION=0.0.0-unknown run_install --replace >/dev/null 2>&1; then
  fail 'unknown Flutter framework version unexpectedly passed validation'
fi
assert_file "$install_root/preserved"
assert_contains "$profile" 'keep-before'
assert_count 1 "$profile" '# >>> airreload installer >>>'

run_uninstall >/dev/null
assert_not_exists "$install_root"
assert_contains "$profile" 'keep-before'
assert_count 0 "$profile" '# >>> airreload installer >>>'

mkdir -p "$install_root"
printf 'unrelated\n' >"$install_root/sentinel"
if run_install --replace >/dev/null 2>&1; then
  fail 'replacement of an unowned directory unexpectedly succeeded'
fi
assert_file "$install_root/sentinel"
if run_uninstall >/dev/null 2>&1; then
  fail 'uninstall of an unowned directory unexpectedly succeeded'
fi
assert_file "$install_root/sentinel"
rm -rf -- "$install_root"

if FAKE_CLI_COMMIT=0000000000000000000000000000000000000000 run_install >/dev/null 2>&1; then
  fail 'commit mismatch unexpectedly succeeded'
fi
assert_not_exists "$install_root"

if FAKE_UNAME_S=Linux run_install >/dev/null 2>&1; then
  fail 'unsupported platform unexpectedly succeeded'
fi
assert_not_exists "$install_root"

printf 'All installer tests passed.\n'

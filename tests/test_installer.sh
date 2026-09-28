#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# Read expected identities from the release manifest so tests follow releases.
# The manifest path is resolved from the script's location at runtime.
# shellcheck disable=SC1091
source "$repo_root/versions.env"
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

# Exercise the real SHA-256 verification with a small executable fixture.
export AIRRELOAD_TEST_BINARY="$test_root/airreload-fixture"
cat >"$AIRRELOAD_TEST_BINARY" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
  version) printf 'Airreload %s\n' "${FAKE_CLI_VERSION:-$AIRRELOAD_EXPECTED_CLI_VERSION}" ;;
  --help)
    if [[ ${FAKE_CLI_FAIL_HELP:-0} == 1 ]]; then exit 1; fi
    if [[ ${FAKE_CLI_FAIL_FINAL_HELP:-0} == 1 && "$0" != *'.airreload-install.'* ]]; then exit 1; fi
    printf 'Build and hot reload a Flutter Android app.\n'
    ;;
  *) printf 'unexpected CLI invocation: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${FAKE_DOWNLOAD_FAIL:-0} == 1 ]]; then exit 22; fi
previous=''
for argument in "$@"; do
  if [[ $previous == --output ]]; then destination=$argument; fi
  previous=$argument
  url=$argument
 done
[[ "$url" == "https://github.com/Airreload/cli/releases/download/v$AIRRELOAD_EXPECTED_CLI_VERSION/airreload-macos-arm64" ]]
cp "$AIRRELOAD_TEST_BINARY" "$destination"
if [[ ${FAKE_CORRUPT_DOWNLOAD:-0} == 1 ]]; then printf 'corrupt' >>"$destination"; fi
EOF
for tool in git dart flutter; do
  cat >"$fake_bin/$tool" <<'EOF'
#!/usr/bin/env bash
printf 'Installer must not invoke Git, Dart, or Flutter.\n' >&2
exit 99
EOF
 done
fixture_repo="$test_root/installer"
mkdir -p "$fixture_repo"
cp "$repo_root/install.sh" "$repo_root/uninstall.sh" "$fixture_repo/"
awk '!/^CLI_SHA256_/' "$repo_root/versions.env" >"$fixture_repo/versions.env"
fixture_hash=$(shasum -a 256 "$AIRRELOAD_TEST_BINARY")
printf 'CLI_SHA256_MACOS_ARM64=%s\n' "${fixture_hash%% *}" >>"$fixture_repo/versions.env"
repo_root=$fixture_repo
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
assert_not_exists "$install_root/cli/.dart_tool"
assert_not_exists "$install_root/flutter"
assert_not_exists "$install_root/sdks"
assert_contains "$profile" '# >>> airreload installer >>>'
assert_count 1 "$profile" '# >>> airreload installer >>>'
"$install_root/bin/airreload" version | grep -F "$AIRRELOAD_EXPECTED_CLI_VERSION" >/dev/null

if run_install >/dev/null 2>&1; then
  fail 'install without --replace unexpectedly succeeded'
fi
run_install --replace >/dev/null
assert_count 1 "$profile" '# >>> airreload installer >>>'

mkdir -p "$install_root/cli/.airreload" "$install_root/sdks/cached-sdk" "$install_root/flutter" "$install_root/cli/.dart_tool"
printf 'private-key-fixture\n' >"$install_root/cli/.airreload/host-key.pem"
printf 'sdk-fixture\n' >"$install_root/sdks/cached-sdk/sentinel"
cp "$profile" "$test_root/profile-before-update"
run_install --replace --no-path --preserve-data >/dev/null
assert_not_exists "$install_root/flutter"
assert_not_exists "$install_root/cli/.dart_tool"
assert_contains "$install_root/cli/.airreload/host-key.pem" 'private-key-fixture'
assert_contains "$install_root/sdks/cached-sdk/sentinel" 'sdk-fixture'
cmp "$profile" "$test_root/profile-before-update" || fail 'update changed shell profile'
if FAKE_CLI_FAIL_FINAL_HELP=1 run_install --replace --no-path --preserve-data >/dev/null 2>&1; then
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
if FAKE_CLI_FAIL_HELP=1 run_install --replace >/dev/null 2>&1; then
  fail 'failing staged help unexpectedly succeeded'
fi
assert_file "$install_root/preserved"

if FAKE_CLI_FAIL_FINAL_HELP=1 run_install --replace >/dev/null 2>&1; then
  fail 'failing final help unexpectedly succeeded'
fi
assert_file "$install_root/preserved"
assert_contains "$profile" 'keep-before'
assert_count 1 "$profile" '# >>> airreload installer >>>'

if FAKE_CLI_VERSION=0.0.0 run_install --replace >/dev/null 2>&1; then
  fail 'wrong CLI version unexpectedly passed validation'
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

if FAKE_CORRUPT_DOWNLOAD=1 run_install >"$test_root/checksum-error" 2>&1; then
  fail 'checksum mismatch unexpectedly succeeded'
fi
assert_contains "$test_root/checksum-error" 'binary checksum mismatch'
assert_not_exists "$install_root"

if FAKE_DOWNLOAD_FAIL=1 run_install >/dev/null 2>&1; then
  fail 'failed download unexpectedly succeeded'
fi
assert_not_exists "$install_root"

if FAKE_UNAME_S=Linux run_install >/dev/null 2>&1; then
  fail 'unsupported platform unexpectedly succeeded'
fi
assert_not_exists "$install_root"

printf 'All installer tests passed.\n'

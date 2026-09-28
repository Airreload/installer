# Airreload installer

Install the native Airreload CLI on **macOS Apple Silicon (arm64)** or **Windows x64**.
Installation downloads one executable, verifies its pinned SHA-256 checksum, and
checks its version and help command. It does not clone source repositories, install
Flutter or Dart, resolve packages, or download any project SDKs.

## Requirements

- macOS Apple Silicon: `curl` and `shasum` (included with macOS)
- Windows x64: PowerShell 5.1 or later
- Internet access during installation

Git is needed when Airreload first downloads a project's patched Flutter SDK.
Building an Android app also requires Android build tools and a suitable JDK.

## Install

Download and extract this repository, or clone it if Git is already installed:

```sh
git clone https://github.com/Airreload/installer.git
cd installer
less install.sh versions.env
./install.sh
```

On Windows, run the native PowerShell installer:

```powershell
Get-Content .\install.ps1, .\versions.env
.\install.ps1
```

The installation is stored in `~/.airreload` on macOS and
`%USERPROFILE%\.airreload` on Windows:

```text
.airreload/
├── bin/airreload          # airreload.exe on Windows
├── cli/.airreload/       # pairing state, created on use
└── sdks/                 # shared Flutter SDK cache, created on first use
```

The installer adds `bin` to your PATH. Open a new terminal afterward. Use
`--no-path` on macOS or `-NoPath` on Windows to skip PATH registration.
Set `AIRRELOAD_INSTALL_ROOT` to choose another absolute installation directory.
The Windows installer supports paths containing spaces.

## Flutter on demand

Run `airreload run` inside a Flutter Android app. Airreload detects its Flutter
version from FVM or the configured/installed Flutter SDK, chooses a supported
patched release, and downloads it only when missing from the cache. Projects
using the same release share that cache. With no detected version, Airreload
uses the latest compatible supported release; an unavailable detected version
uses the closest compatible release and reports the choice.

For exact selection with no fallback:

```sh
airreload run --flutter-version 3.38.10
```

The preview supports Flutter 3.47.5, 3.44.9, 3.41.9, and 3.38.10.
These SDKs remain previews pending manual phone acceptance.
`airreload doctor` works before the first SDK download and reports missing local
tools. Installing Airreload itself does not require Git, Dart, or Flutter.
On Windows, SDK acquisition configures Git long paths for that SDK checkout and
rejects cache paths that would hit the Flutter bootstrap's 260-character limit.
Use a shorter installation root if that diagnostic appears.

## Update or uninstall

On an installer-owned macOS installation:

```sh
airreload update --check
airreload update
```

The CLI uses this repository's `main` manifest as its release channel and runs a
commit-pinned installer with `--replace --no-path --preserve-data`. It preserves
pairing state and downloaded SDKs. The new executable is validated before and
after activation; a failure restores the previous installation and preserved data.
Stop Airreload sessions before updating.

For a manual upgrade, pull or download the updated installer, then run:

```sh
./install.sh --replace --preserve-data
```

On Windows, close Airreload sessions and use:

```powershell
.\install.ps1 -Replace -PreserveData
```

Windows automatic CLI updates are not yet supported. Replacement migrates old
source-based installations to the native executable and removes their bundled
bootstrap Flutter SDK. The `sdks` cache and pairing state are retained when using
the preservation option. Shell PATH entries are not duplicated.

To uninstall:

```sh
./uninstall.sh --yes
```

```powershell
.\uninstall.ps1 -Yes
```

Both installers refuse to replace or remove directories without their ownership
marker. The macOS installer rejects concurrent runs using a sibling lock directory.

## Publishing updates

The CLI tag workflow tests and compiles release executables, smoke-tests them from
an installation without an SDK, uploads their SHA-256 files, and creates a draft
GitHub release. Publish the verified release first. Then update `CLI_TAG`,
`CLI_COMMIT`, `CLI_SHA256_MACOS_ARM64`, and `CLI_SHA256_WINDOWS_X64` in
`versions.env` to match those exact assets. Keep `CLI_DISTRIBUTION=native`.

The legacy `FLUTTER_*` entries remain only so older CLI update clients can parse
the manifest and upgrade. Neither native installer downloads those releases.
A newer CLI semantic version triggers update notices; checksum or installer-only
changes do not. Obtain green installer checks before merging the manifest to
`main`, so users never receive an unavailable binary.

## Verification

```sh
bash -n install.sh uninstall.sh tests/test_installer.sh
shellcheck install.sh uninstall.sh tests/test_installer.sh
bash tests/test_installer.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_installer.ps1
```

Isolated tests verify real checksums, version checks, source-install migration,
state preservation, failed downloads, rollback, ownership checks, PATH registration,
and uninstall behavior. They reject any attempt to invoke Git, Dart, or Flutter.

CI also installs the pinned public binaries on Apple Silicon macOS and Windows
Server 2022/2025 x64 with PowerShell 5.1. The Windows smoke test installs with only
Windows system tools on PATH, verifies no Flutter SDK or package cache was created,
reloads persisted user PATH in a fresh process, checks the commands, and uninstalls.
Git is exposed only for the subsequent `doctor` check.

The Windows smoke script temporarily changes user PATH and is intended only for
disposable CI runners; it restores PATH in `finally`. Hosted runners do not verify
consumer Windows 10/11, standard-user desktop policies, antivirus, phone pairing,
or hot reload. The installers currently do not support Intel Macs, Linux, or
Windows ARM64. The CLI source can also be built for Linux.

# Airreload installer

This repository installs Airreload from its public, pinned source releases. It supports **macOS on Apple Silicon (arm64)** and **Windows**.

## Requirements

- macOS on Apple Silicon, or Windows 10/11
- macOS: `git`, `openssl`, `curl`, and `unzip`
- Windows: Git and PowerShell 5.1 or later
- Internet access during installation

## Install

Clone the installer so you can inspect it before running it:

```sh
git clone https://github.com/Airreload/installer.git
cd installer
less install.sh versions.env
./install.sh
```

The installer clones the exact tagged CLI and patched Flutter releases listed in `versions.env`, verifies their commits, bootstraps Flutter and Dart, resolves CLI packages, and runs `airreload version`, `airreload --help`, and `airreload doctor` before it finishes.

It creates this private, per-user layout:

```text
~/.airreload/
├── bin/airreload
├── cli/
└── flutter/
```

The launcher runs the CLI source with the installed Flutter fork's Dart runtime. The installer adds a marked PATH block to `~/.zprofile` and `~/.bash_profile`; use `--no-path` to skip that step.

### Windows

Run the native PowerShell installer from PowerShell, not WSL:

```powershell
git clone https://github.com/Airreload/installer.git
cd installer
Get-Content .\install.ps1, .\versions.env
.\install.ps1
```

The Windows installer creates the same private layout under `%USERPROFILE%\.airreload`, enables Git long path support for your user, and adds its `bin` directory to your user `PATH`. Use `-NoPath` to skip the PATH update, or `-Replace` to replace an installer-owned installation. Open a new PowerShell window after installation.

Keep custom installation paths short. The pinned Flutter runtime can fail while
listing its deeply nested download cache at the Windows 260-character path
limit, then repeatedly retry bootstrap. Git long-path support does not fix that
runtime behavior. The installer rejects destinations whose staged or final
Flutter cache directory would reach that limit, with a diagnostic requesting a
shorter `AIRRELOAD_INSTALL_ROOT`. This guard covers the observed cache failure;
it does not guarantee support for arbitrarily deep project or package paths.

## Update or uninstall

Once the installed CLI includes the update command, use:

```sh
airreload update --check
airreload update
```

The CLI checks this repository's `main` manifest for a newer CLI version,
shows the release comparison and destination, and runs a commit-pinned copy of
this installer with `--replace --no-path --preserve-data`. The update preserves
`cli/.airreload` (pairing state) and `sdks` (downloaded project SDKs), including
when final validation fails and the previous installation is restored. Stop
Airreload sessions before replacing an installation. Shell profiles stay unchanged.
Concurrent installer runs for the same destination are rejected using a sibling
lock directory; if a process is forcibly killed, remove that lock only after
confirming no installer is still running.


After pulling a reviewed installer update, replace an existing installer-owned installation with:

```sh
./install.sh --replace --preserve-data
```

Replacement is staged and validated before it becomes active. A failed replacement restores the previous installation and shell profiles. The installer refuses to replace directories that do not carry its ownership marker.

To remove the installer-owned directory and its marked PATH entries:

```sh
./uninstall.sh
```

On Windows, use:

```powershell
.\uninstall.ps1
```

For non-interactive use, pass `--yes` on macOS or `-Yes` on Windows. The uninstaller refuses to remove an unmarked directory.

## Limitations

Airreload is beta software for local-network hot reload of Flutter Android apps. This installer does not support Intel Macs or Linux, and it does not install a standalone compiled CLI binary.

## Publishing updates

Publish the CLI tag and verify its immutable commit, then update `CLI_TAG` and
`CLI_COMMIT` in `versions.env` on `main` (and the Flutter pins if its runtime
changes). That manifest is the update channel, including beta releases. A newer
CLI semantic version makes the release discoverable; changing only the installer
or Flutter pins does not trigger a CLI update notice. Publish this installer's
`--preserve-data` support before publishing the first CLI with self-update.
Older installers reject that flag before replacing anything. Existing users whose
CLI lacks `update` must perform the manual replacement above once.

## Contributing

Run the local checks without downloading the pinned repositories:

```sh
bash -n install.sh uninstall.sh tests/test_installer.sh
shellcheck install.sh uninstall.sh tests/test_installer.sh
bash tests/test_installer.sh
```

On Windows, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_installer.ps1
```

CI also installs the public pinned tags on Apple Silicon macOS and hosted Windows runners, verifies the command, and tests uninstall cleanup. See the Windows coverage and limitations below.

## Flutter version preview

This branch installs CLI `0.3.0-beta.1` with a fixed Flutter 3.47.5 runtime.
The CLI can independently download and select project SDKs for Flutter 3.47.5,
3.44.9, 3.41.9, or 3.38.10:

```sh
airreload run --flutter-version 3.38.10
```

An explicit version bypasses FVM and PATH selection and never falls back.
These SDK releases are previews pending manual phone acceptance. Selecting an
older project SDK does not replace the CLI runtime.

### Windows installation CI

Every pull request and push to `main` runs the installer checks. The real Windows
install job uses explicit `windows-2022` and `windows-2025` x64 hosted images
(Windows Server 2022/2025), with Windows PowerShell 5.1. These are the supported
CI environments; they are not Windows 10/11 consumer images. Jobs run independently
so a failure on one image does not cancel the other. Maintainers must approve
fork workflow runs when GitHub reports `action_required`; no checks have run yet
in that state. Require the CI checks to pass before merging manifest or installer
changes. The workflow also supports manual dispatch once present on `main`.

`tests/test_real_install_windows.ps1` exercises:

- Missing Git on a controlled PATH: a nonzero exit, actionable diagnostic, and no
  install, staging, Git config, or user PATH changes.
- A real first install from `versions.env` into a path containing spaces, with a
  fresh pub cache and Git config. PATH exposes only Windows system tools and Git;
  preinstalled Dart, Flutter, PowerShell 7, and OpenSSL must not resolve.
- Real user PATH registration and `airreload version`, `--help`, and `doctor`
  invoked by name in a fresh PowerShell process. Each command's exit code is
  checked. The process reloads the saved user PATH because ordinary child
  processes inherit their parent's environment.
- Uninstall removal, no leftover staging/backup directories, preservation of
  unrelated user PATH entries, and no command discovery in a fresh process.

The smoke script temporarily changes the current user's persisted PATH and is
intended only for disposable Windows CI runners. Its `finally` block restores
PATH and removes its temporary files even on failure. The isolated test suite
uses fake tools and a PATH file instead, covering replacement, rollback,
ownership checks, and pinned-commit mismatches without downloads.

Hosted images still contain SDKs, runtimes, certificates, system configuration,
and elevated runner accounts. Restricting PATH does not remove those components
or verify a standard-user desktop login, execution policies, antivirus behavior,
all prerequisites, or every PC. A genuine minimal consumer-Windows check would
need a disposable Windows 10/11 VM with only documented prerequisites and a
standard-user account; this workflow does not provision one. It also does not
exercise phone pairing, Wi-Fi/firewall connectivity, or hot reload.

These installs test the **pinned released CLI and Flutter**, not current CLI source.
CLI source CI remains separate. Update the manifest through a PR and obtain green
installer checks before promoting that manifest as the installation channel.

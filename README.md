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

The Windows installer creates the same private layout under `%USERPROFILE%\.airreload` and adds its `bin` directory to your user `PATH`. Use `-NoPath` to skip the PATH update, or `-Replace` to replace an installer-owned installation. Open a new PowerShell window after installation.

## Update or uninstall

After pulling a reviewed installer update, replace an existing installer-owned installation with:

```sh
./install.sh --replace
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

CI also performs a real clean install from the public pinned tags on Apple Silicon macOS, verifies the command, and tests uninstall cleanup.

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

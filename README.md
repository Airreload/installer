# Airreload installer

This repository installs Airreload from its public, pinned source releases. It supports **macOS on Apple Silicon (arm64) only**.

## Requirements

- macOS on Apple Silicon
- `git`, `openssl`, `curl`, and `unzip`
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

For non-interactive use, pass `--yes`. The uninstaller refuses to remove an unmarked directory.

## Limitations

Airreload is beta software for local-network hot reload of Flutter Android apps. This installer does not support Intel Macs, Linux, or Windows, and it does not install a standalone compiled CLI binary.

## Contributing

Run the local checks without downloading the pinned repositories:

```sh
bash -n install.sh uninstall.sh tests/test_installer.sh
shellcheck install.sh uninstall.sh tests/test_installer.sh
bash tests/test_installer.sh
```

CI also performs a real clean install from the public pinned tags on Apple Silicon macOS, verifies the command, and tests uninstall cleanup.

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

For non-interactive use, pass `--yes`. The uninstaller refuses to remove an unmarked directory.

## Limitations

Airreload is beta software for local-network hot reload of Flutter Android apps. This installer does not support Intel Macs, Linux, or Windows, and it does not install a standalone compiled CLI binary.

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

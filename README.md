# Vernissage Installer

`vernissagectl` is the command-line installer and administration tool for
[Vernissage](https://joinvernissage.org). This first release verifies the full
distribution path: build, test, package, publish, download, checksum verification,
and installation.

## Supported platforms

- Ubuntu 24.04 x86_64
- Ubuntu 24.04 ARM64
- macOS 26 ARM64

## Build locally

Swift 6.2.4 or newer is required.

```bash
swift build
swift test
swift run vernissagectl
swift run vernissagectl --version
swift run vernissagectl --help
```

The initial command prints:

```text
vernissagectl 0.1.0
The Vernissage installer is ready.
```

## Create the first GitHub Release

The release workflow runs for tags beginning with `v`. The tag version must
match `VernissageVersion.current` in
`Sources/VernissageCore/CommandRunner.swift`.

For the first release:

```bash
git add .
git commit -m "Create the initial vernissagectl release"
git branch -M main
git remote add origin git@github.com:VernissageApp/VernissageInstaller.git
git push -u origin main

git tag v0.1.0
git push origin v0.1.0
```

The tag push creates a GitHub Release containing:

```text
vernissagectl-linux-x86_64.tar.gz
vernissagectl-linux-aarch64.tar.gz
vernissagectl-macos-arm64.tar.gz
SHA256SUMS
```

Enable **Release immutability** in the GitHub repository settings before
publishing the first release.

## Install

Until `install.joinvernissage.org` serves the bootstrap script, it can be run
directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/VernissageApp/VernissageInstaller/main/install.sh | sudo sh
```

After the installation domain has been configured:

```bash
curl -fsSL https://install.joinvernissage.org | sudo sh
```

Install a specific version:

```bash
curl -fsSL https://install.joinvernissage.org | sudo sh -s -- --version 0.1.0
```

Verify the installation:

```bash
vernissagectl
vernissagectl --version
vernissagectl --help
```

By default, the bootstrap script downloads the matching archive and
`SHA256SUMS` from GitHub Releases, verifies the checksum, and installs the
executable as `/usr/local/bin/vernissagectl`.

## Release a new version

1. Update `VernissageVersion.current` and its tests.
2. Commit and push the changes.
3. Create and push the matching `vX.Y.Z` tag.
4. Wait for the **Release** workflow to finish.

The workflow refuses to package an executable whose reported version differs
from the pushed tag.

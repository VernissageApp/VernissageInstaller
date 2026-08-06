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

Swift 6.2 or newer is required for development. Static Linux releases use the
matching Swift 6.3.3 toolchain and Static Linux SDK. GitHub Actions uses the
toolchain preinstalled on each supported runner.

The CLI uses
[Swift Argument Parser](https://github.com/apple/swift-argument-parser) and
Foundation. Linux release artifacts are built with the official Swift Static
Linux SDK and do not require Swift or additional dynamic libraries on the
target server.

```bash
swift build
swift test
swift run vernissagectl
swift run vernissagectl --version
swift run vernissagectl --help
```

The initial command prints:

```text
vernissagectl 0.1.2
The Vernissage installer is ready.
```

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
curl -fsSL https://install.joinvernissage.org | sudo sh -s -- --version 0.1.2
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

Linux archives contain fully statically linked executables built against musl.

## Release a new version

1. Update `VernissageVersion.current` and its tests.
2. Commit and push the changes.
3. Create and push the matching `vX.Y.Z` tag.
4. Wait for the **Release** workflow to finish.

The workflow refuses to package an executable whose reported version differs
from the pushed tag.

If a release workflow fails because of a temporary runner or GitHub service
problem, open **Actions → Release → Run workflow** and enter the existing tag.
The workflow will rebuild and publish that tag without moving it.

# Vernissage Installer

`vernissagectl` is the command-line installer and administration tool for
[Vernissage](https://joinvernissage.org). This first release verifies the full
distribution path: build, test, package, publish, download, checksum verification,
and installation.

> [!WARNING]
> The installer scripts are at an early stage of development and are not ready
> for use yet.

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

```bash
curl -fsSL https://joinvernissage.org/install.sh | sudo sh
```

Install a specific version:

```bash
curl -fsSL https://joinvernissage.org/install.sh | sudo sh -s -- --version 0.1.2
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

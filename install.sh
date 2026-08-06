#!/bin/sh

set -eu

REPOSITORY="${VERNISSAGE_REPOSITORY:-VernissageApp/VernissageInstaller}"
VERSION="${VERNISSAGE_VERSION:-latest}"
INSTALL_DIRECTORY="${VERNISSAGE_INSTALL_DIR:-/usr/local/bin}"
DOWNLOAD_BASE_URL="${VERNISSAGE_DOWNLOAD_BASE_URL:-https://github.com/${REPOSITORY}/releases}"

usage() {
    cat <<'EOF'
Install vernissagectl from GitHub Releases.

Usage:
  install.sh [--version VERSION] [--install-dir DIRECTORY]

Options:
  --version VERSION       Install a specific version, for example 0.1.0.
                          The latest stable release is installed by default.
  --install-dir DIRECTORY Install into DIRECTORY instead of /usr/local/bin.
  -h, --help              Show this help message.

Environment overrides:
  VERNISSAGE_REPOSITORY
  VERNISSAGE_VERSION
  VERNISSAGE_INSTALL_DIR
  VERNISSAGE_DOWNLOAD_BASE_URL
EOF
}

fail() {
    printf 'vernissagectl installer: %s\n' "$1" >&2
    exit 1
}

require_value() {
    option="$1"
    value="${2:-}"
    [ -n "$value" ] || fail "${option} requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            require_value "$1" "${2:-}"
            VERSION="$2"
            shift 2
            ;;
        --install-dir)
            require_value "$1" "${2:-}"
            INSTALL_DIRECTORY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"
command -v install >/dev/null 2>&1 || fail "the install command is required"

system_name="$(uname -s)"
machine_name="$(uname -m)"

case "${system_name}:${machine_name}" in
    Linux:x86_64|Linux:amd64)
        platform="linux-x86_64"
        ;;
    Linux:aarch64|Linux:arm64)
        platform="linux-aarch64"
        ;;
    Darwin:arm64|Darwin:aarch64)
        platform="macos-arm64"
        ;;
    *)
        fail "unsupported platform: ${system_name} ${machine_name}. Supported platforms: Ubuntu 24.04 x86_64, Ubuntu 24.04 ARM64, and macOS 26 ARM64"
        ;;
esac

archive_name="vernissagectl-${platform}.tar.gz"

if [ "$VERSION" = "latest" ]; then
    release_url="${DOWNLOAD_BASE_URL}/latest/download"
else
    normalized_version="${VERSION#v}"
    case "$normalized_version" in
        ''|*[!0-9.]*|.*|*.)
            fail "invalid version: ${VERSION}"
            ;;
    esac
    release_url="${DOWNLOAD_BASE_URL}/download/v${normalized_version}"
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/vernissagectl.XXXXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

archive_path="${temporary_directory}/${archive_name}"
checksums_path="${temporary_directory}/SHA256SUMS"
extract_directory="${temporary_directory}/extracted"

printf 'Downloading %s...\n' "$archive_name"
curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output "$archive_path" "${release_url}/${archive_name}"
curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output "$checksums_path" "${release_url}/SHA256SUMS"

expected_checksum="$(awk -v archive="$archive_name" '
    {
        filename = $2
        sub(/^\*/, "", filename)
        if (filename == archive) {
            print $1
        }
    }
' "$checksums_path")"

[ -n "$expected_checksum" ] || fail "SHA256SUMS does not contain ${archive_name}"

if command -v sha256sum >/dev/null 2>&1; then
    actual_checksum="$(sha256sum "$archive_path" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
    actual_checksum="$(shasum -a 256 "$archive_path" | awk '{ print $1 }')"
else
    fail "sha256sum or shasum is required"
fi

[ "$actual_checksum" = "$expected_checksum" ] || fail "checksum verification failed for ${archive_name}"

mkdir -p "$extract_directory"
tar -xzf "$archive_path" -C "$extract_directory"

executable_path="${extract_directory}/vernissagectl"
[ -f "$executable_path" ] || fail "the release archive does not contain vernissagectl"
[ ! -L "$executable_path" ] || fail "the vernissagectl executable must not be a symbolic link"

mkdir -p "$INSTALL_DIRECTORY" || fail "cannot create ${INSTALL_DIRECTORY}; run the installer with sudo"
install -m 0755 "$executable_path" "${INSTALL_DIRECTORY}/vernissagectl" \
    || fail "cannot install into ${INSTALL_DIRECTORY}; run the installer with sudo"

printf 'Installed %s\n' "$("${INSTALL_DIRECTORY}/vernissagectl" --version)"
printf 'Run: %s\n' "${INSTALL_DIRECTORY}/vernissagectl"

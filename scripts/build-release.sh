#!/bin/sh

set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    printf 'Usage: %s PLATFORM VERSION [OUTPUT_DIRECTORY]\n' "$0" >&2
    exit 64
fi

platform="$1"
version="${2#v}"
output_directory="${3:-dist}"
script_directory="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
project_directory="$(dirname "$script_directory")"

case "$platform" in
    linux-x86_64|linux-aarch64)
        build_arguments="--static-swift-stdlib"
        ;;
    macos-arm64)
        build_arguments=""
        ;;
    *)
        printf 'Unsupported release platform: %s\n' "$platform" >&2
        exit 64
        ;;
esac

cd "$project_directory"

# Intentional word splitting: build_arguments contains zero or one SwiftPM option.
# shellcheck disable=SC2086
swift build -c release --product vernissagectl $build_arguments
binary_directory="$(swift build -c release --show-bin-path)"
binary_path="${binary_directory}/vernissagectl"

[ -x "$binary_path" ] || {
    printf 'Built executable not found: %s\n' "$binary_path" >&2
    exit 1
}

reported_version="$("$binary_path" --version)"
expected_version="vernissagectl ${version}"

[ "$reported_version" = "$expected_version" ] || {
    printf 'Version mismatch: release is %s, executable reports %s\n' "$version" "$reported_version" >&2
    printf 'Update VernissageVersion.current before creating the tag.\n' >&2
    exit 1
}

mkdir -p "$output_directory"
output_directory="$(CDPATH= cd -- "$output_directory" && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/vernissagectl-release.XXXXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

cp "$binary_path" "${temporary_directory}/vernissagectl"
chmod 0755 "${temporary_directory}/vernissagectl"

if command -v strip >/dev/null 2>&1; then
    strip "${temporary_directory}/vernissagectl"
fi

archive_path="${output_directory}/vernissagectl-${platform}.tar.gz"
tar -czf "$archive_path" -C "$temporary_directory" vernissagectl

printf 'Created %s\n' "$archive_path"

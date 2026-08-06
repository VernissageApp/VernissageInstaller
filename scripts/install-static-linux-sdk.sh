#!/bin/sh

set -eu

sdk_version="6.3.3"
sdk_url="https://download.swift.org/swift-${sdk_version}-release/static-sdk/swift-${sdk_version}-RELEASE/swift-${sdk_version}-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
sdk_checksum="87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b"
installed_swift_version="$(swift --version | sed -n '1p')"

case "$installed_swift_version" in
    *"Swift version ${sdk_version} "*)
        ;;
    *)
        printf 'Swift %s is required by the Static Linux SDK; found: %s\n' \
            "$sdk_version" "$installed_swift_version" >&2
        exit 1
        ;;
esac

if swift sdk list | grep -Fq "swift-${sdk_version}-RELEASE_static-linux-0.1.0"; then
    printf 'Swift Static Linux SDK %s is already installed.\n' "$sdk_version"
    exit 0
fi

swift sdk install "$sdk_url" --checksum "$sdk_checksum"
swift sdk list

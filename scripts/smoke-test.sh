#!/bin/sh

set -eu

executable_path="${1:-.build/debug/vernissagectl}"

[ -x "$executable_path" ] || {
    printf 'Executable not found: %s\n' "$executable_path" >&2
    exit 1
}

version_output="$("$executable_path" --version)"
help_output="$("$executable_path" --help)"
ready_output="$("$executable_path")"

printf '%s\n' "$version_output" | grep -Eq '^vernissagectl [0-9]+\.[0-9]+\.[0-9]+$'
printf '%s\n' "$help_output" | grep -Fq 'USAGE: vernissagectl <command>'
printf '%s\n' "$ready_output" | grep -Fq 'The Vernissage installer is ready.'

printf 'Smoke tests passed for %s\n' "$executable_path"

#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ "$#" != 2 ]; then echo 'Usage: sh scripts/package-release.sh CLI_BINARY OUTPUT_DIRECTORY' >&2; exit 2; fi
binary=$1; output=$2
[ -x "$binary" ] || { echo 'CLI binary is missing; prepare assets and build the release product first.' >&2; exit 1; }
[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] && [ "$(lipo -archs "$binary")" = arm64 ] || { echo 'Expected a macOS arm64 CLI; rebuild on the supported release host before packaging.' >&2; exit 1; }
[ -s "$root/LICENSE" ] && [ -s "$root/THIRD_PARTY_NOTICES.md" ] || { echo 'Distribution notices are missing; restore LICENSE and THIRD_PARTY_NOTICES.md before packaging.' >&2; exit 1; }
# Execute only the internal, side-effect-free embedded verifier. No source lookup,
# runtime download, container command, provider or service activation is permitted.
env -i PATH=/usr/bin:/bin "$binary" __adevcontainer_git_broker __verify_embedded_assets >/dev/null
mkdir -p "$output"
stage=$(mktemp -d "$root/.build/release-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
cp "$binary" "$stage/adevcontainer"; chmod 755 "$stage/adevcontainer"
cp "$root/LICENSE" "$root/THIRD_PARTY_NOTICES.md" "$stage/"; chmod 644 "$stage/LICENSE" "$stage/THIRD_PARTY_NOTICES.md"
COPYFILE_DISABLE=1 tar -C "$stage" -czf "$output/adevcontainer-macos-arm64.tar.gz" adevcontainer LICENSE THIRD_PARTY_NOTICES.md
(cd "$output" && shasum -a 256 adevcontainer-macos-arm64.tar.gz > adevcontainer-macos-arm64.tar.gz.sha256)

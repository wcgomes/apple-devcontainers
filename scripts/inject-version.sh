#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "usage: $0 <version>" >&2
  exit 1
fi

version="$1"
version="${version#v}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: invalid version '$1' (expected X.Y.Z or X.Y.Z-prerelease)" >&2
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
target="$root/Sources/adevcontainer/Version.swift"
tmp="${target}.tmp.$$"

cat >"$tmp" <<EOF
enum AppVersion {
    static let current = "$version"
}
EOF

mv "$tmp" "$target"

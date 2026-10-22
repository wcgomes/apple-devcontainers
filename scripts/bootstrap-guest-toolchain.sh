#!/bin/sh
# Maintainer/source-build prerequisite only. Never called by the product at runtime.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
root="$repo/.build/toolchains/zig-0.15.2"
if [ "$#" = 2 ] && [ "$1" = --root ]; then root=$2
elif [ "$#" != 0 ]; then echo 'Usage: sh scripts/bootstrap-guest-toolchain.sh [--root LOCAL_CACHE]' >&2; exit 2; fi
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)
    name=zig-aarch64-macos-0.15.2
    hash=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b ;;
  Linux-x86_64)
    name=zig-x86_64-linux-0.15.2
    hash=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239 ;;
  *) echo 'Unsupported build host; prepare guest artifacts on macOS arm64 or Linux x86-64.' >&2; exit 2 ;;
esac
mkdir -p "$root"
root=$(CDPATH= cd -- "$root" && pwd -P)
archive="$root/$name.tar.xz"
download= stage= locked=0
cleanup() {
  [ -z "$download" ] || rm -f "$download"
  [ -z "$stage" ] || rm -rf "$stage"
  [ "$locked" = 0 ] || rmdir "$root/bootstrap.lock"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
attempt=0
until mkdir "$root/bootstrap.lock" 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 120 ]; then
    echo "Toolchain cache is busy; wait for the other build, or remove '$root/bootstrap.lock' only after verifying no preparation is running." >&2; exit 1
  fi
  sleep 1
done
locked=1
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
  else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
}
if [ ! -f "$archive" ]; then
  download=$(mktemp "$root/download.XXXXXX")
  echo 'Preparing pinned Zig 0.15.2 locally (source build only)…' >&2
  if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 2 --output "$download" "https://ziglang.org/download/0.15.2/$name.tar.xz"; then
    echo "Toolchain download failed; check HTTPS access to ziglang.org and rerun asset preparation." >&2; exit 1
  fi
  if [ "$(digest "$download")" != "$hash" ]; then
    echo "Zig archive checksum mismatch; remove the failed download and retry using the official pinned source." >&2; exit 1
  fi
  mv "$download" "$archive"; download=
fi
# A version string is not a cache integrity check. Verify before every reuse.
if [ -L "$archive" ] || [ "$(digest "$archive")" != "$hash" ]; then
  echo "Zig cached archive checksum mismatch; remove '$archive' and rerun asset preparation." >&2; exit 1
fi
# Never reuse an extracted tree, including its headers/libraries. Each invocation
# owns a private verified extraction; another bootstrap cannot replace a sysroot
# while its compiler is running. Caller removes this directory after use.
stage=$(mktemp -d "$root/verified.XXXXXX")
tar -xJf "$archive" -C "$stage"
[ -x "$stage/$name/zig" ] && [ ! -L "$stage/$name/zig" ] || {
  echo 'Verified archive has no safe Zig compiler; check the pinned archive layout.' >&2; exit 1
}
printf '%s\n' "$stage/$name/zig"
stage=

#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
output="$root/.build/guest-credential-relay"
cache="$root/.build/guest-credential-relay-cache"
raw=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --raw-only) raw=1; shift ;;
    --output|--cache)
      [ "$#" -ge 2 ] || { echo 'Missing build directory; supply --output PATH or --cache PATH.' >&2; exit 2; }
      if [ "$1" = --output ]; then output=$2; else cache=$2; fi; shift 2 ;;
    *) echo 'Usage: sh scripts/build-guest-credential-relay.sh [--raw-only] [--output PATH] [--cache PATH]' >&2; exit 2 ;;
  esac
done
mkdir -p "$output" "$cache"
output=$(CDPATH= cd -- "$output" && pwd -P)
cache=$(CDPATH= cd -- "$cache" && pwd -P)
zig=$(sh "$root/scripts/bootstrap-guest-toolchain.sh")
toolchain=$(dirname "$(dirname "$zig")")
case "$toolchain" in "$root/.build/toolchains/zig-0.15.2/verified."*) ;; *) echo 'Unsafe toolchain extraction path; rerun bootstrap from this checkout.' >&2; exit 1 ;; esac
trap 'rm -rf "$toolchain"' EXIT
trap 'exit 1' HUP INT TERM
for arch in arm64 amd64; do
  case "$arch" in arm64) target=aarch64-linux-musl ;; amd64) target=x86_64-linux-musl ;; esac
  mkdir -p "$output/linux-$arch"
  # Cache locations are local and may be separated by reproducibility tests.
  ZIG_LOCAL_CACHE_DIR="$cache/local" ZIG_GLOBAL_CACHE_DIR="$cache/global" \
    "$zig" cc -target "$target" -mcpu=baseline -std=c11 -O2 -static -s \
      -Wall -Wextra -Werror -fno-ident -ffile-prefix-map="$root"=. \
      -Wl,--build-id=none "$root/Guest/GitCredentialRelay/main.c" \
      -o "$output/linux-$arch/adevcontainer-git-relay"
done
if [ "$raw" = 0 ]; then
  [ "$(uname -s)" = Darwin ] || { echo 'Swift asset generation requires macOS/CryptoKit; use --raw-only for Linux CI.' >&2; exit 2; }
  swift "$root/scripts/prepare-guest-credential-assets.swift" "$output" \
    "$root/Sources/ADevContainerLib/Git/Generated/GuestGitCredentialEmbeddedAssets.swift" \
    "$root/Guest/GitCredentialRelay/main.c"
fi

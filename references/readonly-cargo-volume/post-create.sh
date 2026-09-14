#!/bin/sh
set -eu

cargo_path=/usr/local/cargo/bin/cargo
root_probe=/adevcontainer-issue-45-rootfs-write-probe

# Prove --read-only reached the main container. If this unexpectedly succeeds,
# the trap removes the probe before the script reports the regression.
trap 'rm -f "$root_probe" 2>/dev/null || true' 0 1 2 15
if ( : > "$root_probe" ) 2>/dev/null; then
  printf 'ERROR: rootfs write unexpectedly succeeded at %s; --read-only was not enforced.\n' \
    "$root_probe" >&2
  exit 47
fi
trap - 0 1 2 15

if [ ! -x "$cargo_path" ]; then
  printf '%s\n' \
    "ERROR: $cargo_path is unavailable; the named volume does not contain Cargo from the image." \
    >&2
  exit 45
fi

resolved_cargo=$(command -v cargo || true)
if [ "$resolved_cargo" != "$cargo_path" ]; then
  printf 'ERROR: cargo resolved to %s, expected %s.\n' "$resolved_cargo" "$cargo_path" >&2
  exit 46
fi

if ! cargo_version=$(CARGO_NET_OFFLINE=true cargo --version 2>&1); then
  printf 'ERROR: %s exists but cargo --version failed in offline mode.\n%s\n' \
    "$cargo_path" "$cargo_version" >&2
  exit 48
fi

printf 'PASS: issue #45 validation succeeded; cargo=%s; version=%s; rootfs=read-only; network=offline\n' \
  "$cargo_path" "$cargo_version"

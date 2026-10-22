#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
out="$root/.build/guest-credential-relay-tests"
mkdir -p "$out"
case "$(uname -s)" in
  Darwin)
    cc -std=c11 -Wall -Wextra -Werror -O2 "$root/Tests/GuestGitCredentialRelay/relay_tests.c" -o "$out/tests"
    if [ -f "$root/Guest/GitCredentialRelay/main.c" ]; then
      cc -std=c11 -Wall -Wextra -Werror -O2 "$root/Guest/GitCredentialRelay/main.c" -o "$out/relay"
    fi
    relay="$out/relay"
    ;;
  Linux)
    zig=$(sh "$root/scripts/bootstrap-guest-toolchain.sh")
    toolchain=$(dirname "$(dirname "$zig")")
    case "$toolchain" in "$root/.build/toolchains/zig-0.15.2/verified."*) ;; *) echo 'Unsafe toolchain extraction path; rerun bootstrap from this checkout.' >&2; exit 1 ;; esac
    trap 'rm -rf "$toolchain"' EXIT
    trap 'exit 1' HUP INT TERM
    "$zig" cc -std=c11 -Wall -Wextra -Werror -O2 "$root/Tests/GuestGitCredentialRelay/relay_tests.c" -o "$out/tests"
    relay="$root/.build/guest-credential-relay/linux-amd64/adevcontainer-git-relay"
    ;;
  *) echo 'Unsupported native-test host; use macOS or Linux x86-64.' >&2; exit 2 ;;
esac
# Avoid macOS /var -> /private/var symlinks in the endpoint security tests.
TMPDIR=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P) "$out/tests" "$relay"

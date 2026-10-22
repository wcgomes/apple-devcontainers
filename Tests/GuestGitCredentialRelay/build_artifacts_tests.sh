#!/bin/sh
# No runtime/provider/broker effects. Downloads only the officially pinned local toolchain.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
mkdir -p "$root/.build"
work=$(mktemp -d "$root/.build/credential-artifact-tests.XXXXXX")
first_zig= second_zig= third_zig=
cleanup() {
  for compiler in "$first_zig" "$second_zig" "$third_zig"; do
    [ -n "$compiler" ] || continue
    tree=$(dirname "$(dirname "$compiler")")
    case "$tree" in "$root/.build/toolchains/zig-0.15.2/verified."*) rm -rf "$tree" ;; esac
  done
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
must_fail() { if "$@" >"$work/rejected.stdout" 2>"$work/rejected.stderr"; then fail "accepted invalid artifact/toolchain"; fi; }
if [ "${1:-}" = --package ]; then
  [ "$#" = 2 ] || fail 'usage: build_artifacts_tests.sh --package CLI_BINARY'
  [ -f "$root/scripts/package-release.sh" ] || fail 'release packaging is absent'
  sh "$root/scripts/package-release.sh" "$2" "$work/dist"
  mkdir "$work/relocated"
  tar -xzf "$work/dist/adevcontainer-macos-arm64.tar.gz" -C "$work/relocated"
  [ "$(find "$work/relocated" -type f | wc -l | tr -d ' ')" = 3 ] || fail 'archive layout drift'
  [ -f "$work/relocated/LICENSE" ] && [ -f "$work/relocated/THIRD_PARTY_NOTICES.md" ] || fail 'missing licenses'
  cmp "$root/THIRD_PARTY_NOTICES.md" "$work/relocated/THIRD_PARTY_NOTICES.md"
  (cd "$work/relocated" && env -i PATH=/usr/bin:/bin ./adevcontainer __adevcontainer_git_broker __verify_embedded_assets) > "$work/embedded.json"
  swift - "$work/embedded.json" "$root/.build/guest-credential-relay/manifest.json" <<'SWIFT'
import Foundation
let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [[String: Any]]
precondition(actual.count == 2 && expected.count == 2)
for row in expected {
    let target = row["target"] as! String
    let found = actual.first { $0["target"] as? String == target }!
    precondition(found["sha256"] as? String == row["sha256"] as? String)
    precondition(found["size"] as? Int == row["size"] as? Int)
    precondition(found["protocolVersion"] as? Int == row["protocolVersion"] as? Int)
}
SWIFT
  echo 'PASS packaged notices and relocated embedded guest artifacts'
  exit 0
fi
# An absent generator/build is a behavioral delivery failure, not a compiler failure.
[ -f "$root/scripts/build-guest-credential-relay.sh" ] || fail 'static guest artifact preparation is absent'
[ -f "$root/scripts/prepare-guest-credential-assets.swift" ] || fail 'ELF verifier/generator is absent'
mkdir -p "$work/toolchain"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) archive=zig-aarch64-macos-0.15.2.tar.xz ;;
  Linux-x86_64) archive=zig-x86_64-linux-0.15.2.tar.xz ;;
  *) fail 'unsupported build host' ;;
esac
printf 'corrupt synthetic toolchain archive' > "$work/toolchain/$archive"
must_fail sh "$root/scripts/bootstrap-guest-toolchain.sh" --root "$work/toolchain"
grep -q 'checksum' "$work/rejected.stderr" || fail 'bad checksum did not name its fix'
# Every returned compiler/sysroot must come from the authenticated archive, not a
# previously extracted mutable tree. Do not execute the synthetic replacements.
first_zig=$(sh "$root/scripts/bootstrap-guest-toolchain.sh")
printf '#!/bin/sh\nexit 99\n' > "$first_zig"
second_zig=$(sh "$root/scripts/bootstrap-guest-toolchain.sh")
grep -q 'exit 99' "$second_zig" && fail 'reused modified compiler'
printf 'synthetic auxiliary tampering' > "$(dirname "$second_zig")/lib/std/std.zig"
third_zig=$(sh "$root/scripts/bootstrap-guest-toolchain.sh")
grep -q 'synthetic auxiliary tampering' "$(dirname "$third_zig")/lib/std/std.zig" && fail 'reused modified auxiliary file'
# An installed zig (including a deliberately broken one) is never consulted.
mkdir -p "$work/bin"
printf '#!/bin/sh\necho unexpected-installed-zig >&2\nexit 99\n' > "$work/bin/zig"
chmod +x "$work/bin/zig"
PATH="$work/bin:$PATH"; export PATH
sh "$root/scripts/build-guest-credential-relay.sh" --raw-only --output "$work/one" --cache "$work/cache-one"
sh "$root/scripts/build-guest-credential-relay.sh" --raw-only --output "$work/two" --cache "$work/cache-two"
for target in linux-arm64 linux-amd64; do
  cmp "$work/one/$target/adevcontainer-git-relay" "$work/two/$target/adevcontainer-git-relay" || fail 'nonreproducible ELF'
done
if [ "$(uname -s)" = Darwin ]; then
  swift "$root/scripts/prepare-guest-credential-assets.swift" "$work/one" "$work/one.swift" "$root/Guest/GitCredentialRelay/main.c"
  swift "$root/scripts/prepare-guest-credential-assets.swift" "$work/two" "$work/two.swift" "$root/Guest/GitCredentialRelay/main.c"
  cmp "$work/one/manifest.json" "$work/two/manifest.json"
  cmp "$work/one.swift" "$work/two.swift"
  swift - "$work/one.swift" "$work/one" "$root/Guest/GitCredentialRelay/main.c" <<'SWIFT'
import Foundation
import CryptoKit
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
let generated = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
func payload(_ key: String) -> Data {
    let prefix = "static let \(key) = \""
    let range = generated.range(of: prefix)!
    let tail = generated[range.upperBound...]
    return Data(base64Encoded: String(tail.prefix(while: { $0 != "\"" })))!
}
let root = URL(fileURLWithPath: CommandLine.arguments[2])
let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
precondition(payload("manifestBase64") == manifest)
let rows = try JSONSerialization.jsonObject(with: manifest) as! [[String: Any]]
let sourceDigest = digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
precondition(rows.count == 2)
for (index, arch) in ["arm64", "amd64"].enumerated() {
    let raw = try Data(contentsOf: root.appendingPathComponent("linux-\(arch)/adevcontainer-git-relay"))
    precondition(payload("\(arch)Base64") == raw)
    precondition(rows[index]["sha256"] as? String == digest(raw))
    precondition(rows[index]["size"] as? Int == raw.count)
    precondition(rows[index]["target"] as? String == "linux/\(arch)")
    precondition(rows[index]["protocolVersion"] as? Int == 1)
    precondition(rows[index]["sourceSHA256"] as? String == sourceDigest)
}
SWIFT
  # Deliberately mutate ELF machine, program-header type, dynamic dependency and truncation.
  cp "$work/one/linux-arm64/adevcontainer-git-relay" "$work/original"
  printf '\076\000' | dd of="$work/one/linux-arm64/adevcontainer-git-relay" bs=1 seek=18 conv=notrunc 2>/dev/null
  must_fail swift "$root/scripts/prepare-guest-credential-assets.swift" "$work/one" "$work/rejected.swift" "$root/Guest/GitCredentialRelay/main.c"
  cp "$work/original" "$work/one/linux-arm64/adevcontainer-git-relay"
  # Pinned linker puts the program table at byte 64; generator validates this offset, not this test.
  printf '\003\000\000\000' | dd of="$work/one/linux-arm64/adevcontainer-git-relay" bs=1 seek=64 conv=notrunc 2>/dev/null
  must_fail swift "$root/scripts/prepare-guest-credential-assets.swift" "$work/one" "$work/rejected.swift" "$root/Guest/GitCredentialRelay/main.c"
  cp "$work/original" "$work/one/linux-arm64/adevcontainer-git-relay"
  printf '\002\000\000\000' | dd of="$work/one/linux-arm64/adevcontainer-git-relay" bs=1 seek=64 conv=notrunc 2>/dev/null
  must_fail swift "$root/scripts/prepare-guest-credential-assets.swift" "$work/one" "$work/rejected.swift" "$root/Guest/GitCredentialRelay/main.c"
  dd if="$work/original" of="$work/one/linux-arm64/adevcontainer-git-relay" bs=1 count=80 2>/dev/null
  must_fail swift "$root/scripts/prepare-guest-credential-assets.swift" "$work/one" "$work/rejected.swift" "$root/Guest/GitCredentialRelay/main.c"
  [ ! -e "$work/rejected.swift" ] || fail 'invalid ELF generated a payload'
fi
grep -q 'musl' "$root/THIRD_PARTY_NOTICES.md" || fail 'missing musl notices'
grep -q 'LLVM' "$root/THIRD_PARTY_NOTICES.md" || fail 'missing compiler runtime notices'
echo 'PASS pinned toolchain, deterministic static targets, ELF rejection, generated identity, notices'

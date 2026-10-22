# Native credential relay development

These checks use synthetic strings, local pipes/sockets and build artifacts only.
They do not run Apple `container`, a broker process, launchd, host Git credential helpers or keychain.

```sh
sh scripts/test-guest-credential-relay.sh
sh scripts/build-guest-credential-relay.sh
sh Tests/GuestGitCredentialRelay/build_artifacts_tests.sh
swift build --product adevcontainer
```

macOS arm64 preparation downloads the official Zig 0.15.2 archive into
`.build/toolchains/zig-0.15.2/`, authenticates its pinned SHA-256 before extraction
and on every reuse, and uses that compiler rather than an installed `zig`.
Required source-build tools: CLT (`cc`, Swift/Foundation/CryptoKit), POSIX shell,
curl, tar with xz support and shasum (or sha256sum). The initial archive download
requires HTTPS access to ziglang.org; subsequent builds use the verified archive.
Every invocation extracts a new owner-private tree from that authenticated archive;
extracted compilers, headers and libraries are never reused. Build/test callers
remove their extraction afterwards. Cache contents are not runtime inputs.
Concurrent cache initialization is serialized; an interrupted initializer may
leave `bootstrap.lock`. Remove that exact directory only after confirming no
preparation is running. No global toolchain installation is performed.

`build-guest-credential-relay.sh` builds baseline `aarch64-linux-musl` and
`x86_64-linux-musl` static executables. It then verifies ELF metadata, including
machine, program/section table bounds, executable entry point and absence of
PT_INTERP/PT_DYNAMIC, and generates a deterministic manifest and base64 Swift
source. The generated Swift file and all build outputs/caches are gitignored.
Do not hand-edit or commit them. The manifest records source SHA-256, protocol,
both toolchain archive pins and individual binary lengths/hashes.

The artifact tests rebuild into two separate output/cache roots, compare bytes,
verify embedded payloads/metadata against those bytes, and reject wrong-machine,
interpreter, dynamic-segment and truncated ELF inputs. Tests deliberately supply
a broken `zig` on PATH, a corrupt cached archive and tampered extracted compiler/
auxiliary files. Native macOS tests exercise
a CLT-built executable; they are not Linux-target execution evidence. On Linux
x86-64, first run `sh scripts/build-guest-credential-relay.sh --raw-only`, then
the native harness; it executes the shipped static amd64 output, not a substitute
parser build. Linux does not require Swift or the Apple runtime for these steps.
Actual arm64 Linux execution remains separately authorized smoke work.

The wire contract is documented at the top of `Guest/GitCredentialRelay/main.c`.
Native fixtures in `relay_tests.c` are the source for the later host codec tests.
The relay requires a private, physical (no symlink components) absolute directory,
checks same-UID peers, locks per-directory ownership, and will only unlink an
owned socket. Its lock file is nonsecret and persists for subsequent reuse.
Clients have a 15-second end-to-end deadline and use one request per connection.
Backpressured Linux pipe output uses an independent nonblocking proc-fd reopen;
other output uses one supervised/reaped writer with an orphan alarm. Neither
changes Git's shared stdout status flags. Tests include a 60-KB reply to a nearly
full pipe, 64-client saturation and (on Linux) pending-disconnect CPU usage.

**Implementation status:** these are native delivery tests, not the complete
automatic credential product. Swift policy/protocol/provider/runtime/registry and
broker-channel tests are available with
`ADEVCONTAINER_CREDENTIAL_TESTS_ONLY=1 swift run adevcontainerTests`.
Detached broker activation, provisioning/migration, and lifecycle integration are implemented and covered by the synthetic credential suite and the separately invoked isolated detached probe. The separately authorized plantsuite smoke also verified real credential lookups, concurrent Git operations, CLI-exit survival, stop/idle exit, and recovery on the next start after a crash; it does not certify OAuth renewal or the external-stop retirement bound. These results do not certify release packaging or every guest platform. See [the archived execution record](../../specs/changes/archive/20261022-git-broker-detached-lifecycle/tasks.md) for evidence and limits. Do not run the full Swift test suite without checking its real-runtime side effects.

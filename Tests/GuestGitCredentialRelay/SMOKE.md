# Isolated credential smoke

This procedure is not an automatic check. Do not run it against a user
container, a real Git credential provider, or the production broker state under
`~/Library/Application Support/adevcontainer/git-credentials` and
`~/.adevcontainer/git-broker`.

## Authorization

Both gates are required, and neither is set by unit tests:

```sh
ADEVCONTAINER_CREDENTIAL_SMOKE=1
ADEVCONTAINER_CREDENTIAL_SMOKE_AUTHORIZED=1
```

Without the second variable the test process must exit before container creation,
keychain, or network authentication. The automatic suite does not execute the live
arm64 guest path even when both variables are set. That execution remains a
separately authorized operator step.

## Temporary root

Use only a unique directory under the approved temporary root
(`$TMPDIR/opencode`, resolved with `realpath`). The broker context label must be
`com.adevcontainer.git-credentials.test.<UUID>`. State, socket, helper, and
provider config must live under that directory. Do not change `HOME` to hide the
production broker and do not write anywhere under `~/Library`.

## Synthetic provider

Write a test-owned Git config that selects only a local fixture helper for
`https://credential-smoke.invalid`. The provider environment may contain only
`PATH`, `HOME`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM=/dev/null`, and
`GIT_CONFIG_NOSYSTEM=1`. Exclude user and system Git config, inherited
`GIT_CONFIG_COUNT` / `GIT_CONFIG_PARAMETERS`, `ADEVCONTAINER_GIT_TOKEN`,
`GH_TOKEN`, `GITHUB_TOKEN`, and tracing. The fixture password is the literal
`synthetic-smoke`. Do not print it in logs. A successful fill of that host is
not evidence of OAuth renewal or of a real provider.

## Baseline

Before the run, record existence and a nonsecret metadata fingerprint of the
production broker state directory. Do not dump credential-store contents.
After success, injected failure, and a handled signal, compare that baseline.
It must be unchanged.

## Cleanup that the harness can run

On success, failure, and handled termination:

1. Terminate only the broker pids recorded in the run manifest (`kill -TERM <pid>`).
2. Remove only the helper, provider config, state, and socket root under the
   private test root.
3. Remove only containers recorded in the run manifest.
4. Confirm the broker process, control socket, and those containers are absent.

Do not signal a pid the manifest does not list, do not delete a broad temporary
directory, and never run `container prune` or a broad container/volume delete.

## SIGKILL

A killed process cannot run a trap. Before the first activation, and again for
each activation that records a broker pid, the harness prints one secret-free
line with the fixture root, state path, and pid. The broker also writes its pid
to `<root>/pid`. An operator sweep must use only those recorded paths and pids.
Absence of the production broker from those lines is required; do not treat a
crash as permission to repair the user's installation.

## Isolated detached-broker lifetime test (no containers or real credential acquisition)

The separate detached probe exercises the real broker/service/control loop with
synthetic runtime observations and in-memory channels. It starts the same test
executable as a detached child from a private context, exactly as the product
does. It never selects the installed CLI, the production context, the Apple
runtime, launchd, or a host credential provider. Its acquisition port returns a
miss unless the fixture explicitly requests the post-upgrade lookup, and every
attempt is recorded; tests that must prove no provider polling require that count
to stay at zero.

```sh
ADEVCONTAINER_TESTS_SYNTHETIC_ONLY=1 swift run adevcontainerTests
ADEVCONTAINER_DETACHED_BROKER_TEST=1 \
  ADEVCONTAINER_CREDENTIAL_TESTS_ONLY=1 \
  .build/debug/adevcontainerTests
```

The probe gate is not set by ordinary tests. Without it the detached suite is
excluded, not counted as empirical evidence. CI runs only the synthetic suite and
does not set the detached gate, so detached results are recorded only when this
command is invoked explicitly. Normal safe regression selection is
`ADEVCONTAINER_TESTS_SYNTHETIC_ONLY=1 swift run adevcontainerTests` with all live
gates unset.

The fixture creates one short private root below the physical `$TMPDIR/opencode`,
one `com.adevcontainer.git-credentials.test.<UUID>` context, and test-owned copies
of the test executable. Copies are how an upgrade is simulated: a replacement file
has the same build bytes but a different device/inode. The test never reads or
fingerprints production state or credentials. No containers, network, keychain,
launchd job, plist, or real provider are involved.

Checks cover: broker started before the consumer and surviving CLI exit; two
concurrent CLIs converging on one process; idle exit in the 5–7-second window with
the control socket removed and no automatic replacement; SIGKILL leaving a stale
socket that is not usable and no replacement during a window longer than the idle
bound, with the next activation restoring the process, the nonsecret registration,
and the channel; replacement of an owner from a different executable with
registrations preserved and no repeated kill of the healthy successor, followed by
a channel lookup the successor serves from the saved registration; graceful exit
removing only its own socket while preserving lock inodes and registrations; a
stale privately owned socket replaced safely; a same-user socket that accepts but
stays silent failing closed without replacing its inode or starting a competing
owner; a symlinked endpoint failing closed without deleting the target; a channel
whose cancel is slow not extending broker shutdown past 7 seconds; and SIGHUP
ignored while SIGTERM exits gracefully. Pending work is cancelled on exit; a
successor does not restore an explicit token override or replay a provider request.

Before the first activation, stderr prints the exact fixture root, state path,
and pid for recovery after an unhandleable parent termination. On normal
completion, failure, SIGINT, or SIGTERM the parent terminates only recorded pids,
verifies their exit, and then removes the owned root. A parent SIGKILL cannot run cleanup: use only the printed
root and the pids recorded there, never a broad temporary-directory deletion.

See [the archived execution record](../../specs/changes/archive/20261022-git-broker-detached-lifecycle/tasks.md) for execution evidence
and scenario coverage.

# Change Spec: automatic-ssh-forwarding-up

Domain: `core` (additive to [core](../../../core.md); preserves [clone](../../../clone.md) and [runArgs](../../../runargs-host.md)).

## ADDED Requirements

### Requirement: Automatic SSH forwarding for bind workspaces
Fresh bind-mode `up` and explicit bind-mode `rebuild` MUST request exactly one effective Apple create `--ssh` when at least one local fetch or push remote uses SSH and the invocation's host `SSH_AUTH_SOCK` resolves to a Unix-domain socket. Both paths MUST use the same policy and the same invocation environment for endpoint selection and automatic-forwarding create execution. Socket presence MUST NOT be presented as proof of agent liveness, loaded keys, or authentication success. Discovery MUST be host-local, noninteractive, best-effort and bounded, without guest execution, network operations, credential acquisition, or disclosure of remote URLs/credentials in diagnostics or newly persisted metadata. No repository, absent remotes, unavailable host Git, or discovery failure MUST leave automatic forwarding disabled without failing bring-up.

An SSH remote with no such endpoint MUST continue without automatic forwarding and emit one actionable stderr warning explaining how to expose a host agent and use an explicit rebuild if the container has already been created. The CLI MUST NOT copy keys, query agent keys, install a guest SSH agent, or introduce new public flags or services. HTTPS-only and local-only remotes MUST NOT trigger automatic SSH forwarding or its missing-agent warning. Existing explicit `runArgs --ssh` MUST remain effective once regardless of socket/remotes, without a new product-side agent requirement or automatic-missing-agent warning; existing runtime failures remain possible. Clone/volume create and rebuild policy and HTTP(S) credential behavior MUST remain unchanged.

#### Scenario: S01 - SSH remote and socket
- Given a local SSH remote and an invocation environment selecting a host Unix-domain socket
- When fresh bind `up` creates a container
- Then create includes one `--ssh` and uses that invocation environment, without asserting that SSH authentication succeeds.

#### Scenario: S02 - SSH remote without usable socket
- Given an SSH remote and an unset, blank, nonexistent, or non-socket `SSH_AUTH_SOCK`, with no explicit `--ssh`
- When bind `up` or bind `rebuild` creates a container
- Then automatic `--ssh` is absent, one actionable stderr warning is emitted, and this omission alone does not fail the operation or copy keys.

#### Scenario: S03 - HTTPS-only and local-only workspaces
- Given only HTTPS or local-path remotes, or no discoverable remotes, with or without a socket and no explicit `--ssh`
- When bind creation runs
- Then no automatic `--ssh` or missing-agent warning is added, and HTTPS credential behavior is unchanged.

#### Scenario: S04 - Mixed transports and push-only SSH
- Given an HTTPS fetch URL and an SSH push URL, or separate HTTPS and SSH remotes, and a host socket
- When bind creation runs
- Then one automatic `--ssh` is included regardless of which remote is named `origin`.

#### Scenario: S05 - SSH URL forms
- Given remotes using `git@example.invalid:group/repo.git`, `example.invalid:group/repo.git`, or `ssh://git@example.invalid/group/repo.git`
- When bind SSH eligibility is determined
- Then each is recognized as SSH, unlike absolute/relative local paths or non-SSH scheme URLs.

#### Scenario: S06 - Explicit forwarding remains explicit
- Given admitted `runArgs` containing `--ssh`, for SSH or HTTPS-only remotes and with or without a host socket
- When bind creation runs
- Then create contains one `--ssh`, the explicit-only environment/runtime behavior is preserved, and automatic policy does not reject the request or emit its missing-agent warning.

#### Scenario: S07 - Explicit bind rebuild refreshes forwarding
- Given a bind container and current local remotes/environment
- When the user explicitly invokes `rebuild`
- Then the replacement uses the same forwarding decision as fresh bind `up`, while normal preflight, container-only deletion, and volume preservation remain unchanged; clone-origin volume rebuild keeps its prior policy.

### Requirement: Existing bind containers retain create-time SSH settings
`up` reuse, `up` start-stopped and bare `start` MUST NOT add/remove SSH forwarding, recreate a container, or emulate forwarding in the guest. Changes in host socket availability or local remotes alone MUST NOT change config hash or force a mismatch/rebuild. When SSH plus a socket would qualify for automatic forwarding and existing bind forwarding is not recorded as enabled, these paths MUST emit nonfatal conditional guidance naming `adevcontainer rebuild --name <selected-name>` (respecting the invocation prefix) to apply create-time SSH settings if unavailable. Unknown legacy state MUST NOT be described as verified disabled. Existing config-hash mismatch handling remains authoritative.

#### Scenario: S08 - Reuse and start cannot add a create flag
- Given a same-config bind container without recorded forwarding (including a legacy container), newly eligible local SSH remotes and a host socket
- When `up` reuses it or starts it, or bare `start` selects it
- Then the existing container is preserved, no create/reconfigure/guest-SSH action occurs, and conditional rebuild guidance is emitted on stderr without contaminating JSON stdout or claiming verified absence.

#### Scenario: S09 - Environmental changes do not force rebuild
- Given a same-config bind container with forwarding recorded enabled, whose remotes or host socket changed
- When `up` or `start` runs
- Then create-time settings and identity remain unchanged, no automatic replacement or new config-hash mismatch occurs, and no missing-forwarding rebuild hint is emitted.

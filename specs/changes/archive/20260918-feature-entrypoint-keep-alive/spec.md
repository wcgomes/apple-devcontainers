# Change Spec: feature-entrypoint-keep-alive

Delta against realized contract (union of `specs/<domain>.md`). RFC 2119 keywords apply.

## ADDED Requirements

### Requirement: Feature entrypoint wrap at main-container create

The CLI MUST honor Feature metadata `entrypoint` at **main managed-container create** so `up` matches default Docker/Podman Dev Containers UX without using `postStartCommand` for Feature entrypoints.

**Parse (MUST):** For each admitted Feature, `devcontainer-feature.json` `entrypoint` MUST be a string when present. Absent, empty, or whitespace-only values MUST contribute nothing. Non-string values MUST fail closed with a structured error in the Feature metadata family, naming the feature ref and `entrypoint`, and MUST NOT create a container.

**Collect (MUST):** Non-empty Feature `entrypoint` strings MUST be collected in Feature **install order**. This change does not require merging `entrypoint` from image `devcontainer.metadata`. Image Dockerfile `ENTRYPOINT`/`CMD` MUST remain discarded.

**Main create argv (MUST):**

1. When the collected list is empty, main managed create MUST use today’s keep-alive argv: `--entrypoint /bin/sleep`, the create image, `infinity`.
2. When the collected list is non-empty, main managed create MUST use a `/bin/sh -c` wrapper whose script runs each collected entrypoint as its **own script line** (the wrapper MUST NOT `exec` those lines unless the Feature script itself execs), then `exec /bin/sleep infinity`. Keep-alive `/bin/sleep infinity` MUST be the final PID 1. The observable shape is official CLI (Feature entrypoints then keep-alive), not the image command.

**Substitution (MUST):** `${devcontainerId}` in a Feature `entrypoint` string MUST expand with the same deferred create-time substitution already used for mounts and `containerEnv`. The product MUST NOT invent a second substitution mechanism.

**Helpers (MUST):** Ownership helper creates and recovery helper creates MUST keep sleep-only create argv (`--entrypoint /bin/sleep` and `infinity`), equivalent to an empty Feature entrypoint list. Feature entrypoints MUST NOT apply to those creates.

**Not a lifecycle hook (MUST):** Feature `entrypoint` MUST NOT run via container exec, MUST NOT remelt on `start` / `up` start-stopped / resume, and MUST NOT be stored or ordered as a lifecycle hook. `container start` re-runs PID 1; that is sufficient for the wrap to run again.

**Not a Features image recipe change (MUST):** The Features install Dockerfile MUST NOT gain an `ENTRYPOINT` instruction because of this change. Features `recipeVersion` MUST NOT bump solely for honoring Feature `entrypoint` at create.

**Unchanged (MUST NOT regress):** `overrideCommand: true` remains a silent restatement of the product keep-alive override. `overrideCommand: false` remains blocked. `runArgs --entrypoint` remains forever rejected.

#### Scenario: empty or absent entrypoint keeps sleep-only create argv

- Given admitted Features whose metadata omits `entrypoint` or sets it to empty or whitespace-only
- When main managed-container create argv is built
- Then create uses `--entrypoint /bin/sleep` and `infinity`
- And create does not use a `/bin/sh -c` Feature entrypoint wrapper

#### Scenario: single Feature entrypoint wraps then keep-alive

- Given one admitted Feature whose metadata `entrypoint` is a non-empty string
- When main managed-container create argv is built
- Then create uses `--entrypoint /bin/sh` and `-c` with that entrypoint as its own script line
- And the `-c` script ends by `exec /bin/sleep infinity`
- And keep-alive `/bin/sleep infinity` is the final PID 1 process

#### Scenario: multiple Feature entrypoints run as separate lines in install order

- Given two admitted Features A then B in install order, each with a distinct non-empty metadata `entrypoint`
- When main managed-container create argv is built
- Then the `/bin/sh -c` script contains A’s entrypoint as its own line before B’s entrypoint as its own line
- And the script then `exec /bin/sleep infinity`

#### Scenario: wrapper does not exec Feature entrypoint lines

- Given a non-empty Feature `entrypoint` list at main create
- When the `/bin/sh -c` wrapper script is inspected
- Then Feature entrypoint lines are not prefixed with `exec`
- And only the keep-alive `/bin/sleep infinity` is `exec`’d by the wrapper

#### Scenario: ownership helper create stays sleep-only

- Given a create path that starts an ownership helper container
- When helper create argv is built
- Then the helper uses `--entrypoint /bin/sleep` and `infinity`
- And the helper does not receive Feature entrypoint wrap argv

#### Scenario: recovery helper create stays sleep-only

- Given a recovery helper create
- When helper create argv is built
- Then the helper uses `--entrypoint /bin/sleep` and `infinity`
- And the helper does not receive Feature entrypoint wrap argv

#### Scenario: non-string Feature entrypoint fails closed

- Given Feature metadata whose `entrypoint` is a number, boolean, array, object, or null
- When Feature metadata is resolved
- Then the CLI fails with a structured Feature metadata error naming the feature ref and `entrypoint`
- And no managed container is created

#### Scenario: devcontainerId in Feature entrypoint expands at create

- Given a Feature `entrypoint` string containing `${devcontainerId}` and a known resource identity stem
- When main managed-container create argv is built
- Then the wrapper script contains the expanded stem
- And it does not leave a literal `${devcontainerId}` token

#### Scenario: Features Dockerfile has no ENTRYPOINT and recipeVersion is unchanged

- Given admitted Features with non-empty metadata `entrypoint`
- When the Features install Dockerfile is generated and derived-tag identity is computed
- Then the generated Dockerfile does not contain an `ENTRYPOINT` instruction from this change
- And product Features `recipeVersion` is the same constant as before this change

#### Scenario: overrideCommand policy is unchanged

- Given a valid image config with `overrideCommand: true`, and separately a valid image config with `overrideCommand: false`
- When config admission runs
- Then `true` remains a silent keep-alive restatement and does not by itself select Feature entrypoint wrap
- And `false` still fails closed because preserving the image command is unsupported

#### Scenario: image Dockerfile ENTRYPOINT and CMD stay discarded

- Given a base or derived image that declares Dockerfile `ENTRYPOINT` and/or `CMD`, with or without Feature `entrypoint` strings
- When main managed-container create argv is built
- Then create does not use the image `ENTRYPOINT`/`CMD` as PID 1
- And PID 1 is either keep-alive `/bin/sleep infinity` or the Feature entrypoint wrap then that keep-alive

#### Scenario: start does not remelt Feature entrypoint via exec

- Given a stopped managed container created with a non-empty Feature `entrypoint` wrap
- When the user runs `adevcontainer start` or `up` start-stopped
- Then Feature `entrypoint` is not executed via container exec
- And Feature onCreate / updateContent / postCreate still do not run on resume

#### Scenario: runArgs entrypoint remains rejected

- Given config `runArgs` that include `--entrypoint`
- When config admission runs
- Then the CLI fails closed and does not apply that flag to create

---

## MODIFIED Requirements

### Requirement: Merge feature metadata into create and lifecycle

After features are resolved (and before create for flag contributions; lifecycle hooks from features run after start, with installs already baked into the derived image), the CLI MUST merge **runtime contributions** from feature metadata (and SHOULD merge from image `devcontainer.metadata` label when present) into the effective create/lifecycle request:

| Contribution | Merge behavior |
|--------------|----------------|
| `init` | Effective create includes `--init` (union with config `runArgs` `--init`) |
| `capAdd` | Each capability mapped via the existing **cap-add allowlist path**; disallowed names fail closed with structured error |
| `containerEnv` | Merged into effective **runtime** create/exec env; **config `containerEnv` wins** on key conflict. Install-time availability of feature `containerEnv` is governed solely by **Derived image build** and MUST NOT reverse or weaken config-wins at runtime |
| mounts | Bind and volume only; sources normalized with **MountNormalizer** for file→dir promotion; incompatible mount types fail structured |
| `entrypoint` | Non-empty string values from Feature `devcontainer-feature.json` `entrypoint`, collected in Feature install order and applied only at main managed-container create per **Feature entrypoint wrap at main-container create**. Empty or absent values contribute nothing. MUST NOT be treated as a lifecycle hook, remelted via container exec on start, written as Dockerfile `ENTRYPOINT`, or applied to ownership/recovery helper creates. This change does not require merging `entrypoint` from image `devcontainer.metadata`. |
| lifecycle hooks contributed by features | Appended/merged into the create-path exec order after start (installs already in derived image); same string/argv/object-map forms and failure/delete-on-fail policy as config hooks for create-path failures. Feature `postStart` (and feature `postAttach` when postAttach runs) MUST remelt on resume per **Feature postStart remelt on resume** and [vscode.md](vscode.md) **postAttachCommand policy (CLI-only)**. Feature onCreate / updateContent / postCreate MUST NOT run on resume. |

Privileged / `securityOpt` contributions are warn-stripped and not applied to create (see warn-skip requirement); other contributions still merge.

**SHOULD:** If the base or derived image inspect shows a `devcontainer.metadata` label with JSON metadata, parse and merge compatible fields into the effective model. Absence of the label MUST NOT fail `up`. Compatible fields for that SHOULD do not include Feature `entrypoint` under this change.

#### Scenario: Feature init merges to create --init

- Given feature metadata with `init: true` and config without `--init` in runArgs
- When create argv is built after feature resolve
- Then create includes `--init`

#### Scenario: Feature capAdd uses allowlist path

- Given feature metadata `capAdd: ["SYS_PTRACE"]`
- When create argv is built
- Then cap-add is applied through the same allowlisted mapping as runArgs cap-add

#### Scenario: Config containerEnv wins over feature env

- Given feature metadata `containerEnv.FOO=from-feature` and config `containerEnv.FOO=from-config`
- When effective env is computed
- Then `FOO` is `from-config`

#### Scenario: Feature lifecycle hooks run on fresh create via exec

- Given feature metadata contributing a post-create-style lifecycle command and a fresh create path
- When `up` succeeds through create
- Then the contributed hook runs via runtime exec after start (features already installed in the derived image), and non-zero exit fails `up` under create-path policy

#### Scenario: Feature postStart remelts on start

- Given feature metadata contributing `postStart` and a stopped managed container from a prior successful create
- When the user runs `adevcontainer start` or `up` start-stopped
- Then the contributed postStart runs via runtime exec on this start

#### Scenario: start with unreadable config still runs metadata postStart

- Given a stopped managed container whose stamped config cannot be read and whose image `devcontainer.metadata` contributes `postStart`
- When the user runs `adevcontainer start --name <that-name>`
- Then after the container starts, feature-only postStart runs via container exec (`failKeepContainer`)
- And onCreate / updateContent / postCreate do not run
- And vscode customizations are not applied

#### Scenario: start with unreadable config still runs metadata postAttach on CLI attach

- Given a stopped managed container whose stamped config cannot be read and whose image `devcontainer.metadata` contributes `postAttach`
- When the user runs a real `adevcontainer start` (CLI-attach gate)
- Then feature-only postAttach runs via container exec (`failKeepContainer`)

#### Scenario: derived-image LABEL includes base-image postStart/postAttach after Features build

- Given a base image whose `devcontainer.metadata` contributes `postStart` / `postAttach` and a feature that also contributes those hooks
- When Features builds a derived image
- Then the derived `LABEL devcontainer.metadata` includes both the base-image and feature hooks

#### Scenario: no-features up runs image-metadata postCreate/postStart

- Given a config with empty `features` and a base image whose `devcontainer.metadata` contributes `onCreate` / `updateContent` / `postCreate` / `postStart` / `postAttach`
- When the user runs a fresh `up`
- Then those image-metadata hooks run via container exec on the create path (and postAttach as CLI attach)
- And Features `container build` does not run

#### Scenario: up finish still has base-image postAttach after remelt

- Given Features apply already unioned base-image `postAttach` into the create config
- When `up` finish remelts feature postAttach from image metadata that is features-only
- Then the base-image postAttach still runs (remelt unions, does not replace-away)

#### Scenario: devcontainer.metadata label merge when present

- Given a base image with a parseable `devcontainer.metadata` label
- When features/metadata merge runs
- Then compatible fields are merged into the effective model and `up` is not failed solely because the label existed

#### Scenario: Missing devcontainer.metadata label is OK

- Given no `devcontainer.metadata` label on the image
- When `up` runs with features
- Then absence alone does not fail `up`

#### Scenario: Feature entrypoint is collected in install order

- Given Features A then B in install order, A with non-empty metadata `entrypoint` and B omitting `entrypoint`
- When runtime contributions are merged before main create
- Then the collected Feature entrypoint list is A’s string only, in install order
- And B contributes no entrypoint

#### Scenario: empty Feature entrypoint contributes nothing

- Given Feature metadata with absent or empty `entrypoint` plus other contributions such as `init` or `containerEnv`
- When runtime contributions are merged
- Then those other contributions still merge as today
- And the Feature entrypoint list is empty

#### Scenario: Feature entrypoint is not merged as a lifecycle hook

- Given Feature metadata with a non-empty `entrypoint` and no lifecycle hook fields
- When runtime contributions are merged
- Then `entrypoint` is not appended to feature onCreate / updateContent / postCreate / postStart / postAttach command lists

## REMOVED Requirements

None.

# adevcontainer — runArgs and hostRequirements Specification

## Purpose

Allowlisted `runArgs` admission and create mapping, `hostRequirements` preflight with create limits, and dedicated fixtures for those surfaces.

## Requirements

### Requirement: runArgs allowlist and create mapping

The CLI MUST admit `runArgs` only when every entry matches the runArgs allowlist. Empty `runArgs` (`[]`) or omitted `runArgs` MUST be accepted. Allowlisted entries MUST be mapped onto Apple `container create` argv via AppleContainerRuntime / `CreateRequest` (no other module invents `container` flags).

**Allowlist (exact shapes)**

Each valued flag accepts `=VALUE` or two-token (`FLAG` + next array element) form unless noted. Two-token values MUST NOT start with `-`.

| Shape | createTokens / notes |
|-------|----------------------|
| `--init` | `--init`; at most once (duplicates MAY collapse) |
| `--cap-add=NAME` / two-token | `--cap-add`, `NAME` |
| `--cap-drop=NAME` / two-token | `--cap-drop`, `NAME` |
| `--shm-size=SIZE` / two-token | `--shm-size`, `SIZE` |
| `--dns=IP` / two-token | `--dns`, `IP` |
| `--dns-search=VAL` / two-token | `--dns-search`, `VAL` |
| `--dns-option=VAL` / two-token | `--dns-option`, `VAL` |
| `--dns-domain=VAL` / two-token | `--dns-domain`, `VAL` |
| `--no-dns` | `--no-dns` |
| `--ulimit=type=soft[:hard]` / two-token | `--ulimit`, value |
| `--tmpfs=PATH` / two-token | `--tmpfs`, path; if value contains `:`, take path before first `:` only (Docker opts stripped) |
| `--cpus=N` / `-c` / two-token | **No** createTokens; merge into `cpuLimit` (see memory/CPU merge) |
| `--memory=SIZE` / `-m` / two-token | **No** createTokens; merge into `memoryLimit` (see memory/CPU merge) |
| `--network=NAME` / two-token | `--network`, `NAME`; **named only** — warn-skip `host`, `bridge`, `none`, `container:*` (case-insensitive); empty name remains hard-error |
| `--rosetta` | `--rosetta` |
| `--ssh` | `--ssh` |
| `--read-only` | `--read-only` |

**Memory/CPU merge policy**

- `CreateRequest` already may set `memoryLimit`/`cpuLimit` from `hostRequirements`.
- If runArgs also supplies memory/cpus:
  - If hostRequirements set that dimension → **hostRequirements wins** (ignore runArgs for that dimension; MAY warn once on stderr)
  - If hostRequirements not set that dimension → apply runArgs value to `memoryLimit`/`cpuLimit` (normalize memory to Apple form when parseable)
- MUST NOT emit duplicate `-m`/`-c` from both runArgs createTokens and limits — memory/cpus MUST NOT contribute createTokens.

**Do NOT allow via runArgs** (prefer first-class config properties): `-e`/`--env`, `-u`/`--user`, `-w`/`--workdir`, `-p`/`--publish`, `-v`/`--volume`, `--mount`, `--name`, `--label`/`-l`, `-i`/`-t`/`-d`, `--rm`, `--entrypoint`.

**Warn-skip (do not apply; continue admission)** — known Apple-incompatible optional flags:

- `--privileged` and `--privileged=…`
- Any `--device`, `--device=…`, or `--device` + value token form
- `--security-opt`, `--gpus`, `--ipc`, `--pid`, `--userns`, `--cgroupns`, `--hostname`, `--add-host`, `--sysctl`, `--group-add`, `--runtime` (and `=…` / two-token forms)
- Network modes `host` / `bridge` / `none` / `container:*` (empty network name remains hard-error)

Each skipped entry MUST emit a stderr warning naming the entry and that it is ignored due to Apple container incompatibility. Skipped entries MUST NOT appear in effective runArgs or config hash material. Do **not** map `--privileged` → `--virtualization`.

**Still hard-error**

- First-class smuggling flags (`-e`/`-u`/`-w`/`-p`/`-v`/… listed above)
- Any other flag or bare token not consumed by the allowlist rules above
- Incomplete valued forms (e.g. bare `--cap-add` with no name)

Errors MUST name the offending `runArgs` entry and state allowlist or first-class collision policy.

#### Scenario: Allowlisted runArgs admit and map
- Given `runArgs`: `["--init", "--cap-add=NET_ADMIN", "--cap-add", "SYS_PTRACE", "--cap-drop=MKNOD"]`
- When config is resolved and a create request is built
- Then admission succeeds and create argv includes `--init` and the corresponding `--cap-add` / `--cap-drop` forms supported by the runtime mapper

#### Scenario: Wave A+B allowlisted flags admit and map
- Given `runArgs` including `--shm-size=64m`, `--dns=8.8.8.8`, `--tmpfs=/tmp:rw`, `--network=mynet`, `--rosetta`, `--ssh`, `--read-only`
- When config is resolved and a create request is built
- Then admission succeeds; create argv includes `--shm-size`/`64m`, `--dns`/`8.8.8.8`, `--tmpfs`/`/tmp` (opts stripped), `--network`/`mynet`, `--rosetta`, `--ssh`, `--read-only`

#### Scenario: runArgs memory/cpus merge
- Given no hostRequirements and `runArgs` `["--memory=2g", "--cpus", "2"]`
- When a create request is built
- Then create argv includes `-m`/`2G` (or equivalent) and `-c`/`2`, and does not also emit `--memory`/`--cpus` tokens
- Given hostRequirements memory/cpus set and runArgs also set memory/cpus
- When a create request is built
- Then hostRequirements values win for those dimensions

#### Scenario: Empty runArgs OK
- Given `"runArgs": []`
- When config is validated
- Then validation succeeds

#### Scenario: Warn-skip privileged keeps allowlisted flags
- Given `runArgs` including `--privileged` and `--init`
- When config is validated
- Then admission succeeds; effective runArgs contain only `--init`; stderr warns about `--privileged`

#### Scenario: Warn-skip device
- Given `runArgs` including `--device=/dev/net/tun:/dev/net/tun` (optionally with allowlisted flags)
- When config is validated
- Then admission succeeds; the device entry is absent from effective runArgs; stderr warns

#### Scenario: Warn-skip network=host and Docker-only modes
- Given `runArgs` including `--network=host` (or bridge/none/container:*) plus an allowlisted flag
- When config is validated
- Then admission succeeds; the Docker-only network mode is absent from effective runArgs; stderr warns

#### Scenario: Reject unknown flag
- Given `runArgs` including any non-allowlisted flag (e.g. `--not-a-real-flag`)
- When config is validated
- Then the CLI fails with a structured error naming that entry and stating it is not on the allowlist

#### Scenario: Reject dangling cap-add value
- Given `runArgs`: `["--cap-add"]` with no following name token
- When config is validated
- Then the CLI fails with a structured error for the incomplete `--cap-add` form

---

### Requirement: hostRequirements preflight and create limits

The CLI MUST evaluate `hostRequirements` during `up` preflight (not pure-ignore) **before** create/start/reuse paths. Supported keys:

| Key | Value | Behavior |
|-----|--------|----------|
| `memory` | String with size + unit: `gb`/`g`, `mb`/`m` (case-insensitive), e.g. `"8gb"`, `"8192mb"` | If host has enough: pass **requested** value to `container create` as `-m` / `--memory` (Apple suffixes `K,M,G,T,P`; e.g. `8gb` → `8G`). If host shortfall: **fail `up`** (do not create). |
| `cpus` | Number or numeric string (positive) | If host has enough: pass **requested** value to `container create` as `-c` / `--cpus`. If host shortfall: **fail `up`**. |
| `gpu` | Any present value | **Warn** that GPU requirements are unsupported; do **not** fail `up` solely for `gpu`; no create flags for gpu |

| Condition | Behavior |
|-----------|----------|
| Absent / empty `hostRequirements` | Do **not** pass `-m`/`-c`; Apple defaults |
| memory/cpus set AND host has capacity | Pass create limits; `up` may proceed |
| memory/cpus shortfall | **Fail `up`** with structured error naming the shortfall |
| Cannot read host memory/cpus when required | **Fail `up`** (cannot verify) |
| `gpu` only | Warn unsupported; does not fail alone; no create flags |

**Parse failures:** if `hostRequirements` is present but not an object, or a supported key has an unparseable value, or an **unknown** key appears inside the object, the CLI MUST **fail** with a structured error naming the property/field.

Host measurement source is implementation-defined but MUST be deterministic enough for tests to mock (e.g. injectable host info provider). Shortfall checks run on **every** `up`; create flags apply only on the create path (existing containers already carry limits).

Config hash material MUST include `hostRequirements` memory/cpus when set (limits affect create identity).

#### Scenario: Memory below requirement fails up
- Given `hostRequirements.memory` is `"8gb"` and the host reports less than 8 GiB
- When the user runs `up`
- Then `up` fails with a structured error naming `memory` / the requirement, and no container is created

#### Scenario: CPUs below requirement fails up
- Given `hostRequirements.cpus` is `4` and the host reports fewer than 4 CPUs
- When the user runs `up`
- Then `up` fails with a structured error naming `cpus`, and no container is created

#### Scenario: Enough host applies create limits
- Given `hostRequirements.memory` is `"8gb"` and `cpus` is `4` and the host meets both
- When the user runs `up` on a fresh create path
- Then create argv includes `-m`/`8G` (or equivalent) and `-c`/`4`, and `up` succeeds

#### Scenario: Absent hostRequirements omits create limits
- Given no `hostRequirements` key
- When a create request is built
- Then create argv does not include `-m` or `-c`

#### Scenario: Unparseable memory fails
- Given `hostRequirements.memory` is `"plenty"` (or another non-size string)
- When config is resolved
- Then the CLI fails with a structured error naming `hostRequirements.memory`

#### Scenario: Unknown hostRequirements key fails
- Given `hostRequirements` includes `"storage": "100gb"`
- When config is resolved
- Then the CLI fails with a structured error naming the unknown key

#### Scenario: GPU warns unsupported
- Given `hostRequirements.gpu` is present (e.g. `"optional"`) and memory/cpus are absent or satisfied
- When the user runs `up`
- Then stderr warns that GPU host requirements are unsupported and `up` is not failed solely for `gpu`

#### Scenario: Absent hostRequirements is no-op
- Given no `hostRequirements` key
- When config is resolved
- Then no hostRequirements error or warning is required

---

### Requirement: Lifecycle / runArgs / hostRequirements fixtures

The repository MUST provide pure JSON fixtures for lifecycle, runArgs, and hostRequirements surfaces:

| Path | Covers |
|------|--------|
| `Tests/Fixtures/lifecycle-hooks.json` | `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`; MAY include admitted `postAttachCommand` |
| `Tests/Fixtures/runargs-host.json` | Allowlisted `runArgs` and parseable `hostRequirements` (`memory` and/or `cpus`) |

Ordinary fixtures MUST NOT include Compose or unknown/first-class-smuggling runArgs (hard-error). Privileged/device family entries are valid warn-skip inputs (see warn-skip scenarios); keep default fixtures free of them unless exercising that path. They SHOULD remain Apple-container-runnable for optional integration tests.

#### Scenario: Lifecycle / runArgs / hostRequirements fixtures admit
- Given each lifecycle / runArgs / hostRequirements fixture file
- When parsed and validated under admission rules
- Then admission succeeds without unsupported-property errors

---

### Requirement: Top-level capAdd translation

The CLI MUST admit top-level `capAdd` only as an array of non-empty capability-name strings accepted by the existing `--cap-add` validation. Valid entries MUST normalize into the same typed effective capability representation and Apple create tokens used by allowlisted `runArgs --cap-add` and Feature/image `capAdd` contributions. The product MUST NOT pass raw array entries directly to Apple `container`.

Top-level and runArgs capability declarations MUST deduplicate by normalized capability name while preserving deterministic order. Equivalent config-time declarations through top-level `capAdd` and `runArgs --cap-add` MUST produce equivalent effective config hash material. Feature references/options remain their existing identity inputs even when a Feature capability contribution deduplicates against config-time capability behavior.

An omitted or empty top-level array MUST be a silent no-op. A non-array value, non-string entry, empty name, name beginning with `-`, or otherwise invalid capability name MUST fail with a structured error naming `capAdd` before create.

#### Scenario: Top-level capAdd maps through the typed create path

- Given a config with `capAdd: ["SYS_PTRACE", "NET_ADMIN"]`
- When the config is resolved and create argv is built
- Then effective capabilities contain both names and argv contains typed `--cap-add` pairs without raw passthrough

#### Scenario: Top-level and runArgs capAdd deduplicate

- Given otherwise identical configs where one declares `SYS_PTRACE` top-level and the other through allowlisted runArgs, including a config declaring both
- When effective config and hash material are produced
- Then all forms contain one normalized capability entry, equivalent config-time forms hash equally, and create argv contains one token pair

#### Scenario: Feature capability still preserves Feature identity

- Given top-level `capAdd` and an admitted Feature both contribute the same capability
- When Feature contributions merge
- Then create argv contains one capability token pair while the Feature ref/options remain in existing config and derived-image identity material

#### Scenario: Empty capAdd is silent

- Given `capAdd: []`
- When the config is resolved in default or strict mode
- Then resolution succeeds without a compatibility issue and no capability token is added

#### Scenario: Invalid capAdd blocks before create

- Given top-level `capAdd` is not an array or contains a non-string, empty, dash-prefixed, or invalid capability name
- When admission runs
- Then the CLI fails with a structured error naming `capAdd` and creates no container


# Proposal: Support top-level init and securityOpt

## Intent

`adevcontainer` rejects otherwise portable image-based Dev Container configurations that use the standard top-level `init` and `securityOpt` properties. This blocks all eleven current Bare Dev Container templates before create, even though Apple `container create` supports `--init` and the remaining template surface is usable.

## Scope

- Extend the supported top-level property surface in [core.md](../../../core.md) with Boolean `init` and string-array `securityOpt`.
- Make `init: true` contribute one effective init request, unioned and deduplicated with `runArgs` `--init` and Feature/image metadata init contributions; `init: false` contributes nothing and does not veto another source.
- Accept well-formed `securityOpt`, but strip every value from effective configuration; any non-empty array emits an explicit warning that it was not applied and, when present, that `no-new-privileges` is not enforced.
- Keep invalid shapes fail-closed and base config hashing on the normalized effective behavior represented by this change.
- Add test-first regression coverage for three equivalence classes spanning the active property patterns of the eleven current Bare templates: Debian, uv, and Go.

## Non-goals

- Enforcing `no-new-privileges`, emulating Docker security options, or inventing an unsupported Apple `container` flag.
- Supporting arbitrary security option semantics beyond validation followed by explicit warn-skip.
- Adding top-level `capAdd`, `remoteEnv`, `build`, Docker Compose, or OCI Template application to `adevcontainer`.
- Accepting unresolved `${templateOption:*}` tokens from template source files; fixtures represent configurations after an external template application step.
- Changing Feature identity inputs, Feature installation, named-volume ownership, VS Code customization behavior, container naming, or `${devcontainerId}` semantics.
- Editing the wiki or archiving this change as part of specification creation.

## Approach

Admit and validate both properties through the configuration boundary without weakening unknown-property fail-closed behavior. Normalize a true top-level init request into the existing effective init/create representation before config hashing, and retain the existing create mapping and Feature contribution merge. Validate top-level `securityOpt` as an array of strings, emit its user-facing warning once during resolution when non-empty, and discard it before the effective model, create request, and hash are produced.

## Decision index

- **Boolean init only:** `init` MUST be a Boolean; true requests init and false is an additive no-op.
- **Union rather than precedence:** top-level init, `runArgs` `--init`, and Feature/image init contributions form a Boolean union; no source can add a second create token and false does not disable another source.
- **Reuse the existing runtime mapping:** effective init remains represented by the existing allowlisted create behavior, avoiding a duplicate runtime DTO field or a new adapter flag.
- **Security options are admitted but not enforced:** a non-empty string array is accepted only to preserve portable-config usability; it is warn-stripped and MUST NOT imply that `no-new-privileges` is active.
- **Empty securityOpt is silent:** an empty array has no effect and emits no warning.
- **Malformed values fail closed:** non-Boolean init, non-array securityOpt, and non-string securityOpt entries produce structured errors naming the property.
- **Effective hash material:** one normalized config-time init behavior participates in hash material; duplicate top-level/runArgs declarations do not add duplicate material, false/absence are equivalent, and warn-stripped securityOpt contributes nothing. Existing Feature refs/options remain identity inputs under the realized Features contract.
- **Warning cardinality:** a non-empty top-level securityOpt array emits exactly one explicit warning per resolve despite pre- and post-substitution admission passes.
- **Bare template coverage by equivalence class:** Debian covers the common baseline, uv adds environment/one-volume/editor payloads, and Go adds multiple volumes/deep editor settings; duplicating all eleven upstream files would add maintenance without new property shapes.
- **Upstream baseline:** the compatibility inventory is anchored to `bare-devcontainer/templates@b6a41219` (`src/{bun,debian,deno,golang,mise,node,opentofu,rustup,terraform,uv,zig}/.devcontainer/devcontainer.json`), whose eleven published templates share the same active init/security defaults.
- **Active-change compatibility:** `friendly-container-name` governs create-name identity, occupancy, and `${devcontainerId}`; `workspace-parents-writable` governs create-path ownership. Neither changes init/security option semantics. This change is behaviorally separate, but its full replacement text for the existing **Supported property surface** requirement deliberately preserves the active friendly-name wording so the two live deltas do not contradict each other; it does not absorb the ownership delta.
- **No design.md:** the normalization, warn-skip boundary, and test matrix remain understandable in this decision index and the implementation tasks; the overflow rule is not met.

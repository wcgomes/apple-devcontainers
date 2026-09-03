# Proposal: Tolerant Dev Container configuration compatibility

## Intent

`adevcontainer` currently treats most recognized-but-unimplemented Dev Container properties the same as malformed or truly unknown input. This change establishes a semantic compatibility policy that keeps portable image-based configurations usable when omitted behavior is harmless or optional, while still blocking configurations that would become incoherent, unsafe, destructive, or materially misleading.

## Scope

- Modify [core.md](../../core.md) **Supported property surface**, **Unsupported property policy**, and **Top-level init and securityOpt behavior** to define exact translation, bounded emulation, harmless metadata, known optional degradation, and blocking outcomes.
- Add deterministic compatibility issue reporting with stable codes, property paths, dispositions, deduplication, redaction, and effective-config hash rules.
- Add opt-in strict automation through `ADEVCONTAINER_STRICT_COMPATIBILITY=1`, promoting reported compatibility degradation to a structured failure before the affected container create/start/reuse or destructive lifecycle action.
- Admit `$schema` as silent harmless metadata; admit object-shaped `otherPortsAttributes` and `secrets` as hash-neutral metadata with one warning when non-empty.
- Admit Boolean top-level `privileged`: false is a silent no-op; true is warn-stripped and never mapped to Apple virtualization or another privilege mechanism.
- Admit `overrideCommand: true` as a silent restatement of the existing keep-alive behavior; keep false blocking because the product does not preserve the image command.
- Add top-level `capAdd` as an exact typed translation through the existing capability/create representation, deduplicated with `runArgs` and Feature/image contributions.
- Re-route existing warn-skip and bounded-emulation paths through the compatibility issue model without weakening their realized effective behavior.

## Non-goals

- General Dockerfile or `build` support, legacy `dockerFile`/`context`, Docker Compose, multi-service orchestration, or choosing an image when the declared source selector cannot be represented.
- Private registry authentication, secret injection, secret prompting, or treating `secrets` metadata as credential values.
- `workspaceMount`, `remoteEnv`, `updateRemoteUserUID`, `appPort`, `overrideFeatureInstallOrder`, `type=tmpfs` mounts, arbitrary mount-option parity, or lifecycle/reuse/exec decoupling; each needs a separately bounded behavior contract.
- Raw Apple `container` argument passthrough, expansion of the existing runArgs allowlist, or permitting first-class properties to be smuggled through runArgs.
- Changing the realized default behavior of top-level `init` or `securityOpt`; only strict mode adds an explicit failure policy for the already-reported securityOpt degradation.
- Changing friendly create-name/resource identity or workspace-parent ownership behavior governed by the active `friendly-container-name` and `workspace-parents-writable` changes.
- Editing the wiki or archiving this change.

## Approach

Introduce a typed compatibility issue/report boundary shared by admission, resolution, Features metadata, runArgs, and bounded emulation paths. A registry classifies each recognized input by semantic consequence rather than by mere implementation status. Exact translations produce no issue; bounded emulation and known optional omissions produce deterministic issues; harmless metadata is silent; malformed or unrepresentable critical behavior remains a structured error. See [design.md](design.md) for the cross-phase collection, strict gate, migration, and security rationale.

## Decision index

- **Classify semantics, not key presence:** recognized inputs receive exact, emulated, ignored, or blocked dispositions based on observable consequences; harmless metadata is an additional silent class that produces no issue and is hash-neutral. Truly unknown non-metadata top-level keys remain blocked because their consequence cannot be classified.
- **Default mode stays fluid:** bounded emulation and known optional omissions warn once and continue with an explicit effective configuration.
- **Strict automation is opt-in:** `ADEVCONTAINER_STRICT_COMPATIBILITY=1` fails on reported degradation but not on silent harmless metadata or exact translations.
- **Stable compatibility issues:** each issue has a stable code, property path, disposition, and redacted message; duplicate admission passes do not duplicate output.
- **Effective hashes only:** exact translations and effective emulations hash their normalized behavior; ignored or harmless metadata and the selected strictness mode do not affect identity.
- **No broad passthrough:** Apple create tokens continue to originate only from typed runtime mappings and the existing runArgs allowlist.
- **First compatibility slice is deliberately small:** `$schema`, `otherPortsAttributes`, `secrets`, `privileged`, `overrideCommand: true` as a harmless keep-alive restatement, and top-level `capAdd` provide immediate interoperability without taking on build, workspace, Feature-order, or tmpfs redesign.
- **Security does not fail open:** privileged true is omitted rather than elevated; securityOpt remains explicitly unenforced; strict mode can reject either degradation before runtime action.
- **Active deltas remain independent:** this change preserves friendly-name wording in any full **Supported property surface** replacement and does not modify workspace ownership requirements.
- **Design overflow is triggered:** deterministic issue collection spans config admission, Features metadata, runArgs, command strictness, warning ordering, hashing, and security-sensitive migration; [design.md](design.md) retains that non-normative rationale without moving guarantees out of the spec.

## Clarifications

- **Q:** Should an arbitrary unknown top-level property become a warning?
  **A:** No. Only properties registered with known semantics may degrade; truly unknown non-metadata keys remain blocking to catch typos and unclassifiable security, workspace, or source-selection intent.
- **Q:** Which audited compatibility candidates belong in this first implementation?
  **A:** Include low-risk metadata/no-op properties and top-level `capAdd`; defer Dockerfile build, Feature-order override, tmpfs mounts, workspace/remote environment semantics, and lifecycle decoupling to later changes.
- **Q:** Should strict behavior be the default?
  **A:** No. Default behavior is tolerant and explicit; automation opts into strict mode through `ADEVCONTAINER_STRICT_COMPATIBILITY=1`.

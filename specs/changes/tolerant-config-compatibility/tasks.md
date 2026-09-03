# Tasks: tolerant-config-compatibility

Spec ref: `specs/changes/tolerant-config-compatibility/`. Execute test-first. Preserve the realized init/securityOpt default contract, existing runArgs allowlist, friendly-name/resource identity, and workspace ownership behavior. Do not add raw Apple CLI passthrough, Dockerfile build, Compose, private registry auth, complex workspace semantics, or any other non-goal.

## 1. Compatibility contract tests and fixture

- [x] 1.1 Add a pure JSON fixture containing `$schema`, non-empty `otherPortsAttributes`, non-empty recommendation-only `secrets`, `privileged: true`, `overrideCommand: true`, and top-level `capAdd` (path: `Tests/Fixtures/tolerant-compatibility.json`)
- [x] 1.2 Write failing unit tests for issue codes, dispositions, deterministic ordering, deduplication, redaction, QUIET behavior, and ignored/effective hash rules [P] (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 1.3 Write failing admission/resolution tests for harmless/empty metadata, non-empty metadata warnings, privileged true/false, overrideCommand true/false, malformed shapes, unknown keys, and unrepresentable selectors [P] (path: `Tests/adevcontainerTests/CompatibilityPolicyTests.swift`)
- [x] 1.4 Write failing tests for top-level capAdd mapping, validation, deduplication, create argv, and config-time hash equivalence with runArgs [P] (path: `Tests/adevcontainerTests/CompatibilityCapAddTests.swift`)
- [x] 1.5 Write failing command tests proving strict-mode gating for `up`, `clone`, `rebuild`, `start`, and `exec` occurs before mocked create/start/reuse-success/user-exec/build/delete and keeps property-specific malformed errors [P] (path: `Tests/adevcontainerTests/CompatibilityStrictModeTests.swift`)
- [x] 1.6 Register the new test collections and fixture checks in the suite of record (path: `Tests/adevcontainerTests/main.swift`)
- [x] 1.7 Run the registered compatibility tests and confirm each new test fails for the expected missing policy behavior before implementation (path: `Tests/adevcontainerTests/main.swift`)

## Checkpoint

- [x] verify **Default mode reports known degradation once**
- [x] verify **Compatibility warnings are deterministic**
- [x] verify **Compatibility warnings preserve terminal channels**
- [x] verify **Schema metadata is silent**
- [x] verify **Non-empty otherPortsAttributes degrades visibly**
- [x] verify **Secrets recommendations are not exposed**
- [x] verify **Privileged true is warn-stripped**
- [x] verify **Override command false remains blocking**
- [x] verify **Top-level capAdd maps through the typed create path**
- [x] verify **Top-level and runArgs capAdd deduplicate**
- [x] verify **Default tolerant mode continues**
- [x] verify **Strict mode blocks degradation before runtime effects**

## 2. Typed compatibility policy and top-level admission

- [x] 2.1 Add compatibility mode, disposition, issue, report, deterministic sort/dedup, redacted rendering, and strict-error value types (path: `Sources/ADevContainerLib/Config/CompatibilityPolicy.swift`)
- [x] 2.2 Classify registered top-level properties, validate new shapes, retain unknown/critical blockers, and stop direct warning emission during duplicate admission passes (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`)
- [x] 2.3 Normalize harmless/ignored metadata, privileged/override behavior, top-level capAdd, and config-level compatibility issues during resolution (path: `Sources/ADevContainerLib/Config/ConfigResolver.swift`)
- [x] 2.4 Extend the resolved model only with effective capability/report state required by the typed boundary, excluding raw ignored metadata (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [x] 2.5 Reuse capability-name validation and normalized `AllowlistedRunArg.capAdd` construction without opening generic runArgs passthrough (path: `Sources/ADevContainerLib/Config/RunArgs.swift`)
- [x] 2.6 Add the structured strict degradation error code and safe human/JSON fields (path: `Sources/ADevContainerLib/Errors/CLIError.swift`)

## Checkpoint

- [x] verify **Exact and harmless inputs do not warn**
- [x] verify **Ignored input is hash-neutral**
- [x] verify **Harmless false and empty forms are silent**
- [x] verify **Invalid metadata shapes remain blocking**
- [x] verify **Empty capAdd is silent**
- [x] verify **Invalid capAdd blocks before create**
- [x] verify **Truly unknown top-level property remains blocked**
- [x] verify **Malformed recognized property remains blocked**
- [x] verify **Unrepresentable source selector remains blocked**

## 3. Existing degradation producers and strict gates

- [x] 3.1 Route known-incompatible runArgs through typed compatibility issues while preserving the exact allowlist, skip set, contextual NET_ADMIN sidecar warning intent, and effective hash behavior [P] (path: `Sources/ADevContainerLib/Config/RunArgs.swift`)
- [x] 3.2 Route docker-* Feature admission skips through typed compatibility issues without changing admitted siblings or Feature identity [P] (path: `Sources/ADevContainerLib/Features/FeatureAdmission.swift`)
- [x] 3.3 Route Feature privileged/securityOpt metadata omissions through typed compatibility issues without applying either contribution [P] (path: `Sources/ADevContainerLib/Features/FeatureMetadata.swift`)
- [x] 3.4 Route image metadata privileged/securityOpt omissions through typed compatibility issues with existing redaction [P] (path: `Sources/ADevContainerLib/Features/DevContainerMetadataLabel.swift`)
- [x] 3.5 Route each file-bind promotion through one emulated compatibility issue carrying only safe path information permitted by existing mount warnings [P] (path: `Sources/ADevContainerLib/Config/MountNormalizer.swift`)
- [x] 3.6 Carry the shared compatibility report through Feature resolution and enforce metadata-stage strict mode before derived-image build/create (path: `Sources/ADevContainerLib/Features/FeaturesRunner.swift`)
- [x] 3.7 Enforce config-stage and Feature-stage strict gates before fresh-create, start-stopped, and reuse-success runtime effects [P] (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 3.8 Enforce config-stage and Feature-stage strict gates before clone create/build runtime effects [P] (path: `Sources/ADevContainerLib/Commands/CloneCommand.swift`)
- [x] 3.9 Enforce config-stage and Feature-stage strict gates before replacement build/delete/create runtime effects [P] (path: `Sources/ADevContainerLib/Commands/RebuildCommand.swift`)
- [x] 3.10 In strict mode, preflight stamped config and available image metadata before bare-start, already-running success, editor open, or hook execution while preserving default-mode best-effort loading [P] (path: `Sources/ADevContainerLib/Commands/StartCommand.swift`)
- [x] 3.11 Enforce the strict config compatibility gate before user environment probing or user command execution while preserving default-mode best-effort loading [P] (path: `Sources/ADevContainerLib/Commands/ExecCommand.swift`)

## Checkpoint

- [x] verify **Emulation hashes delivered behavior**
- [x] verify **Sidecar notices stay outside the issue vocabulary**
- [x] verify **Strict error aggregation is deterministic and redacted**
- [x] verify **Strict mode accepts exact and harmless inputs**
- [x] verify **Malformed input keeps its specific error**
- [x] verify **Feature capability still preserves Feature identity**
- [x] verify **Recognized optional property no longer blocks default mode**
- [x] verify **First-class runArg collision remains blocked**
- [x] verify **Existing Apple-incompatible optional inputs remain tolerant**
- [x] verify **Strict securityOpt blocks before runtime**

## 4. User-facing contract and regression coverage

- [x] 4.1 Document the strict environment switch, stable compatibility warning shape, tolerated property subset, and retained blockers in command help (path: `Sources/ADevContainerLib/Support/CommandSurface.swift`)
- [x] 4.2 Add command-level JSON/QUIET assertions proving compatibility warnings remain on stderr and strict errors remain structured (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`)
- [x] 4.3 Add regression assertions that supported existing configs, archived Bare fixtures, and the new compatibility fixture preserve realized init/securityOpt and identity behavior, and that `hostRequirements.gpu` plus vscode apply soft-skip notices remain sidecar rather than table codes (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint

- [x] verify **Expanded low-risk property surface admits**
- [x] verify **Material workspace or process mismatch remains blocked**
- [x] verify **Required host or protection semantics remain blocking**
- [x] verify **Minimal image config**
- [x] verify **Env user folder (connection vs create)**
- [x] verify **remoteUser without containerUser sets create -u**
- [x] verify **Mounts and ports**
- [x] verify **postCreate success**
- [x] verify **postCreate failure**
- [x] verify **Lifecycle runtime options runArgs and hostRequirements property set does not hard-error as unknown**
- [x] verify **initializeCommand waitFor userEnvProbe shutdownAction admit**
- [x] verify **features is on the supported surface**
- [x] verify **property surface admits vscode extensions and settings**
- [x] verify **top-level init and securityOpt are on the supported surface**
- [x] verify **Warn-skip docker-outside-of-docker**
- [x] verify **Non-ood features no longer rejected as blanket-unsupported**
- [x] verify **Warn-skip privileged runArgs**
- [x] verify **Warn-skip device runArgs**
- [x] verify **Reject Compose keys**
- [x] verify **customizations.vscode does not fail**
- [x] verify **parseable vscode customizations are applied per policy**
- [x] verify **Allowlisted cap-add no longer errors as unknown runArgs**
- [x] verify **hostRequirements no longer silently ignored**
- [x] verify **Top-level init true maps to create**
- [x] verify **Top-level init false is an additive no-op**
- [x] verify **Top-level and runArgs init deduplicate**
- [x] verify **Feature and image metadata init union with config init**
- [x] verify **Invalid init fails closed**
- [x] verify **Non-empty securityOpt warns without enforcement**
- [x] verify **Other securityOpt values warn and strip**
- [x] verify **Empty securityOpt is silent**
- [x] verify **Invalid securityOpt fails closed**
- [x] verify **Ignored securityOpt is hash-neutral**
- [x] verify default-mode warning output remains visible under QUIET and does not contaminate JSON stdout

## 5. Validation

- [x] 5.1 Run the full suite of record and confirm all compatibility scenarios pass or retain established platform skips (path: `Tests/adevcontainerTests/main.swift`)
- [x] 5.2 Build the Swift package and fix only failures introduced by this change (path: `Package.swift`)
- [x] 5.3 Inspect the final diff for scope exclusions, absence of raw passthrough, redaction, deterministic reporting, effective hashing, active-delta compatibility, and unresolved clarification markers (path: `specs/changes/tolerant-config-compatibility/spec.md`)

## Checkpoint

- [x] all normative scenarios map to passing tests
- [x] no unresolved clarification markers remain
- [x] `swift build` passes
- [x] `swift run adevcontainerTests` passes except established environment-gated skips
- [x] no production path emits raw unclassified Apple arguments
- [x] no wiki or unrelated active-change artifact is modified

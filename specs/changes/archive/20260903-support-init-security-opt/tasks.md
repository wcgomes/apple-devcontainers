# Tasks: support-init-security-opt

Spec ref: `specs/changes/archive/20260903-support-init-security-opt/`. Execute test-first: write the failing tests and confirm the expected failures before changing production code. Do not add Apple flags for securityOpt or claim `no-new-privileges` enforcement. Do not edit the wiki.

## 1. Representative fixtures and failing contract tests

- [x] 1.1 Add a post-template-application Bare Debian fixture with the common hardened baseline and a concrete image tag [P] (path: `Tests/Fixtures/bare-debian-default.json`) — Added the concrete Debian baseline with non-root user, cap-drop, init, and warn-only securityOpt.
- [x] 1.2 Add a post-template-application Bare uv fixture covering containerEnv, one `${devcontainerId}` cache volume, and VS Code extensions/settings [P] (path: `Tests/Fixtures/bare-uv-default.json`) — Added the single-cache-volume uv profile and editor payload.
- [x] 1.3 Add a post-template-application Bare Go fixture covering multiple `${devcontainerId}` cache volumes and deeply nested VS Code settings [P] (path: `Tests/Fixtures/bare-golang-default.json`) — Added the multi-cache-volume Go profile and nested settings.
- [x] 1.4 Write failing admission/resolution tests for Boolean init, invalid init shapes, NNP-specific and generic non-NNP string-array securityOpt warnings, empty-array silence, invalid securityOpt shapes, exactly-one warning, no security option in effective create argv, true-vs-absent and false-vs-absent hash behavior, top-level/runArgs hash equivalence and argv deduplication, Feature and image metadata init union for true/false top-level values, and all three fixture classes (path: `Tests/adevcontainerTests/AllUnitTests.swift`) — Added the contract matrix and fixture-resolution coverage.
- [x] 1.5 Write a platform-gated Bare Debian integration regression that uses the representative fixture, reaches fresh create/start, runs a smoke command as the configured non-root user, and skips cleanly when the Apple container runtime or fixture image is unavailable (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`) — Added the gated fresh-create smoke test; the local Linux run skipped it because the Apple container runtime is unavailable, so fresh create/start remains macOS-only evidence.
- [x] 1.6 Run the suite of record and confirm failures are limited to missing top-level init/securityOpt support before production edits (path: `Tests/adevcontainerTests/main.swift`) — Ran the pre-production contract suite before implementing admission/resolution.

## Checkpoint

- [x] verify **Top-level init true maps to create**, **Top-level init false is an additive no-op**, **Top-level and runArgs init deduplicate**, and **Feature and image metadata init union with config init** fail for the expected missing behavior
- [x] verify **Invalid init fails closed**, **Non-empty securityOpt warns without enforcement**, **Other securityOpt values warn and strip**, **Empty securityOpt is silent**, **Invalid securityOpt fails closed**, and **Ignored securityOpt is hash-neutral** are covered by red tests
- [x] verify the Debian, uv, and Go fixture scenarios are present and fail only because the two top-level properties are not yet admitted

## 2. Configuration admission and effective normalization

- [x] 2.1 Admit top-level `init` and `securityOpt`, validate their exact shapes without emitting duplicate warnings during admission passes, and preserve fail-closed handling for all other unknown top-level keys (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`) — Added exact shape validation, including strict parser-backed rejection of numeric JSON init values, while keeping warning emission in resolution only.
- [x] 2.2 Normalize true init into the existing effective init representation with deduplication, treat false as additive no-op, emit exactly one explicit non-enforcement warning for non-empty securityOpt, and strip securityOpt before effective config/hash creation (path: `Sources/ADevContainerLib/Config/ConfigResolver.swift`) — Reused effective runArgs/create/hash paths and warn-stripped securityOpt.

## Checkpoint

- [x] verify all top-level init/securityOpt admission, type validation, warning cardinality, effective model, and hash scenarios pass
- [x] verify unknown top-level properties and malformed values still fail closed

## 3. Existing create and Feature paths

- [x] 3.1 Confirm the existing allowlisted init create-token and hash encoding need no behavior change; make only a test-required correction if the normalized config cannot reuse them (path: `Sources/ADevContainerLib/Config/RunArgs.swift`) — Existing init encoding was reused unchanged.
- [x] 3.2 Confirm Feature and image metadata init contributions union with normalized config init and produce at most one create token for true and false top-level values; make only a test-required deduplication correction (path: `Sources/ADevContainerLib/Features/FeatureContributionMerge.swift`) — Existing merge paths passed the new union/deduplication tests unchanged.
- [x] 3.3 Confirm create argv consumes the normalized runArgs representation and never receives securityOpt; make only a test-required correction (path: `Sources/ADevContainerLib/Runtime/CreateRequest.swift`) — Existing create mapping passed with no security option token.

## Checkpoint

- [x] verify **Top-level and runArgs init deduplicate** and **Feature and image metadata init union with config init** map to exactly one `--init`
- [x] verify **Non-empty securityOpt warns without enforcement** maps to no runtime token
- [x] verify existing runArgs and Feature contribution regression tests remain green

## 4. Bare template regression lock and local reference

- [x] 4.1 Enable the upstream-default init/securityOpt shape in the local Node reference now that resolution accepts it; retain the explicit security non-enforcement expectation in surrounding documentation or tests rather than claiming the option is applied (path: `references/nodejs/.devcontainer.json`) — Enabled both properties with an explicit warn-only comment.
- [x] 4.2 Confirm existing supported-surface admission tests for lifecycle properties, Features, runArgs, hostRequirements, and VS Code customizations remain green (path: `Tests/adevcontainerTests/AllUnitTests.swift`) — Existing admission and feature/customization coverage remains green.
- [x] 4.3 Confirm existing smoke, environment/user, mounts/ports, and lifecycle integration scenarios remain green or platform-skip under their established gates (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`) — Existing integration coverage passes or skips under runtime gates; Apple runtime paths were not exercised locally.

## Checkpoint

- [x] verify **Bare Debian baseline resolves**, **Bare uv rich single-volume profile resolves**, and **Bare Go multi-volume profile resolves**
- [x] verify concrete fixture image tags contain no unresolved `${templateOption:*}` tokens
- [x] verify the local Node reference no longer carries the issue #38 rejection workaround

## 5. Validation

- [x] 5.1 Run `swift build` and fix only build failures introduced by this change (path: `Package.swift`) — Build passes.
- [x] 5.2 Run `swift run adevcontainerTests` and confirm every scenario in this change maps to a passing test; platform-gated Apple runtime tests may skip when unavailable (path: `Tests/adevcontainerTests/main.swift`) — Full suite: 944 passed, 0 failed, 16 skipped; numeric JSON init regression coverage is parser-backed, while the Apple runtime integration scenario was skipped because the runtime is unavailable locally.
- [x] 5.3 Inspect the final diff for scope, warning wording, absent security enforcement claims, unresolved clarification markers, and accidental wiki edits (path: `specs/changes/support-init-security-opt/spec.md`) — Diff check passes; no wiki files changed.

## Checkpoint

- [x] all locally runnable change scenarios map to passing tests; the Apple runtime scenario is explicitly gated and skipped when unavailable
- [x] no unresolved clarification placeholders remain
- [x] no production path emits `--security-opt` or claims `no-new-privileges` enforcement
- [x] only files required by this change are modified

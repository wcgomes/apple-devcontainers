# Tasks: align-remote-user-resolution

Spec ref: `specs/changes/align-remote-user-resolution/`  
Base contract: union of `specs/<domain>.md`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: repository root

Assume Swift 6.x / SPM already available. Test-first: write failing tests before implementation in each section. Mock `AppleContainerRuntime` image inspect so the default suite needs no real `container` runtime and no network. Do not hardcode product usernames (`vscode`, etc.) in resolution logic. Greenfield: no migration helpers for empty legacy labels.

## 1. Image inspect exposes OCI USER

- [x] 1.1 Write failing tests: successful image inspect JSON with `USER` / configuration user field populates `RuntimeImageInspection.user` (non-empty); successful inspect with missing/empty USER yields empty/nil user — **not** `"root"`; multi-shape payloads already accepted by inspect still parse (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 1.2 Write failing tests: inspect failure (non-zero runtime, unparseable JSON) throws structured error and does not return a fabricated user `root` (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 1.3 Extend `RuntimeImageInspection` with optional/empty `user` and parse OCI USER from Apple `container image inspect` JSON in `parseImageInspection` (path: `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift`)
- [x] 1.4 Update any test doubles / mock inspect fixtures that construct `RuntimeImageInspection` so existing suites compile (path: `Tests/adevcontainerTests/`)

## Checkpoint — inspect USER

- [x] verify **inspect exposes OCI USER**
- [x] verify **successful inspect with no USER is empty not root**
- [x] verify **inspect failure is distinct from empty USER**

---

## 2. Remote connection user resolution (pure)

- [x] 2.1 Write failing tests for precedence: `remoteUser` > `containerUser` > inspected OCI USER > `root`; trim/empty handling; never hardcoded `vscode` (path: `Tests/adevcontainerTests/AllUnitTests.swift` or new `Tests/adevcontainerTests/RemoteUserResolutionTests.swift`)
- [x] 2.2 Write failing tests: when config users empty and OCI USER provider **throws**, resolution fails (does not return `root`); when provider returns empty USER, resolution returns `root` (path: same as 2.1)
- [x] 2.3 Implement pure resolver API (e.g. on `DevContainerConfig` / small `RemoteUserResolution` helper) that takes config `remoteUser`/`containerUser` + OCI USER result/error and returns resolved connection user or throws (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift` and/or `Sources/ADevContainerLib/Config/RemoteUserResolution.swift`)
- [x] 2.4 Deprecate or narrow collapsed `effectiveUser` so call sites stop using it for create `-u`; keep a clearly named connection-user accessor used by exec/hooks/VS Code (path: `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)

## Checkpoint — resolution pure

- [x] verify **remoteUser wins over containerUser and OCI USER**
- [x] verify **containerUser used when remoteUser unset**
- [x] verify **OCI USER used when both config keys unset**
- [x] verify **root only after successful empty OCI USER**
- [x] verify **inspect failure does not become root**
- [x] verify **no hardcoded vscode default**

---

## 3. Create `-u` only for explicit `containerUser`

- [x] 3.1 Write failing tests: `CreateRequest.from` / `fromVolumeMode` set `user` **only** from non-empty `containerUser`; `remoteUser`-only → `user == nil` / no `-u` in `toCreateArgv`; both set → `-u` is `containerUser` (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 3.2 Implement create user wiring (stop passing connection-user / old `effectiveUser` into `CreateRequest.user`) (path: `Sources/ADevContainerLib/Runtime/CreateRequest.swift`)
- [x] 3.3 Fix command tests that assumed create `-u` from `remoteUser` alone (path: `Tests/adevcontainerTests/AllCommandTests.swift`, `Tests/adevcontainerTests/CloneInVolumeTests.swift`, `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift` as needed)

## Checkpoint — create user

- [x] verify **create -u only for explicit containerUser**
- [x] verify **create -u when containerUser set**
- [x] verify **both unset omits create -u**

---

## 4. Stamp non-empty `devcontainer.remote_user` + success JSON

- [x] 4.1 Write failing tests: bind-mode label build stamps non-empty resolved connection user; empty string stamp on successful create is forbidden (path: `Tests/adevcontainerTests/AllUnitTests.swift` / `AllCommandTests.swift`)
- [x] 4.2 Write failing tests: `up` create path resolves connection user (mock inspect when config users empty), stamps label, success JSON `remoteUser` matches (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 4.3 Write failing tests: `clone` and `rebuild` stamp/JSON use resolved connection user; rebuild drift updates `devcontainer.remote_user` (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`, `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)
- [x] 4.4 Wire resolution + inspect into `UpCommand` / `CloneCommand` / `RebuildCommand` before label build and create; pass resolved user into `ContainerIdentity.bindModeLabels` / `volumeModeLabels` (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`, `CloneCommand.swift`, `RebuildCommand.swift`, `Sources/ADevContainerLib/Runtime/ContainerIdentity.swift`)
- [x] 4.5 Success result builders (`UpResult` / `CloneResult` / `RebuildResult`) emit resolved connection user, never empty-on-success when resolution succeeded (path: same command files + `Sources/ADevContainerLib/Model/`)

## Checkpoint — stamp + JSON

- [x] verify **Up create stamps non-empty remote_user from resolution**
- [x] verify **Clone create stamps remoteUser when set**
- [x] verify **Rebuild refreshes remote_user to newly resolved connection user**
- [x] verify **success JSON remoteUser reflects OCI fallback**

---

## 5. Exec, lifecycle hooks, VS Code consumers

- [x] 5.1 Write failing tests: `ExecCommand` still prefers non-empty `devcontainer.remote_user` label; documents empty → omit (legacy) (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 5.2 Write failing tests: `LifecycleRunner` exec user is resolved connection user (`remoteUser` over `containerUser`) (path: `Tests/adevcontainerTests/AllCommandTests.swift` or lifecycle tests in `AllUnitTests.swift`)
- [x] 5.3 Write failing tests: `VSCodeOpen.bestEffortOpen` writes nameConfig **before** launcher `code` invoke; nameConfig `remoteUser` is connection user; open still attempted if nameConfig write fails (path: `Tests/adevcontainerTests/VSCodeOpenTests.swift`)
- [x] 5.4 Write failing tests: settings/extensions apply and postAttach gate use connection user when `remoteUser` ≠ `containerUser` (path: `Tests/adevcontainerTests/VSCodeCustomizationsApplyTests.swift`, `VSCodeCustomizationsCommandTests.swift`)
- [x] 5.5 Implement nameConfig-before-launch ordering in `VSCodeOpen.bestEffortOpen` (path: `Sources/ADevContainerLib/Support/VSCodeOpen.swift`)
- [x] 5.6 Point `LifecycleRunner`, `VSCodeCustomizationsApply`, and command VS Code targets at connection-user accessor / stamped label (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`, `Sources/ADevContainerLib/Support/VSCodeCustomizationsApply.swift`, `UpCommand.swift`, `StartCommand.swift`, `CloneCommand.swift`, `RebuildCommand.swift`)
- [x] 5.7 Confirm `ExecCommand` remains label-driven (no ConfigResolver); only relies on non-empty stamps from new creates (path: `Sources/ADevContainerLib/Commands/ExecCommand.swift`)

## Checkpoint — consumers

- [x] verify **Exec uses stamped resolved remote connection user**
- [x] verify **nameConfig written before code launch**
- [x] verify **nameConfig remoteUser matches stamp not hardcoded**
- [x] verify **postAttach runs as remote connection user not containerUser**
- [x] verify **settings apply under remote connection user home**
- [x] verify **remoteUser without containerUser does not set create -u**

---

## 6. Features Dockerfile final USER restore

- [x] 6.1 Write failing tests: generated Dockerfile contains `USER root` before install RUNs and ends with `USER <baseUser>` when base USER is non-empty; does not end on `USER root` when base is `node` (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 6.2 Write failing tests: base USER empty after successful inspect → final default is `root` (or equivalent empty-USER semantics) without leaving an accidental final `USER root` only because install used root when a non-root base USER existed (path: same)
- [x] 6.3 Write failing tests: base inspect failure during Features generate/build fails structured (path: same / Features runner tests)
- [x] 6.4 Implement final USER restore in `FeatureDockerfileGenerator.write` using inspected base USER; thread inspect into `FeaturesRunner` (path: `Sources/ADevContainerLib/Features/FeatureDockerfileGenerator.swift`, `FeaturesRunner.swift`)
- [x] 6.5 Bump `DerivedImageTag.recipeVersion` for install-Dockerfile semantic change (path: `Sources/ADevContainerLib/Features/DerivedImageTag.swift`)
- [x] 6.6 Ensure `FeatureOptions.userInstallEnvironment` does not hardcode editor usernames; root fallback only per Features contract after empty resolution inputs (path: `Sources/ADevContainerLib/Features/FeatureOptions.swift`)

## Checkpoint — Features USER

- [x] verify **Features Dockerfile ends with base USER not root**
- [x] verify **Features restore fails closed on base inspect failure**
- [x] verify **derived image default user matches base after Features**
- [x] verify `recipeVersion` bumped

---

## 7. Integration / regression gate

- [x] 7.1 Update fixture-driven expectations for `Tests/Fixtures/env-user.json` (both users `vscode`: create `-u`, stamp, JSON) (path: `Tests/adevcontainerTests/AllCommandTests.swift`, `AllIntegrationTests.swift` as applicable)
- [x] 7.2 Grep regression: no create path passes `remoteUser` into `CreateRequest.user`; no resolution default string `vscode`; no Features Dockerfile that ends on `USER root` when base USER was non-root (path: `Sources/`)
- [x] 7.3 Run full default suite `swift run adevcontainerTests`; fix regressions (path: `Tests/adevcontainerTests/`)

## Checkpoint — suite

- [x] verify **Env user folder (connection vs create)**
- [x] verify default `swift run adevcontainerTests` green
- [x] verify scenarios in change `spec.md` ADDED + MODIFIED covered by tests above

---

## 8. Docs note (product-facing, optional in this change)

- [x] 8.1 [P] README / help: brief note that `remoteUser` is connection/exec/attach, `containerUser` alone sets create `-u`, and omitted users fall back to image USER then `root` (path: `README.md`, `Sources/ADevContainerLib/Support/CommandSurface.swift` if help mentions users)
- [x] 8.2 Domain fold + archive are **out of this task set** (implementer lands contract after code; coordinator archives). Do not move this folder to `specs/changes/archive/` here.

## Checkpoint — docs

- [x] verify README does not claim create `-u` from `remoteUser` alone
- [x] verify no wiki edits required for this Lite change

---

## 9. Review-gap close: metadata users + Features install env base USER

- [x] 9.1 Parse `remoteUser`/`containerUser` from image `devcontainer.metadata` (last non-empty across array fragments) via `DevContainerMetadataLabel` (path: `Sources/ADevContainerLib/Features/DevContainerMetadataLabel.swift`)
- [x] 9.2 Merge metadata users into `RemoteUserResolution` after local config, before OCI USER; Features pass base metadata (derived may lack label) (path: `RemoteUserResolution.swift`, `FeaturesRunner.swift`, `UpCommand`/`CloneCommand`/`RebuildCommand`)
- [x] 9.3 `FeatureOptions.userInstallEnvironment` falls back to inspected base USER (not unconditional root) when config users empty; Dockerfile generator passes `baseUser` (path: `FeatureOptions.swift`, `FeatureDockerfileGenerator.swift`)
- [x] 9.4 Tests: metadata remoteUser over OCI root; local wins; array last-wins; Features install env base USER; clone stamp remoteUser; up metadata path (path: `RemoteUserResolutionTests.swift`, `AllCommandTests.swift`, `CloneInVolumeTests.swift`, `AllUnitTests.swift`)
- [x] 9.5 Evolve change `spec.md` for metadata tier + install-env base USER; run `swift run adevcontainerTests`

## Checkpoint — review gaps

- [x] verify **metadata remoteUser when config users empty**
- [x] verify **local config wins over metadata remoteUser**
- [x] verify **Features install env uses base USER when config users empty**
- [x] verify default suite green

(End of file)

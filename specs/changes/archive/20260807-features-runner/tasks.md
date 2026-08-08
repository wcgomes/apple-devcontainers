# Tasks: features-runner

Spec ref: `specs/changes/archive/20260807-features-runner/` (archived; live contract: union of `specs/<domain>.md`)  
Base contract: union of `specs/<domain>.md`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: `/Users/wyller/Repos/dev-containerization/`  

Assume Swift 6.x / SPM and Apple `container` already on the host. Do **not** install toolchains, ORAS, Node, or run network package installs as task steps. Test-first: write failing tests before implementation in each section.

---

## 1. Features fixture

- [x] 1.1 Add Features fixture with valid `image` and only an OCI Node feature ref (+ options if useful); never docker-ood, privileged, device, or Compose (path: `Tests/Fixtures/features-node.json`)
- [x] 1.2 [P] Confirm existing fixtures remain present and free of accidental features/ood (path: `Tests/Fixtures/`)

## Checkpoint — fixtures
- [x] `features-node.json` is pure JSON and matches change spec table
- [x] No fixture contains docker-outside-of-docker as a positive install path (reject fixture `features-docker-ood.json` is OK)

---

## 2. Admit `features` + forever-reject policy (test-first)

- [x] 2.1 Write failing tests: OCI feature ref + options object admits; empty `{}` OK; omitted OK (path: `Tests/adevcontainerTests/AllUnitTests.swift` or dedicated Features admission section)
- [x] 2.2 Write failing tests: local path `./…` / absolute / `file://` admit; missing package fails at load; non-object `features` fails (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 2.3 Write failing tests: any ref containing `docker-outside-of-docker`, `docker-in-docker`, or `docker-from-docker` forever-rejects (ghcr and alternate host/tag shapes) (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 2.4 Remove blanket “any features entry rejected” path; parse `features` map into resolved model (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`, `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)
- [x] 2.5 Wire resolver to populate admitted features after substitution where string options need it (path: `Sources/ADevContainerLib/Config/ConfigResolver.swift`)
- [x] 2.6 Update unsupported-property / error copy so non-ood OCI and local features are not described as post-MVP unsupported (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`, `Sources/ADevContainerLib/Errors/CLIError.swift`)
- [x] 2.7 Add `features` to supported top-level keys set (path: `Sources/ADevContainerLib/Config/ConfigAdmissions.swift`)

## Checkpoint — admission
- [x] verify **OCI feature ref with options admits**
- [x] verify **Empty features object is no-op**
- [x] verify **Local path feature admits**
- [x] verify **features must be an object**
- [x] verify **Reject docker-ood / docker-in-docker / docker-from-docker under any registry/tag**
- [x] verify **Non-ood features no longer rejected as blanket-unsupported**
- [x] `Tests/Fixtures/features-node.json` admits at parse/admission layer

---

## 3. Feature model, metadata types, dependency order (test-first)

- [x] 3.1 Write failing tests: parse `devcontainer-feature.json` fixture blobs (id, options, dependsOn, installsAfter, init, capAdd, containerEnv, mounts, privileged, securityOpt, lifecycle contributions) (path: `Tests/adevcontainerTests/AllUnitTests.swift`; sample JSON under `Tests/Fixtures/` or test resources as needed)
- [x] 3.2 Write failing tests: dependsOn / installsAfter ordering; cycle detection fails (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 3.3 Write failing tests: privileged true / securityOpt present → structured forever-reject (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 3.4 Implement feature metadata model + parser (path: `Sources/ADevContainerLib/Features/FeatureMetadata.swift` or under `Config/` if thinner layout preferred — keep Features code cohesive)
- [x] 3.5 Implement install order resolver (dependsOn, installsAfter, tie-break) (path: `Sources/ADevContainerLib/Features/FeatureOrder.swift`)
- [x] 3.6 Options → install env / substitution helper for install.sh contract (path: `Sources/ADevContainerLib/Features/FeatureOptions.swift`)

## Checkpoint — metadata & order
- [x] verify **dependsOn orders install before dependent**
- [x] verify **installsAfter respected**
- [x] verify **Dependency cycle fails**
- [x] verify **Reject privileged feature metadata**
- [x] verify **Missing devcontainer-feature.json fails** (with fixture-missing case)

---

## 4. OCI artifact fetch (embedded, mockable) (test-first)

- [x] 4.1 Define `FeatureFetching` protocol (or equivalent) with mock for tests (path: `Sources/ADevContainerLib/Features/FeatureFetching.swift`)
- [x] 4.2 Write failing tests: successful fetch returns files including `devcontainer-feature.json` + `install.sh`; 404/network errors map to structured CLIError (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 4.3 Implement HTTPS/registry API client sufficient to pull feature OCI artifact layers/files (no ORAS CLI; no Node) (path: `Sources/ADevContainerLib/Features/OCIFeatureClient.swift`)
- [x] 4.4 Cache/scratch directory layout for fetched features (implementation-defined under product control; document in code) (path: `Sources/ADevContainerLib/Features/FeatureCache.swift`)
- [x] 4.5 Ensure fetch path is **not** `container image pull` for feature artifacts; keep all `container` subprocesses in AppleContainerRuntime only (path: `Sources/ADevContainerLib/Features/`, `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift`)
- [x] 4.6 DefaultFeatureFetcher: local path resolve + copy; OCI via embedded client (path: `Sources/ADevContainerLib/Features/`)

## Checkpoint — fetch
- [x] verify **Fetch invokes embedded registry client not container pull for artifacts**
- [x] verify **Fetch 404 is structured failure**
- [x] verify **Unit tests mock fetch without network**
- [x] verify **Local path load from features-sample fixtures**
- [x] Grep: no ORAS shell-out; no Node; no `container` subprocess outside AppleContainerRuntime

---

## 5. Dockerfile generation + deterministic tag (test-first)

- [x] 5.1 Write failing tests: generated Dockerfile `FROM` user image; per-feature COPY + RUN install.sh as root; options/env wiring (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 5.2 Write failing tests: deterministic tag from config hash + features hash; options change ⇒ tag change (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 5.3 Implement Dockerfile + build context writer (path: `Sources/ADevContainerLib/Features/FeatureDockerfileGenerator.swift`)
- [x] 5.4 Implement derived image tag computation; include features in config hash material (path: `Sources/ADevContainerLib/Features/DerivedImageTag.swift`, `Sources/ADevContainerLib/Config/DevContainerConfig.swift`)

## Checkpoint — Dockerfile & tag
- [x] verify **install.sh runs as root in generated Dockerfile**
- [x] verify **Feature option change produces new tag**
- [x] verify **Features participate in identity hash**

---

## 6. `container build` + reuse via AppleContainerRuntime (test-first)

- [x] 6.1 Write failing tests with mock ProcessRunning/runtime: build invoked when tag missing; skipped when tag exists (path: `Tests/adevcontainerTests/AllUnitTests.swift` and/or `AllCommandTests.swift`)
- [x] 6.2 Add runtime API for image build + image exists/inspect-by-ref as needed (path: `Sources/ADevContainerLib/Runtime/AppleContainerRuntime.swift`)
- [x] 6.3 Implement FeaturesRunner orchestrating resolve → fetch → tag check → build → derived image ref (path: `Sources/ADevContainerLib/Features/FeaturesRunner.swift`)
- [x] 6.4 Map build failures to structured CLIError (path: `Sources/ADevContainerLib/Errors/CLIError.swift`)
- [x] 6.5 Host-native `--platform` on pull/build/create; no `--rosetta` by default; build.rosetta consent gate (path: FeaturesRunner / AppleContainerConfig)

## Checkpoint — build/reuse
- [x] verify **Derived image used on create** (with mocks)
- [x] verify **Existing derived tag skips rebuild**
- [x] verify **Build goes through AppleContainerRuntime**
- [x] verify **Platform linux/arm64 on arm64 hosts; build.rosetta consent**

---

## 7. Merge feature contributions into create + lifecycle (test-first)

- [x] 7.1 Write failing tests: feature `init` → create `--init`; `capAdd` via allowlist path; disallow bad caps (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 7.2 Write failing tests: `containerEnv` merge with config wins on conflict; mounts via MountNormalizer-compatible path (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 7.3 Write failing tests: feature lifecycle hooks merge into create-path exec order; failure participates in delete-on-fail (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 7.4 Implement merge into CreateRequest / resolved effective config (path: `Sources/ADevContainerLib/Features/FeatureContributionMerge.swift`, `Sources/ADevContainerLib/Runtime/CreateRequest.swift`)
- [x] 7.5 SHOULD: read/merge `devcontainer.metadata` label when present on image inspect; absence OK (path: `Sources/ADevContainerLib/Features/DevContainerMetadataLabel.swift`, runtime inspect helpers)
- [x] 7.6 Wire merged hooks through LifecycleRunner / UpCommand without breaking existing matrix (path: `Sources/ADevContainerLib/Commands/LifecycleRunner.swift`, `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 7.7 Expand `${PATH}` / `$PATH` in containerEnv on create (path: `Sources/ADevContainerLib/Runtime/CreateRequest.swift`)

## Checkpoint — merge
- [x] verify **Feature init merges to create --init**
- [x] verify **Feature capAdd uses allowlist path**
- [x] verify **Config containerEnv wins over feature env**
- [x] verify **Feature lifecycle hooks run on fresh create via exec**
- [x] verify **devcontainer.metadata label merge when present**
- [x] verify **Missing devcontainer.metadata label is OK**

---

## 8. UpCommand Features path + progress (test-first)

- [x] 8.1 Write failing tests: fresh create with features → runner before create; create image is derived tag (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 8.2 Write failing tests: no features → no runner build; reuse running → no fetch/build (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 8.3 Write failing tests: progress status lines for resolve/fetch/build/reuse; quiet suppresses (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 8.4 Wire FeaturesRunner into `up` before create; pass derived image into CreateRequest (path: `Sources/ADevContainerLib/Commands/UpCommand.swift`)
- [x] 8.5 Emit Features progress via StatusPrinter (`==> Resolving features`, fetching, building, reusing) (path: `Sources/ADevContainerLib/Support/StatusPrinter.swift`, FeaturesRunner / UpCommand)

## Checkpoint — up path
- [x] verify **Up with features builds then creates**
- [x] verify **Up without features unchanged image path**
- [x] verify **Reuse running does not re-fetch features**
- [x] verify **Progress lines during feature up**
- [x] verify **Quiet suppresses features progress**
- [x] verify **Create then reuse still stable** with features identity

---

## 9. Integration and suite wiring

- [x] 9.1 Register new unit/command tests in suite entrypoints (path: `Tests/adevcontainerTests/main.swift`, `AllUnitTests.swift`, `AllCommandTests.swift`)
- [x] 9.2 Optional integration: OCI fixtures against real registry + Apple `container` when `ADEVCONTAINER_FEATURES_E2E=1`; local path E2E always when runtime available (path: `Tests/adevcontainerTests/AllIntegrationTests.swift`)
- [x] 9.3 Run full suite: `swift run adevcontainerTests` (path: package root)

## Checkpoint — suite
- [x] Full MiniTest suite green offline (mocks + local fixtures) — ~156+ passed
- [x] OCI E2E skips cleanly without `ADEVCONTAINER_FEATURES_E2E=1`; local E2E runs when Apple `container` up
- [x] Core + lifecycle/runArgs/host scenarios remain green (no regression)
- [x] verify **Offline unit suite** and **OCI integration skips without network gate**

---

## 10. Realized contract + docs touchpoints (no scope creep)

- [x] 10.1 Merge Features delta into realized contract after implementation lands (path: `specs/features.md`)
- [x] 10.2 README + wiki: OCI **and** local path Features runner, docker-* forever-reject markers, build.rosetta consent, native arm64 `container build`, fixtures, test guidance (path: `README.md`, `wiki/**`)
- [x] 10.3 Do **not** implement: docker-ood / docker-in-docker / docker-from-docker install path, privileged/device, Compose, feature publish CLI, ORAS install, Node runtime. **Local path features are supported** (shipped).

## Checkpoint — closeout
- [x] Realized spec matches shipped behavior
- [x] Non-goals respected (local path is in scope and shipped)
- [x] Archive this change folder under `specs/changes/archive/` when closing (coordinator/process)

---

## Implementation notes (locked — shipped behavior)

| Topic | Decision |
|-------|----------|
| Change id | `features-runner` (capability-named; not phase-branded) |
| Admit `features` | Yes — object map feature ref → options |
| Local path features | **Supported** — `./`, `../`, absolute `/`, `file://` via DefaultFeatureFetcher (workspace-relative) |
| OCI refs | Supported — embedded HTTPS/registry client |
| docker-* markers | Forever-reject if ref contains `docker-outside-of-docker`, `docker-in-docker`, or `docker-from-docker` |
| privileged / securityOpt in feature metadata | Forever-reject |
| Fetch | Embedded HTTPS/registry API for OCI; disk copy for local; mockable; not `container image pull` for artifacts |
| Build | Generated Dockerfile + `container build --platform` host-native via AppleContainerRuntime; no `--rosetta` by default |
| build.rosetta | One-time consent when true/missing; silent if already false; env `ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE=1` for CI |
| install.sh | RUN as root |
| Tag | Deterministic from config hash + features hash (`adevcontainer/features:<hash>`); reuse if exists |
| Create image | Derived tag when features non-empty; same `--platform` |
| PATH expansion | Expand `${PATH}` / `$PATH` in containerEnv on create |
| capAdd / init | Merge via existing allowlist / create mapping |
| containerEnv conflict | Config wins |
| mounts | Bind/volume only; MountNormalizer |
| Feature lifecycle hooks | Exec after container up; create-path failure policy unchanged |
| `devcontainer.metadata` label | SHOULD merge when present |
| Progress | Resolving / Fetching / Building / Reusing; quiet honored |
| ORAS / Node | No external ORAS; no Node for CLI |
| Fixtures | `features-node`, `features-triple`, `features-local`, `features-docker-ood`, `features-sample/*` |
| Tests | ~156+ offline; local E2E when runtime; OCI E2E needs `ADEVCONTAINER_FEATURES_E2E=1` |
| Test runner | `swift run adevcontainerTests` |
| Paths | Library under `Sources/ADevContainerLib/`; Features subsystem under `Sources/ADevContainerLib/Features/`; do not put logic only in thin executable entry |

(End of file)

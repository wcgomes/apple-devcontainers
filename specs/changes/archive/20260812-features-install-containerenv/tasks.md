# Tasks: features-install-containerenv

Spec ref: `specs/changes/features-install-containerenv/`  
Base contract: union of `specs/<domain>.md`  
Binary: `adevcontainer`  
Library: `Sources/ADevContainerLib/`  
Tests: `Tests/adevcontainerTests/` (MiniTest; run with `swift run adevcontainerTests`)  
Package root: repository root

Assume Swift 6.x / SPM already available. Test-first: write failing tests before implementation in each section. No network / real `container` required for default suite. Do not change runtime config-wins merge. Do not archive or fold domain specs in this task set.

## 1. Install env includes feature containerEnv (failing tests)

- [x] 1.1 Write failing tests: generated Dockerfile / install env for a feature with metadata `containerEnv` (e.g. `DOTNET_ROOT=/usr/share/dotnet`) exposes those keys to `./install.sh` (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 1.2 Write failing tests: absent/empty feature `containerEnv` → install env is options + `_REMOTE_USER` / `_CONTAINER_USER` (+ homes) only; no spurious keys (path: same)
- [x] 1.3 Write failing tests: non-empty `containerEnv` coexists with option-derived keys and user install keys in the same install layer (path: same)
- [x] 1.4 Write failing tests: runtime merge still config-wins (`FOO` from config beats feature) — regression lock, expect pass before/after (path: same or existing merge tests)

## Checkpoint — install env tests red on new behavior

- [x] verify **install sees feature containerEnv** fails under current generator
- [x] verify **empty containerEnv unchanged** and **install env still has options and user keys** encoded as tests
- [x] verify **runtime merge still config-wins (no change)** still green

---

## 2. Implement install-time containerEnv

- [x] 2.1 Extend install-env assembly so each feature layer includes that feature’s `metadata.containerEnv` alongside `FeatureOptions.installEnvironment` and `userInstallEnvironment` (path: `Sources/ADevContainerLib/Features/FeatureDockerfileGenerator.swift`, `FeatureOptions.swift` as needed)
- [x] 2.2 Update `FeatureOptions.installEnvironment` comment/docs that currently say containerEnv is runtime-only merge (path: `Sources/ADevContainerLib/Features/FeatureOptions.swift`)
- [x] 2.3 Keep install as root + final base `USER` restore; do not inject config-file `containerEnv` into the Dockerfile (path: `FeatureDockerfileGenerator.swift`)
- [x] 2.4 Make tests from §1 green (path: `Tests/adevcontainerTests/AllUnitTests.swift`)

## Checkpoint — install env green

- [x] verify **install sees feature containerEnv**
- [x] verify **empty containerEnv unchanged**
- [x] verify **install env still has options and user keys**
- [x] verify **runtime merge still config-wins (no change)**

---

## 3. recipeVersion bump (install-Dockerfile epoch)

- [x] 3.1 Write/adjust tests: product `DerivedImageTag.recipeVersion` equals current epoch; same base+features with prior vs current yield different tags (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 3.2 Bump `DerivedImageTag.recipeVersion` on install-Dockerfile semantic change; refresh epoch comment (path: `Sources/ADevContainerLib/Features/DerivedImageTag.swift`)
- [x] 3.3 Fix any hard-coded prior-epoch expectations in the suite (path: `Tests/adevcontainerTests/`)

## Checkpoint — tag invalidation

- [x] verify **recipeVersion bump invalidates derived tags**
- [x] verify **same recipeVersion keeps derived tag stable** (existing scenario still holds at current epoch)

---

## 4. Suite / regression gate (initial land)

- [x] 4.1 Grep regression: install path includes feature `containerEnv`; runtime merge path still config-wins; no accidental config `containerEnv` forced into install Dockerfile (path: `Sources/ADevContainerLib/Features/`)
- [x] 4.2 Run full default suite `swift run adevcontainerTests`; fix regressions (path: `Tests/adevcontainerTests/`)
- [x] 4.3 Domain fold + archive are **out of this task set** (land contract after code; coordinator archives). Do not move this folder to `specs/changes/archive/` here.

## Checkpoint — initial land done

- [x] verify scenarios in change `spec.md` covered for initial land
- [x] verify default `swift run adevcontainerTests` green
- [x] verify Non-goals respected (runtime config-wins unchanged; no archive/wiki)

---

## 5. Defect fix: containerEnv PATH/$VAR via ENV (not RUN single-quote)

Root cause after §2: `installEnvExportPrefix`/`shellEscape` single-quotes values containing `$`, so `PATH=$PATH:$DOTNET_ROOT` becomes literal `PATH='$PATH:$DOTNET_ROOT'` and install loses system PATH (`dirname: command not found`).

- [x] 5.1 Spec delta: scenario **containerEnv PATH dollar-refs expand (no single-quote wipe)**; composition requires Dockerfile `ENV` before install `RUN`; `recipeVersion` `"5"` (path: `specs/changes/features-install-containerenv/spec.md`, `proposal.md`)
- [x] 5.2 Failing test: feature with `DOTNET_ROOT` + `PATH=$PATH:$DOTNET_ROOT` → Dockerfile has expandable `ENV PATH=…`, no `PATH='$PATH:…'`; options/user keys stay on RUN prefix; ENV before RUN (path: `Tests/adevcontainerTests/AllUnitTests.swift`)
- [x] 5.3 Emit non-empty feature `metadata.containerEnv` as Dockerfile `ENV` lines before that feature’s install `RUN` (preserve `$VAR`/`${VAR}`; do not shell single-quote). Options + `_REMOTE_*`/`_CONTAINER_*` remain on RUN export prefix only (path: `FeatureDockerfileGenerator.swift`, `FeatureOptions.swift`)
- [x] 5.4 Bump `DerivedImageTag.recipeVersion` `"4"` → `"5"`; update epoch comment and suite expectations (path: `DerivedImageTag.swift`, `AllUnitTests.swift`)
- [x] 5.5 Adjust existing containerEnv Dockerfile assertions for `ENV …` form; keep empty/coexist/runtime config-wins green (path: `AllUnitTests.swift`)
- [x] 5.6 Run full default suite `swift run adevcontainerTests`; fix regressions

## Checkpoint — PATH/$VAR defect fixed

- [x] verify **containerEnv PATH dollar-refs expand (no single-quote wipe)**
- [x] verify **install sees feature containerEnv** (ENV form)
- [x] verify **empty containerEnv unchanged** / **options and user keys** / **runtime config-wins**
- [x] verify **recipeVersion** is `"5"` and invalidates `"4"` tags
- [x] verify default `swift run adevcontainerTests` green
- [x] verify Non-goals respected (no config-file containerEnv in Dockerfile; no archive/wiki)

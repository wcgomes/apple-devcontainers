# Tasks: private-feature-git-clone

Readiness: `analyze` must pass before implementation; review runs `verify` against the persisted spec.

Contract ref: `specs/changes/private-feature-git-clone/`. Implementation waits for `analyze`. Do not implement from this file before that gate. Persisted spec is authoritative. Do not create `design.md`. Do not edit `specs/features.md`, wiki, `GitClient.swift`, `HostGitCredential.swift`, or `CloneCommand.swift`. Do not close GitHub issue 66. Do not add feature-key syntax, forward a registry login token, synthesize an SSH URL, pass PAT flags, or read or print passwords or tokens. Tests use a fake HTTP session and a fake host git and must not call a live registry or a live private git remote. Suite command: `swift run adevcontainerTests`.

Fallback choke point, verified in source: `DefaultFeatureFetcher.fetch` delegates OCI refs to `ociClient.fetch`; `UpCommand`, `CloneCommand`, and bind `RebuildCommand` construct `DefaultFeatureFetcher`; volume `RebuildCommand` with any local-path ref also uses `DefaultFeatureFetcher`; volume OCI-only `RebuildCommand` sets `fetcher = OCIFeatureClient()` at `RebuildCommand.swift`. `FeaturesRunner` fetches through that injected fetcher and already runs before container delete. Implement the fallback inside `OCIFeatureClient.fetch` so every one of those paths hits it. Do not replace the volume OCI-only construction with a client that skips the fallback, and do not satisfy command tests by setting `featuresFetcherOverride`.

## 1. Failing unit tests

- [x] 1.1 Write failing tests: tag ref `some.private.registry/devcontainer-features/feature:1` and the same ref with a digest clone `https://some.private.registry/devcontainer-features`; the tag and digest are not git refs and are not checked out; `some.private.registry/feature:1` fails structured `CLIErrorCode.featureFetch`, names the ref, and does not invent a clone URL or invoke git (path: `Tests/adevcontainerTests/PrivateFeatureGitCloneTests.swift`)
- [x] 1.2 Write failing tests: embedded manifest or blob HTTP 401 and HTTP 403 load a valid package while `devcontainer.json` bytes and the OCI key stay unchanged; a successful OCI fetch does not clone; HTTP 404, a network error, a malformed manifest, and any other non-401/403 HTTP status stay structured OCI `featureFetch`, do not clone, and do not install; a successful OCI feature beside an auth-failed feature stays on OCI and is not cloned (path: `Tests/adevcontainerTests/PrivateFeatureGitCloneTests.swift`)
- [x] 1.3 Write failing tests: host git is invoked with inherited environment so a credential helper and `url.insteadOf` apply; argv is the synthesized HTTPS URL only, with no PAT or password flag, no SSH URL, and no registry bearer token; status, labels, logs, and error JSON do not contain a fixture token (path: `Tests/adevcontainerTests/PrivateFeatureGitCloneTests.swift`)
- [x] 1.4 Write failing tests: `src/<featureId>` wins when it contains both `devcontainer-feature.json` and `install.sh`, even if the repository root is also valid; otherwise a valid repository root is loaded; a partial tree or incomplete clone fails `featureFetch`, names the ref, states that OCI authentication failed and the git fallback failed, and does not return a package (path: `Tests/adevcontainerTests/PrivateFeatureGitCloneTests.swift`)
- [x] 1.5 Write failing tests: the loaded tree is the default-branch tip, not the OCI tag or digest; a later resolution obtains the then-current tip rather than an unchecked earlier cache; two features from `https://some.private.registry/devcontainer-features` in one resolution are loadable from one clone; the clone and cache are outside the fixture workspace and the workspace is not dirty (path: `Tests/adevcontainerTests/PrivateFeatureGitCloneTests.swift`)
- [x] 1.6 Write failing tests: missing git, or git that cannot obtain credentials, fails `featureFetch`, names the ref, states that OCI authentication failed and the git fallback failed, produces no partial package, and does not proceed to install; with quiet unset, stderr gains a `==> …` status that the feature is being cloned after OCI authentication failure, names the ref, and has no credentials; `StatusPrinter.enabled = false` silences that line (path: `Tests/adevcontainerTests/PrivateFeatureGitCloneTests.swift`)
- [x] 1.7 Write the identity lock and the embedded-client lock: `DerivedImageTag` / existing hash inputs stay the OCI ref string plus current inputs when only git tip or file content would differ, and `recipeVersion` stays `"7"`; fetch still does not invoke `container image pull`, ORAS, or Node (path: `Tests/adevcontainerTests/PrivateFeatureGitCloneTests.swift`)

## 2. Register unit tests and write command coverage

- [x] 2.1 Register `privateFeatureGitCloneTests` in the suite list [P] (path: `Tests/adevcontainerTests/main.swift`)
- [x] 2.2 Write failing `up` tests with `featuresFetcherOverride` left nil: HTTP 401 or 403 loads the package through the production fetcher, the OCI key is not rewritten, and install does not run when the fallback fails [P] (path: `Tests/adevcontainerTests/AllCommandTests.swift`)
- [x] 2.3 Write failing `clone` tests with `featuresFetcherOverride` left nil: the same fallback loads the package and does not rewrite the key; lock that workspace `adevcontainer clone` credential behavior is unchanged; lock that a local-path package still loads from the sparse checkout and a missing local-path package stays `featureFetch`/`featureMetadata`, never OCI, and does not start git; a mixed valid local-path feature plus an OCI HTTP 401 or 403 loads the local package from the sparse checkout without starting git for that ref, and loads the OCI ref through the same fallback without rewriting either key [P] (path: `Tests/adevcontainerTests/CloneInVolumeTests.swift`)
- [x] 2.4 Write failing `rebuild` tests with `featuresFetcherOverride` left nil: bind rebuild and volume OCI-only rebuild load through the same fallback and do not rewrite the key; rebuild still re-fetches and takes the fallback when derived-tag identity is unchanged; a fallback failure does not delete the old container; lock that bind rebuild still loads a local-path package from the stamped workspace, volume rebuild still stages guest `.devcontainer` via `exec tar` and not `container cp`, and a missing local-path package fails before delete without starting git; bind and volume mixed configs keep the local path on that existing loader (volume still `exec tar`, not `container cp`, temp removed) and load the OCI HTTP 401 or 403 ref through the same fallback without rewriting either key [P] (path: `Tests/adevcontainerTests/RebuildCommandPhaseTests.swift`)

## Checkpoint

- [x] verify **Collection URL strips tag and digest** is a failing test
- [x] verify **OCI ref with no collection segment fails structured** is a failing test
- [x] verify **HTTP 401 or 403 loads the collection without rewriting the key** is a failing test
- [x] verify **Successful OCI fetch does not clone** is a failing test
- [x] verify **Successful OCI feature beside an auth failure stays on OCI** is a failing test
- [x] verify **Fetch 404 is structured failure** is a failing test
- [x] verify **Non-auth OCI failure does not clone** is a failing test
- [x] verify **Host git credentials apply without product secrets** is a failing test
- [x] verify **Registry login token is not forwarded** is a failing test
- [x] verify **Package lookup prefers src** is a failing test
- [x] verify **Package lookup uses repository root when src is not valid** is a failing test
- [x] verify **Partial package is not used** is a failing test
- [x] verify **Fallback uses the current default-branch tip** is a failing test
- [x] verify **One collection clone loads several features** is a failing test
- [x] verify **Clone stays outside the workspace** is a failing test
- [x] verify **Missing git or credentials fails closed** is a failing test
- [x] verify **Status reports clone after OCI auth failure** is a failing test
- [x] verify **Same fallback on up, clone, and rebuild** is a failing test on `up`, `clone`, bind `rebuild`, and volume OCI-only `rebuild`
- [x] verify **Mixed local-path and OCI auth failure falls back only for the OCI ref** is a failing test on `clone`, bind `rebuild`, and volume `rebuild`
- [x] verify **Fallback failure on rebuild keeps the old container** is a failing test
- [x] verify **Git content does not invalidate identity** already passes and is not rewritten into a failure
- [x] verify **Fetch invokes embedded registry client not container pull for artifacts** already passes and is not rewritten into a failure
- [x] verify **Workspace clone credentials are unchanged** already passes
- [x] verify **Clone loads local-path Features from sparse checkout** already passes
- [x] verify **Clone missing local-path package fails structured not OCI** already passes and does not start git
- [x] verify **Bind rebuild loads local-path Features from stamped workspace** already passes
- [x] verify **Volume rebuild loads local-path Features from staged guest .devcontainer** already passes
- [x] verify **Volume rebuild missing local-path package fails before delete** already passes and does not start git

## 3. Implement the fallback

- [x] 3.1 On embedded manifest or blob HTTP 401 or 403 only, clone `https://<registry>/<collection>` with host git, inheriting credential helpers and `url.insteadOf`, and load `src/<featureId>` or else a valid repository root into the existing feature cache destination; refresh the default-branch tip on every resolution; share one clone per collection on that client instance; keep the clone outside the workspace; emit `StatusPrinter.status` for the clone without credentials; map missing git, missing credentials, no collection segment, and bad packages to `CLIErrorCode.featureFetch` with the spec wording; leave success, 404, and other non-auth failures on the current OCI path; add the test seam that production `OCIFeatureClient()` and `DefaultFeatureFetcher()`'s default client honor so command tests need no `featuresFetcherOverride` (path: `Sources/ADevContainerLib/Features/OCIFeatureClient.swift`)

## Checkpoint

- [x] verify **Fetch invokes embedded registry client not container pull for artifacts**
- [x] verify **Successful OCI fetch does not clone**
- [x] verify **Successful OCI feature beside an auth failure stays on OCI**
- [x] verify **Fetch 404 is structured failure**
- [x] verify **Non-auth OCI failure does not clone**
- [x] verify **HTTP 401 or 403 loads the collection without rewriting the key**
- [x] verify **Collection URL strips tag and digest**
- [x] verify **OCI ref with no collection segment fails structured**
- [x] verify **Host git credentials apply without product secrets**
- [x] verify **Registry login token is not forwarded**
- [x] verify **Package lookup prefers src**
- [x] verify **Package lookup uses repository root when src is not valid**
- [x] verify **Partial package is not used**
- [x] verify **Fallback uses the current default-branch tip**
- [x] verify **Clone stays outside the workspace**
- [x] verify **Missing git or credentials fails closed**
- [x] verify **Fallback failure on rebuild keeps the old container**
- [x] verify **Same fallback on up, clone, and rebuild**
- [x] verify **Mixed local-path and OCI auth failure falls back only for the OCI ref**
- [x] verify **One collection clone loads several features**
- [x] verify **Git content does not invalidate identity**
- [x] verify **Status reports clone after OCI auth failure**
- [x] verify **Workspace clone credentials are unchanged**
- [x] verify **Unit tests mock fetch without network** by `swift run adevcontainerTests` with no live registry and no live private git remote
- [x] verify **Clone loads local-path Features from sparse checkout**
- [x] verify **Clone missing local-path package fails structured not OCI**
- [x] verify **Bind rebuild loads local-path Features from stamped workspace**
- [x] verify **Volume rebuild loads local-path Features from staged guest .devcontainer**
- [x] verify **Volume rebuild missing local-path package fails before delete**

# Change Spec: private-feature-git-clone

Delta against `specs/features.md`. This change modifies requirement "Feature artifact fetch (OCI + local path)" only. Admission is not modified: supported reference forms stay OCI and local path, and this fallback is not a new feature-key form.

## MODIFIED Requirements

### Requirement: Feature artifact fetch (OCI + local path)

The default fetcher MUST:

1. **Local path** refs → resolve relative candidates in order until a directory containing both `devcontainer-feature.json` and `install.sh` exists: config-file parent, then `workspace/.devcontainer` if distinct, then workspace root; absolute/`file://` use their own path only. Validate package layout and **copy** into the feature cache destination. A miss is a structured `featureFetch`/`featureMetadata` error naming the ref, not an OCI/network failure, and MUST NOT start the git fallback below.
2. **OCI** refs → fetch feature content as **OCI artifacts** (feature layers/files), not as a plain application container image assumed runnable, via **HTTPS and/or registry API** logic **embedded in the product** (library code under `Sources/ADevContainerLib/`).

When that embedded OCI manifest or blob fetch succeeds, the product MUST use the OCI artifact and MUST NOT clone a git collection for that feature. A successful OCI feature in the same resolution as an auth-failed OCI feature MUST stay on OCI.

When that embedded OCI manifest or blob fetch fails with HTTP 401 or HTTP 403, the product MUST clone the feature collection with host git and load the package, without rewriting `devcontainer.json`. The feature key MUST stay the OCI ref. The product MUST NOT rewrite it to a local path and MUST NOT require a manual checkout. The example key `some.private.registry/devcontainer-features/feature:1` MUST keep working unchanged. This same fallback MUST apply on every product path that fetches an admitted OCI feature, including `up`, `clone`, and `rebuild` (bind and volume, including an OCI-only volume rebuild). It MUST NOT apply to local-path misses, HTTP 404, or any other non-auth OCI failure.

The product MUST NOT:

- Require users to install ORAS or another external feature-fetch CLI
- Assume Apple `container image pull` pulls feature artifacts correctly
- Invoke Node or `@devcontainers/cli` to fetch features
- Add a new feature-key syntax, or rewrite an OCI feature key to a local path
- Use an OCI registry keychain or forward a `container registry login` token to satisfy this fallback
- Change how `adevcontainer clone` authenticates the workspace repository
- Treat the OCI tag or digest as a git ref, or check out that tag or digest
- Synthesize an SSH clone URL
- Read or print passwords or tokens, pass them as git flags or arguments, or place them in labels, logs, status, or error JSON
- Place the collection clone or its cache inside the user workspace, or dirty the workspace
- Use a partial clone or a directory that is not a valid package
- Proceed to feature install after the git fallback fails

**Collection URL (MUST):** The feature id is the last repository path segment of the OCI ref. The tag and the digest MUST be stripped and MUST NOT be used as git refs. The collection is the repository path without that last segment. The product MUST clone `https://<registry>/<collection>`. Example: `some.private.registry/devcontainer-features/feature:1` MUST clone `https://some.private.registry/devcontainer-features`. A ref whose repository has no collection segment, such as `registry/feature:tag`, MUST fail structured and MUST NOT invent a clone URL.

**Host git (MUST):** The product MUST invoke host git so existing host credential helpers and host git config apply, including `url.insteadOf`. The product MUST synthesize that HTTPS URL only. Host git config MAY rewrite it; the product MUST NOT invent a second URL. The product MUST NOT add personal-access-token flags and MUST NOT read or print passwords or tokens.

**Package lookup (MUST):** After a completed clone, if `src/<featureId>` contains both `devcontainer-feature.json` and `install.sh`, the product MUST load that directory. Otherwise, if the repository root contains both files, the product MUST load the root. Otherwise the product MUST fail structured. A directory that contains only one of the two files MUST NOT be used. Several features from the same collection in one resolution MUST be loadable from one clone of that collection.

**Tip and cache (MUST):** The loaded tree MUST be the default branch tip at that resolution. The product MUST NOT check out the OCI tag or digest. Each resolution that takes the fallback MUST obtain the current default-branch tip and MUST NOT use an unchecked stale cache. The clone or temp cache MUST stay outside the user workspace and MUST NOT dirty the workspace.

**Identity (MUST):** Config-hash and derived-tag identity MUST stay the OCI ref string plus the existing hash inputs. Git commit identity or cloned file content MUST NOT by itself invalidate that hash, the same v1 local-path rule. `rebuild` MUST still re-fetch an admitted OCI feature, and MUST take this fallback when that re-fetch returns HTTP 401 or HTTP 403.

**Status (MUST):** When the fallback starts, the product MUST emit a user-visible progress status in the existing `==> …` family stating that the feature is being cloned after OCI authentication failure and naming the feature ref. The status MUST NOT include credentials, passwords, or tokens. Existing quiet-mode silencing of Features progress status applies to this line.

**Failures (MUST):** OCI or local fetch/load failures other than HTTP 401 and HTTP 403 (missing local directory, missing install script or metadata, network, HTTP 404, any other non-auth HTTP status, malformed manifest) MUST surface as structured errors naming the feature ref and failure class, and MUST NOT start the git fallback. HTTP 404 and those other non-auth OCI failures remain structured OCI `featureFetch` failures. If clone or package lookup fails, including because git is missing or credentials are absent, the structured `featureFetch` error MUST name the feature ref and state that OCI authentication failed and the git fallback failed. The product MUST NOT proceed to feature install and MUST NOT produce a partial package. On `rebuild`, this failure MUST remain before container delete, so the old container is kept. Unit tests MUST mock the OCI fetch boundary, and git-fallback tests MUST be satisfiable without a live registry or a live private git remote, so the default suite needs no network; local path tests use fixtures under `Tests/Fixtures/features-sample/`.

`clone` MUST sparse-checkout the whole `.devcontainer/` tree (including `features/<id>`) and load local-path refs via `DefaultFeatureFetcher` (workspace = checkout, configDirectory = config parent) — never raw `OCIFeatureClient`. Bind `rebuild` MUST load local-path refs via `DefaultFeatureFetcher` from the stamped host workspace. Volume `rebuild` MUST NOT use raw `OCIFeatureClient` when any admitted feature is a local path: stage the guest `.devcontainer/` (and root `.devcontainer.json` when that is the config) onto a host temp via `exec tar cf -` (not `container cp`) before Features/delete, point `DefaultFeatureFetcher` at that staged root + config directory, and remove the temp. Staging or load failure is a structured pre-delete error (old container kept). Mixed OCI + local in one config: local via the loader, OCI via the embedded client. An OCI ref on that mixed path, and an OCI-only volume rebuild, MUST still take this HTTP 401/403 git fallback. The fallback MUST NOT convert the feature key into a local-path ref and MUST NOT change local-path staging.

#### Scenario: Fetch invokes embedded registry client not container pull for artifacts

- Given an admitted OCI feature ref
- When the runner fetches the feature
- Then fetch goes through the embedded Features fetch path (mockable), and tests can succeed without calling `container image pull` for the feature artifact

#### Scenario: Successful OCI fetch does not clone

- Given an admitted OCI feature whose embedded manifest and blob fetch succeed
- When the runner fetches the feature
- Then the OCI artifact is used, no git collection is cloned, and the feature key is unchanged

#### Scenario: Successful OCI feature beside an auth failure stays on OCI

- Given one resolution admits an OCI feature whose embedded fetch succeeds and another whose embedded fetch returns HTTP 401 or HTTP 403
- When features are fetched
- Then the successful feature uses the OCI artifact and is not cloned, and the auth-failed feature does not change that successful fetch

#### Scenario: Fetch 404 is structured failure

- Given a feature ref whose manifest does not exist
- When fetch runs
- Then `up` fails with a structured OCI `featureFetch` error naming the feature ref, does not clone a git collection, and does not proceed to create/install

#### Scenario: Non-auth OCI failure does not clone

- Given an admitted OCI feature whose embedded fetch fails with a network error, a malformed manifest, or an HTTP status other than 401 or 403
- When fetch runs
- Then the CLI fails with a structured OCI `featureFetch` error naming the feature ref, does not clone a git collection, and does not proceed to install

#### Scenario: HTTP 401 or 403 loads the collection without rewriting the key

- Given `devcontainer.json` keeps the key `some.private.registry/devcontainer-features/feature:1` and the embedded manifest or blob fetch returns HTTP 401 or HTTP 403
- When `up` fetches that feature and the collection clone contains a valid package
- Then the key is not rewritten to a local path, the user is not required to check out the collection, and the package loads from the git fallback

#### Scenario: Collection URL strips tag and digest

- Given the OCI ref `some.private.registry/devcontainer-features/feature:1` or the same ref with a digest instead of `:1`, and the embedded fetch returns HTTP 401
- When the fallback selects a clone URL
- Then the URL is `https://some.private.registry/devcontainer-features`, and the tag or digest is not a git ref and is not checked out

#### Scenario: OCI ref with no collection segment fails structured

- Given an admitted OCI ref whose repository path has no collection segment, such as `some.private.registry/feature:1`, and the embedded fetch returns HTTP 401
- When fetch runs
- Then the CLI fails structured, names the feature ref, and does not invent a clone URL

#### Scenario: Host git credentials apply without product secrets

- Given host git has a credential helper and `url.insteadOf` for the synthesized HTTPS collection URL, and the product is not given a password or token
- When the fallback clones
- Then host git is invoked so that helper and `url.insteadOf` apply, the product does not pass a personal access token or password, does not synthesize an SSH URL, and does not place credentials in status, labels, logs, or error JSON

#### Scenario: Registry login token is not forwarded

- Given a `container registry login` session exists and host git cannot authenticate the collection
- When the embedded OCI fetch returns HTTP 401
- Then the product does not forward that registry token, and the git fallback fails structured with no partial package

#### Scenario: Package lookup prefers src

- Given a completed collection clone whose `src/<featureId>` contains both `devcontainer-feature.json` and `install.sh`
- When the fallback selects a package
- Then that `src/<featureId>` directory is loaded, even if the repository root is also a valid package

#### Scenario: Package lookup uses repository root when src is not valid

- Given a completed clone whose `src/<featureId>` is absent or is not a valid package, and whose repository root contains both `devcontainer-feature.json` and `install.sh`
- When the fallback selects a package
- Then the repository root is loaded

#### Scenario: Partial package is not used

- Given a fallback clone where neither `src/<featureId>` nor the repository root contains both `devcontainer-feature.json` and `install.sh`, or the clone did not complete
- When package lookup finishes
- Then the CLI fails with a structured `featureFetch` error naming the feature ref and stating that OCI authentication failed and the git fallback failed, does not use a partial tree, and does not proceed to install

#### Scenario: Fallback uses the current default-branch tip

- Given an OCI ref with a tag or digest and a collection whose default branch tip is not that tag or digest
- When a resolution takes the fallback
- Then the loaded tree is the default branch tip at that resolution, not a checkout of the OCI tag or digest
- And a later resolution that takes the fallback obtains the then-current default-branch tip rather than an unchecked earlier cache

#### Scenario: Clone stays outside the workspace

- Given a resolution that takes the git fallback
- When the collection is cloned
- Then the clone and any cache are outside the user workspace, and the workspace is not dirty

#### Scenario: Missing git or credentials fails closed

- Given an admitted OCI feature whose embedded fetch returns HTTP 401 or HTTP 403, and host git is missing or cannot obtain credentials
- When fetch runs
- Then the CLI fails with a structured `featureFetch` error naming the feature ref and stating that OCI authentication failed and the git fallback failed, produces no partial package, and does not proceed to install

#### Scenario: Fallback failure on rebuild keeps the old container

- Given a `rebuild` whose admitted OCI feature returns HTTP 401 or HTTP 403 and whose git fallback then fails
- When feature fetch runs
- Then the CLI fails structured as in the missing-credentials case, does not proceed to install, and does not delete the old container

#### Scenario: Same fallback on up, clone, and rebuild

- Given an admitted OCI feature whose embedded fetch returns HTTP 401 or HTTP 403 and a collection that contains a valid package
- When `up`, `clone`, or `rebuild` fetches that feature, including bind `rebuild` and volume `rebuild` when the admitted features are OCI-only
- Then each of those paths loads the package through the same git fallback and does not rewrite the feature key

#### Scenario: Mixed local-path and OCI auth failure falls back only for the OCI ref

- Given a config admits a valid local-path feature and an OCI feature whose embedded fetch returns HTTP 401 or HTTP 403, and that OCI collection contains a valid package
- When `clone`, bind `rebuild`, or volume `rebuild` fetches those features
- Then the local-path package loads through the existing local loader and does not start the git fallback, the OCI ref loads through the git fallback, neither feature key is rewritten, and volume local-path staging stays `exec tar` (not `container cp`) with the temp removed

#### Scenario: One collection clone loads several features

- Given one resolution admits `some.private.registry/devcontainer-features/feature-a:1` and `some.private.registry/devcontainer-features/feature-b:1`, both embedded fetches return HTTP 401 or HTTP 403, and that collection contains valid packages for both feature ids
- When features are fetched
- Then both packages are loadable from one clone of `https://some.private.registry/devcontainer-features`

#### Scenario: Git content does not invalidate identity

- Given an admitted OCI ref whose fallback tip or package file content changes and whose OCI ref string and other existing hash inputs do not
- When config-hash and derived-tag identity are computed
- Then that identity is unchanged by the git commit or file content alone
- And `rebuild` still re-fetches the OCI feature and takes the fallback when that re-fetch returns HTTP 401 or HTTP 403

#### Scenario: Status reports clone after OCI auth failure

- Given quiet mode is unset and an admitted OCI feature takes the git fallback
- When the fallback starts
- Then stderr includes a `==> …` progress status stating that the feature is being cloned after OCI authentication failure, naming the feature ref, and containing no credentials

#### Scenario: Workspace clone credentials are unchanged

- Given `adevcontainer clone` authenticates the workspace repository
- When that workspace clone runs, whether or not a feature later takes the git fallback
- Then workspace clone credential behavior is unchanged and is not replaced by this feature-collection fallback

#### Scenario: Unit tests mock fetch without network

- Given unit tests for the Features runner
- When the suite runs offline
- Then fetch is satisfied by a mock/fake and tests do not require live registry access or a live private git remote

#### Scenario: Clone loads local-path Features from sparse checkout

- Given a repo with `"features": { "./features/kubesecret": {} }` and a valid package at `.devcontainer/features/kubesecret`
- When `clone` fetches config and runs Features
- Then the sparse checkout materializes the `.devcontainer/` tree (including `features/kubesecret`) and the package loads via `DefaultFeatureFetcher` (not OCI)

#### Scenario: Clone missing local-path package fails structured not OCI

- Given a clone config with a local-path feature whose package is absent from the checkout
- When Features load
- Then the CLI fails with a structured `featureFetch`/`featureMetadata` error naming the ref (never OCI/network) and does not start the git fallback

#### Scenario: Bind rebuild loads local-path Features from stamped workspace

- Given a bind-mode container whose stamped host workspace has `"features": { "./features/kubesecret": {} }` and a valid package at `.devcontainer/features/kubesecret`
- When `rebuild` runs Features
- Then the package loads via `DefaultFeatureFetcher` from the stamped workspace (not OCI)

#### Scenario: Volume rebuild loads local-path Features from staged guest .devcontainer

- Given a volume-mode container whose guest workspace has `"features": { "./features/kubesecret": {} }` and a valid package at `.devcontainer/features/kubesecret`
- When `rebuild` runs Features
- Then the guest `.devcontainer/` tree is staged to a host temp via `exec tar` (not `container cp`) before Features/delete, `DefaultFeatureFetcher` loads the package from that staged root (not raw `OCIFeatureClient`), and the temp is removed

#### Scenario: Volume rebuild missing local-path package fails before delete

- Given a volume-mode rebuild whose admitted features include a local-path ref whose package is missing after staging
- When Features load
- Then the CLI fails with a structured `featureFetch`/`featureMetadata` error naming the ref (never OCI/network), does not start the git fallback, and the old container is not deleted

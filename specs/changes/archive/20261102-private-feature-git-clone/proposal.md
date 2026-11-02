# Proposal: Private OCI feature git clone fallback

## Intent

An admitted OCI feature key that the embedded registry fetch rejects with HTTP 401 or 403 cannot be installed unless the user manually clones the collection and rewrites `devcontainer.json` to a local path, which is the workaround reported in GitHub issue 66. This change keeps that key unchanged and, only after that authentication failure, clones the collection with host git and loads the package.

## Scope

The outcome modifies the Features requirement "Feature artifact fetch (OCI + local path)" in [features.md](../../features.md). Admission is not modified: supported forms remain OCI and local path, and this fallback is not a new feature-key syntax, so the supported-forms text must not mention it. No other active change under `specs/changes/` overlaps this domain. Descriptive pages [cli-runtime-boundary.md](../../../wiki/conventions/cli-runtime-boundary.md), [devcontainer-apple-gaps.md](../../../wiki/domain/devcontainer-apple-gaps.md), and [architecture.md](../../../wiki/architecture.md) still describe OCI plus local path only, with OCI fetch as embedded HTTPS and no git fallback; that conflict is flagged and those pages are not edited. Realized `specs/features.md` is not edited until archive.

## Non-goals

- OCI registry keychain or `container registry login` token forwarding
- New feature-key syntax
- Changing workspace `adevcontainer clone` credential behavior
- Closing GitHub issue 66 inside this change
- Treating the OCI tag or digest as a git ref
- SSH URL synthesis

## Approach

On HTTP 401 or 403 from the embedded OCI feature manifest or blob fetch, clone the collection with host git, load `src/<featureId>` or the repository root when that directory is a valid package, and continue the existing install path. Successful OCI fetches and non-auth failures stay on the current OCI path. `design.md` is not created: each decision stays a short index entry, and the observable guarantees live in [spec.md](spec.md).

## Decision index

- **Unchanged feature key:** The `devcontainer.json` key stays the OCI ref. The product does not rewrite it to a local path and does not require a manual checkout. Example that must keep working: `some.private.registry/devcontainer-features/feature:1`.
- **Trigger:** Only HTTP 401 or 403 from the embedded OCI feature manifest or blob fetch. Successful OCI fetch is unchanged. HTTP 404 and other non-auth failures stay structured OCI `featureFetch` failures with no git clone.
- **Collection URL:** Feature id is the last repository path segment; tag and digest are stripped and are not git refs. Clone `https://<registry>/<collection>`, where collection is the repository path without that last segment. A ref with no collection segment fails structured and does not invent a URL.
- **Host git credentials:** Invoke host git so existing credential helpers and host git config apply, including `url.insteadOf`. No PAT flags, no reading or printing passwords or tokens, and no credentials in labels, logs, or error JSON. Synthesize HTTPS only.
- **Package lookup:** `src/<featureId>` when that directory contains both `devcontainer-feature.json` and `install.sh`; otherwise the repository root when it is a valid package; otherwise structured failure. Do not use a partial tree.
- **Tip:** Use the default branch tip at resolution time. Do not check out the OCI tag or digest. Each fallback resolution obtains the current tip, not an unchecked stale cache.
- **Workspace:** Cache or temp clone stays outside the user workspace and does not dirty it.
- **Fallback failure:** The structured error names the feature ref and that OCI auth failed and the git fallback failed. Do not proceed to install. Missing git or absent credentials fail the same way, with no partial package.
- **Paths:** The same fallback applies on every product path that fetches an admitted OCI feature, including `up`, `clone`, and `rebuild` (bind and volume, including OCI-only volume rebuild and a mixed local-path plus OCI config). The fallback does not convert the OCI key into a local path or change local-path staging.
- **One collection clone:** Several features from the same collection in one resolution are loadable from one clone of that collection.
- **Identity:** Config-hash and derived-tag identity stay the OCI ref string plus existing hash inputs. Git commit or file content does not by itself invalidate the hash, same as the v1 local-path rule. `rebuild` still re-fetches.
- **Status:** Emit a user-visible status that the feature is being cloned after OCI auth failure, with no credentials.

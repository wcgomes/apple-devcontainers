# Convention: Release and distribution

How `adevcontainer` binaries are built, versioned, and installed. Decided 2026-08.

## Repo identity

- **GitHub:** [wcgomes/apple-dev-containers](https://github.com/wcgomes/apple-dev-containers) (renamed 2026-08 from `wcgomes/dev-containerization`; old URLs 301).
- **Product/binary:** still `adevcontainer`. Local clone folder may still be named `dev-containerization`.
- **Homebrew tap:** unchanged (`wcgomes/homebrew-tap`); formula homepage/url point at the new repo.

## Constraints

- **Host build:** GitHub Actions on **macos-26 only** (`Package.swift` requires macOS 26.0; arm64-only product).
- **No codesign / notarize in v1** — deferred; raw unsigned arm64 binary in the tarball.
- **Apple `container` is a runtime dep only** — not a build or CI dependency for release artifacts. Document in Homebrew caveats and install docs.
- **LICENSE:** MIT at repo root.

## CI vs release

| Workflow | Path | Trigger | What it does |
|----------|------|---------|--------------|
| CI | `.github/workflows/ci.yml` | push `main`, PRs | tests + release configuration build |
| Release | `.github/workflows/release.yml` | tag `v*.*.*` or `workflow_dispatch` + version input | inject version → test → `swift build -c release` → tarball + sha256 → GitHub Release |

Do not paste workflow YAML into the wiki — edit the files under `.github/workflows/`.

## Maintainer process

**`main` ≠ release.** Merge integrates code; it does not publish a binary or GitHub Release.

| Step | Action |
|------|--------|
| Land code | Branch → PR → CI green → merge to `main` (merge when ready to integrate; no ship gate) |
| Ship | Tag the desired commit (usually latest `main`): `git tag vX.Y.Z && git push origin vX.Y.Z` — or `workflow_dispatch` with version input |
| Publish | Release workflow builds/tests, writes tarball + sha256, creates GitHub Release |
| Homebrew | After release: set `sha256` in `wcgomes/homebrew-tap` `Formula/adevcontainer.rb` **and** `packaging/homebrew/adevcontainer.rb` |

- **Release trigger / source of truth:** git tag `vMAJOR.MINOR.PATCH` (or prerelease with `-`). Only tags (or dispatch + version) publish.
- **Branch protection (recommended):** require PR + CI on `main` so contributors cannot push directly; maintainers still release only via tags. Confirm repo settings before claiming it is enforced.
- No extra process (no changelog tooling, no notarize) unless this page is updated.

## Versioning

- **Published binary source of truth:** git tag (`vX.Y.Z` or prerelease with `-`).
- **In-binary version:** `Sources/adevcontainer/Version.swift` (`AppVersion.current`).
- **Inject script:** `scripts/inject-version.sh` — used in **release CI only** (not local day-to-day builds).
- **Prerelease:** version string containing `-` → GitHub Release marked prerelease (`softprops/action-gh-release`).

## Artifact

- Build: `swift build -c release` on macos-26 arm64.
- Tarball name: `adevcontainer-macos-arm64.tar.gz` (+ companion `.sha256`).
- When creating the tarball on macOS: set **`COPYFILE_DISABLE=1`** so AppleDouble/`._*` files are not packed.
- Publish: GitHub Release via `softprops/action-gh-release`.

## Install UX (priority order)

1. **Homebrew (primary)** — public tap [wcgomes/homebrew-tap](https://github.com/wcgomes/homebrew-tap); formula `Formula/adevcontainer.rb`. Install: `brew tap wcgomes/tap && brew install adevcontainer`. In-repo template: `packaging/homebrew/adevcontainer.rb` (real `sha256` synced from first release **v0.1.0**; keep tap formula in sync on each release). Caveats must note Apple `container` is a separate runtime install.
2. **GitHub Release curl/tar** — download tarball + verify sha256; fallback for non-brew users.
3. **Source build** — documented in README (`swift build -c release` on macOS 26+ Apple Silicon).

## Agent checklist (changing release)

- Touch workflows under `.github/workflows/`, not ad-hoc publish scripts, unless intentionally adding a new path.
- Bump/tag version; release workflow owns inject + artifact + GH Release.
- On each release: update `sha256` in `packaging/homebrew/adevcontainer.rb` and the tap formula (`Formula/adevcontainer.rb` in `wcgomes/homebrew-tap`).
- Still no notarize unless an explicit decision supersedes this page.

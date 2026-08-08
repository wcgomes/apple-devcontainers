# Convention: Release and distribution

How `adevcontainer` binaries are built, versioned, and installed. Decided 2026-08.

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

1. **Homebrew (primary)** — tap `wcgomes/tap` (repo `homebrew-tap`). Formula template in-repo: `packaging/homebrew/adevcontainer.rb` (`sha256` placeholder `REPLACE_ON_RELEASE` until first real release). Caveats must note Apple `container` is a separate runtime install.
2. **GitHub Release curl/tar** — download tarball + verify sha256; fallback for non-brew users.
3. **Source build** — documented in README (`swift build -c release` on macOS 26+ Apple Silicon).

## Agent checklist (changing release)

- Touch workflows under `.github/workflows/`, not ad-hoc publish scripts, unless intentionally adding a new path.
- Bump/tag version; release workflow owns inject + artifact + GH Release.
- After first real release: replace `REPLACE_ON_RELEASE` in the Homebrew formula (and keep the tap formula in sync).
- Still no notarize unless an explicit decision supersedes this page.

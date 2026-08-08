# Homebrew formula (personal tap)

Users install with:

```bash
brew tap wcgomes/tap
brew install adevcontainer
```

`brew tap wcgomes/tap` resolves to `homebrew-tap` on GitHub. Apple `container` stays a separate host dependency (see formula caveats).

## Automatic updates on release

On each **non-prerelease** GitHub Release (`vX.Y.Z`, no `-` in the version):

1. **Tap (required for `brew upgrade`)** — the Release workflow renders `Formula/adevcontainer.rb` and pushes directly to `wcgomes/homebrew-tap` `main`.
2. **Packaging mirror** — the same job opens a PR to this repo updating `packaging/homebrew/adevcontainer.rb` (branch protection blocks direct push to `main`).

Prerelease tags (`vX.Y.Z-rc.1`, etc.) skip both Homebrew steps.

### Required secret

Configure repo secret **`HOMEBREW_TAP_TOKEN`**:

- **Fine-grained PAT**: Contents read/write on `wcgomes/homebrew-tap` only, or
- **Classic PAT**: `repo` scope

Without this secret, non-prerelease releases fail at the tap-bump step so missing brew updates are visible.

### Manual render (local)

```bash
scripts/render-homebrew-formula.sh 0.2.0 <sha256> packaging/homebrew/adevcontainer.rb
```

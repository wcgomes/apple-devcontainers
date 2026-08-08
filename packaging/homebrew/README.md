# Homebrew formula (personal tap)

1. Create or open `github.com/wcgomes/homebrew-tap`.
2. Copy `adevcontainer.rb` to `Formula/adevcontainer.rb` in that repo.
3. Per release: set `version`, confirm `url`, and replace `sha256` with the arm64 tarball digest (`shasum -a 256 adevcontainer-macos-arm64.tar.gz`).
4. Users install with:

```bash
brew tap wcgomes/tap
brew install adevcontainer
```

`brew tap wcgomes/tap` resolves to `homebrew-tap` on GitHub. Apple `container` stays a separate host dependency (see formula caveats).

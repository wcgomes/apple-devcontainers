#!/usr/bin/env bash
# Render the adevcontainer Homebrew formula with version + sha256.
# Usage: render-homebrew-formula.sh <VERSION> <SHA256> [output path]
#   output path omitted or "-" → stdout
set -euo pipefail

usage() {
  echo "usage: $0 <VERSION> <SHA256> [output path]" >&2
  echo "  VERSION  semver X.Y.Z or X.Y.Z-prerelease (optional leading v stripped)" >&2
  echo "  SHA256   64-char lowercase hex digest of adevcontainer-macos-arm64.tar.gz" >&2
  echo "  output   file path, or omit/- for stdout" >&2
  exit 1
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
fi

version="${1#v}"
sha256="$2"
out="${3:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: invalid version '$1' (expected X.Y.Z or X.Y.Z-prerelease)" >&2
  exit 1
fi

if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: invalid sha256 '$sha256' (expected 64 lowercase hex chars)" >&2
  exit 1
fi

formula=$(cat <<EOF
# Formula for personal tap github.com/wcgomes/homebrew-tap.
# After each release: set version, url (if needed), and sha256 of the arm64 tarball.

class Adevcontainer < Formula
  desc "Native Swift CLI for devcontainer.json on Apple container"
  homepage "https://github.com/wcgomes/apple-dev-containers"
  version "${version}"
  url "https://github.com/wcgomes/apple-dev-containers/releases/download/v#{version}/adevcontainer-macos-arm64.tar.gz"
  sha256 "${sha256}"
  license "MIT"

  depends_on macos: :tahoe # macOS 26+
  depends_on arch: :arm64

  def install
    bin.install "adevcontainer"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/adevcontainer --version")
  end

  def caveats
    <<~EOS
      adevcontainer requires the Apple container CLI on the host (not installed by this formula):
        https://github.com/apple/container

      After install, run:
        adevcontainer doctor
    EOS
  end
end
EOF
)

if [[ -z "$out" || "$out" == "-" ]]; then
  printf '%s\n' "$formula"
else
  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$formula" >"$out"
fi

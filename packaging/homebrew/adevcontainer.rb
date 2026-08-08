# Formula template for a personal tap (e.g. github.com/wcgomes/homebrew-tap).
# After each release: set version, url (if needed), and sha256 of the arm64 tarball.
# See packaging/homebrew/README.md.

class Adevcontainer < Formula
  desc "Native Swift CLI for devcontainer.json on Apple container"
  homepage "https://github.com/wcgomes/dev-containerization"
  version "0.1.0"
  url "https://github.com/wcgomes/dev-containerization/releases/download/v#{version}/adevcontainer-macos-arm64.tar.gz"
  # Replace with the release tarball SHA-256 before publishing the formula.
  sha256 "REPLACE_ON_RELEASE"
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

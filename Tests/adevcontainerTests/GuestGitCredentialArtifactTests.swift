import Foundation
@testable import ADevContainerLib

@MainActor let guestGitCredentialArtifactTests: [(String, () throws -> Void)] = [
    ("credentials.assets.actualPlatformAndIntegrity", {
        for platform in ["linux/arm64", "linux/amd64"] {
            let artifact = try GuestGitCredentialArtifact.select(platform: platform)
            try artifact.verify(); try artifact.verify(readBack: artifact.bytes)
            try MiniTest.expectEqual(artifact.platform, platform)
            var bad = artifact.bytes; bad[20] ^= 1
            try MiniTest.expectThrows({ try artifact.verify(readBack: bad) }, validate: { _ in })
            try MiniTest.expectThrows({ try GuestGitCredentialArtifact(platform: platform, bytes: bad, sha256: artifact.sha256).verify() }, validate: { _ in })
            var invalidELF = artifact.bytes; invalidELF[0] = 0
            try MiniTest.expectThrows({ try GuestGitCredentialArtifact(platform: platform, bytes: invalidELF, sha256: GuestGitCredentialArtifact.hash(invalidELF)).verify() }, validate: { _ in })
            let other = platform == "linux/arm64" ? "linux/amd64" : "linux/arm64"
            try MiniTest.expectThrows({ try GuestGitCredentialArtifact(platform: other, bytes: artifact.bytes, sha256: artifact.sha256).verify() }, validate: { _ in })
            try MiniTest.expectThrows({ try GuestGitCredentialArtifact(platform: platform, bytes: artifact.bytes.prefix(30), sha256: artifact.sha256).verify() }, validate: { _ in })
        }
        for platform in ["", "linux/riscv64", "darwin/arm64", "linux/x86_64"] {
            try MiniTest.expectThrows({ _ = try GuestGitCredentialArtifact.select(platform: platform) }, validate: { _ in })
        }
        try MiniTest.expectEqual(GitCredentialProtocol.version, GuestGitCredentialEmbeddedAssets.protocolVersion)
    })
]

import Foundation
@testable import ADevContainerLib

@MainActor let gitCredentialDiscoveryTests: [(String, () throws -> Void)] = [
    ("credentials.discovery.fetchURLsDeduplicateWithoutLosingSchemes", {
        let remotes = "origin\thttps://example.invalid/a.git (fetch)\norigin\thttps://example.invalid/a.git (push)\nmirror https://example.invalid/a.git (fetch)\nlegacy\thttp://dev.azure.com/org/project/_git/repo (fetch)\nssh\tgit@example.invalid:repo (fetch)\n"
        try MiniTest.expectEqual(GitCredentialDiscovery.uniqueFetchURLs(from: remotes), ["https://example.invalid/a.git", "http://dev.azure.com/org/project/_git/repo", "git@example.invalid:repo"])
        try MiniTest.expectEqual(GitCredentialDiscovery.uniqueFetchURLs(from: "origin https://example.invalid/a.git (push)\n"), [])
        try MiniTest.expectEqual(GitCredentialDiscovery.uniqueFetchURLs(from: ""), [])
    }),
    ("credentials.discovery.bindAndVolumeSources", {
        let bind = GitCredentialDiscovery.credentialSources(from: [ContainerIdentity.labelLocalFolder: " /synthetic/workspace ", ContainerIdentity.labelGitURL: "https://ignored.invalid/repo"])
        try MiniTest.expectEqual(bind.hostWorkspace, "/synthetic/workspace"); try MiniTest.expectEqual(bind.gitURL, nil)
        let volume = GitCredentialDiscovery.credentialSources(from: [ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume, ContainerIdentity.labelLocalFolder: "volume://synthetic", ContainerIdentity.labelGitURL: " http://example.invalid/repo "])
        try MiniTest.expectEqual(volume.hostWorkspace, nil); try MiniTest.expectEqual(volume.gitURL, "http://example.invalid/repo")
        let missing = GitCredentialDiscovery.credentialSources(from: [ContainerIdentity.labelLocalFolder: "volume://synthetic"])
        try MiniTest.expectEqual(missing.hostWorkspace, nil); try MiniTest.expectEqual(missing.gitURL, nil)
    })
]

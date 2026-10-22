import Foundation

/// Nonsecret source discovery for automatic credential setup.
enum GitCredentialDiscovery {
    static func uniqueFetchURLs(from output: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.hasSuffix("(fetch)") else { continue }
            let trimmed = String(text.dropLast("(fetch)".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2 else { continue }
            let url = String(parts[1])
            guard !url.isEmpty, seen.insert(url).inserted else { continue }
            result.append(url)
        }
        return result
    }
    static func credentialSources(from labels: [String: String]) -> (hostWorkspace: String?, gitURL: String?) {
        func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let gitURL = nonEmpty(labels[ContainerIdentity.labelGitURL])
        if nonEmpty(labels[ContainerIdentity.labelWorkspaceMode]) == ContainerIdentity.workspaceModeVolume { return (nil, gitURL) }
        guard let folder = nonEmpty(labels[ContainerIdentity.labelLocalFolder]), !folder.hasPrefix("volume://") else { return (nil, gitURL) }
        return (folder, nil)
    }
}

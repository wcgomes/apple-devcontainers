import Foundation

public enum RefreshCredentialsCommand {
    /// Refresh git credentials in an already-running managed container from host
    /// `git credential fill`. Does not start, stop, fetch, pull, push, or write the
    /// workspace. Credential material enters the guest via stdin only.
    public static func run(
        name: String? = nil,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker = .default,
        credentials: any GitCredentialProviding = HostGitCredential()
    ) throws {
        let info = try ManagedContainers.resolveSelection(
            name: name,
            runtime: runtime,
            picker: picker
        )
        guard info.isRunning else {
            throw CLIError(
                code: CLIErrorCode.containerNotRunning,
                message: "Container \(info.name) is not running (state: \(info.state))",
                hint: "Run '\(CommandSurface.commandPrefix) start --name \(info.name)' to start it and refresh credentials"
            )
        }

        StatusPrinter.status("Refreshing git credentials", item: info.name)
        let refreshed: Bool
        do {
            refreshed = try GuestGitCredentialSeed(
                credentials: credentials,
                runner: LifecycleRunner.hostProcessRunnerOverride ?? FoundationProcessRunner()
            ).seedFromLabels(
                containerId: info.id,
                labels: info.labels,
                connectionUser: GuestGitCredentialSeed.connectionUser(from: info.labels),
                runtime: runtime
            )
        } catch let error as CLIError {
            throw CLIError(
                code: error.code,
                message: "Failed to refresh git credentials in the container (\(error.message))",
                hint: error.hint
            )
        }
        if refreshed {
            StatusPrinter.status("Git credentials refreshed", item: info.name)
        } else {
            StatusPrinter.status("No host git credentials to refresh", item: info.name)
        }
    }
}

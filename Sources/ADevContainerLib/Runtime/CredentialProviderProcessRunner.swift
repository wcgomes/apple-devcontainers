import Foundation

/// Bounded, exact-environment provider runner. No raw output is displayed.
public struct CredentialProviderProcessRunner: ProcessRunning {
    var deadline: TimeInterval?
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 15) { self.timeout = timeout }
    func withDeadline(_ deadline: TimeInterval) -> Self { var copy = self; copy.deadline = deadline; return copy }
    public func run(executable: String, arguments: [String], environment: [String: String]?, currentDirectory: String?, stdinData: Data?) throws -> ProcessResult {
        guard currentDirectory == nil, (stdinData?.count ?? 0) <= GitCredentialProtocol.limit else { throw GitCredentialFailure.invalidMessage }
        let end = deadline ?? (ProcessInfo.processInfo.systemUptime + timeout)
        guard end > ProcessInfo.processInfo.systemUptime else { throw GitCredentialFailure.deadline }
        let process = try CredentialDuplexProcess(executable: executable, arguments: arguments, environment: environment ?? [:], guarded: true, deadline: end)
        defer { process.cancel() }
        if let stdinData { try process.send(stdinData) }; process.closeInput()
        var output = Data()
        while let chunk = try process.read(deadline: end) {
            guard chunk.count <= GitCredentialProtocol.limit - output.count else { throw GitCredentialFailure.overloaded }
            output.append(chunk)
        }
        return .init(exitCode: process.cancel(), stdout: output, stderr: Data())
    }
}

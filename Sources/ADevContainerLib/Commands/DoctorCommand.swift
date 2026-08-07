import Foundation

public struct DoctorReport: Equatable, Sendable {
    public var ok: Bool
    public var binaryPath: String
    public var version: String?
    public var status: String?
    public var messages: [String]

    public init(ok: Bool, binaryPath: String, version: String?, status: String?, messages: [String]) {
        self.ok = ok
        self.binaryPath = binaryPath
        self.version = version
        self.status = status
        self.messages = messages
    }
}

public enum DoctorCommand {
    public static func run(runtime: AppleContainerRuntime) throws -> DoctorReport {
        var messages: [String] = []
        let path = runtime.executablePath

        guard runtime.binaryExists() else {
            throw CLIError(
                code: CLIErrorCode.runtimeMissing,
                message: "Apple container binary not found at \(path)",
                hint: "Install Apple container and ensure it is at /usr/local/bin/container or on PATH"
            )
        }
        messages.append("binary: \(path)")

        let versions = try runtime.systemVersion()
        let versionString: String
        if let first = versions.first {
            let v = first["version"] as? String ?? "unknown"
            let name = first["appName"] as? String ?? "container"
            versionString = "\(name) \(v)"
        } else {
            versionString = "unknown"
        }
        messages.append("version: \(versionString)")

        let statusObj = try runtime.systemStatus()
        let status = (statusObj["status"] as? String) ?? "unknown"
        messages.append("status: \(status)")

        let ok = status.lowercased() == "running"
        if !ok {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Apple container system status is '\(status)' (expected running)",
                hint: "Start the container system (e.g. container system start)"
            )
        }

        return DoctorReport(
            ok: true,
            binaryPath: path,
            version: versionString,
            status: status,
            messages: messages
        )
    }

    public static func printReport(_ report: DoctorReport) {
        print("adevcontainer doctor: PASS")
        for m in report.messages {
            print("  \(m)")
        }
    }
}

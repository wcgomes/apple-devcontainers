import Foundation

/// Default OCI platform for Apple `container` pull/create (native host arch).
///
/// Product hosts are Apple Silicon → `linux/arm64`. Never enables Rosetta by default.
public enum ContainerPlatform {
    /// `linux/arm64` on arm64 hosts; `linux/amd64` only when the host is x86_64.
    public static var defaultLinuxPlatform: String {
        #if arch(arm64)
        return "linux/arm64"
        #elseif arch(x86_64)
        return "linux/amd64"
        #else
        // Fallback via uname when arch macros are unexpected.
        return platformFromUname()
        #endif
    }

    /// Resolve platform string from host machine architecture (for tests / override paths).
    public static func linuxPlatform(hostMachine: String) -> String {
        switch hostMachine.lowercased() {
        case "arm64", "aarch64":
            return "linux/arm64"
        case "x86_64", "amd64":
            return "linux/amd64"
        default:
            return "linux/arm64"
        }
    }

    private static func platformFromUname() -> String {
        var uts = utsname()
        uname(&uts)
        let machineCapacity = MemoryLayout.size(ofValue: uts.machine)
        let machine = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineCapacity) {
                String(cString: $0)
            }
        }
        return linuxPlatform(hostMachine: machine)
    }
}

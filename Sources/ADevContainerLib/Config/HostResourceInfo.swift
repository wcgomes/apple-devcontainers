import Foundation

/// Injectable host resource snapshot for hostRequirements preflight.
public protocol HostResourceProviding: Sendable {
    /// Physical memory in bytes, or `nil` if unreadable.
    var physicalMemoryBytes: UInt64? { get }
    /// Logical CPU count, or `nil` if unreadable.
    var cpuCount: Int? { get }
}

/// Production host info via Foundation / sysctl.
public struct SystemHostResourceInfo: HostResourceProviding, Sendable {
    public init() {}

    public var physicalMemoryBytes: UInt64? {
        // ProcessInfo is reliable on macOS; fall back to sysctl if needed.
        let fromProcess = ProcessInfo.processInfo.physicalMemory
        if fromProcess > 0 { return fromProcess }
        return Self.sysctlUInt64("hw.memsize")
    }

    public var cpuCount: Int? {
        let count = ProcessInfo.processInfo.processorCount
        if count > 0 { return count }
        if let n = Self.sysctlInt32("hw.ncpu"), n > 0 { return Int(n) }
        return nil
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = sysctlbyname(name, &value, &size, nil, 0)
        guard result == 0 else { return nil }
        return value
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname(name, &value, &size, nil, 0)
        guard result == 0 else { return nil }
        return value
    }
}

/// Fixed values for tests.
public struct MockHostResourceInfo: HostResourceProviding, Sendable {
    public var physicalMemoryBytes: UInt64?
    public var cpuCount: Int?

    public init(physicalMemoryBytes: UInt64? = nil, cpuCount: Int? = nil) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.cpuCount = cpuCount
    }
}

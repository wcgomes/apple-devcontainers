import Foundation

/// Injectable host resource snapshot for hostRequirements preflight.
public protocol HostResourceProviding: Sendable {
    /// Physical memory in bytes, or `nil` if unreadable.
    var physicalMemoryBytes: UInt64? { get }
    /// Logical CPU count, or `nil` if unreadable.
    var cpuCount: Int? { get }
}

/// Production host info via Foundation ProcessInfo.
public struct SystemHostResourceInfo: HostResourceProviding, Sendable {
    public init() {}

    public var physicalMemoryBytes: UInt64? {
        let fromProcess = ProcessInfo.processInfo.physicalMemory
        // 0 means unknown on the host; report nil per protocol.
        return fromProcess > 0 ? fromProcess : nil
    }

    public var cpuCount: Int? {
        let count = ProcessInfo.processInfo.processorCount
        // 0 means unknown on the host; report nil per protocol.
        return count > 0 ? count : nil
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

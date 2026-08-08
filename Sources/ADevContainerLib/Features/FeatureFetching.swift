import Foundation

/// Fetched feature package on disk (artifact root containing metadata + install.sh).
public struct FetchedFeaturePackage: Equatable, Sendable {
    public var reference: String
    /// Absolute path to extracted feature root.
    public var directoryPath: String

    public init(reference: String, directoryPath: String) {
        self.reference = reference
        self.directoryPath = directoryPath
    }

    public var metadataPath: String {
        (directoryPath as NSString).appendingPathComponent("devcontainer-feature.json")
    }

    public var installScriptPath: String {
        (directoryPath as NSString).appendingPathComponent("install.sh")
    }
}

/// Boundary for feature artifact fetch (mockable; OCI path never uses `container image pull`).
public protocol FeatureFetching: Sendable {
    /// Fetch feature files into a local directory and return the package root.
    func fetch(reference: String, destinationDirectory: String) throws -> FetchedFeaturePackage
}

/// Default fetcher: local path packages from the workspace, OCI via embedded registry client.
public struct DefaultFeatureFetcher: FeatureFetching, Sendable {
    public var workspacePath: String
    public var ociClient: OCIFeatureClient

    public init(
        workspacePath: String,
        ociClient: OCIFeatureClient = OCIFeatureClient()
    ) {
        self.workspacePath = workspacePath
        self.ociClient = ociClient
    }

    public func fetch(reference: String, destinationDirectory: String) throws -> FetchedFeaturePackage {
        if FeatureRef.isLocalPath(reference) {
            return try LocalFeatureLoader.load(
                reference: reference,
                workspacePath: workspacePath,
                destinationDirectory: destinationDirectory
            )
        }
        return try ociClient.fetch(reference: reference, destinationDirectory: destinationDirectory)
    }
}

/// Test double that copies a local fixture directory for a given reference.
public struct MockFeatureFetcher: FeatureFetching, Sendable {
    /// Map feature ref → on-disk package directory to copy.
    public var packagesByRef: [String: String]
    /// Optional error to throw for specific refs.
    public var errorsByRef: [String: CLIError]
    public var fetchCalls: LockedCounter

    public init(
        packagesByRef: [String: String] = [:],
        errorsByRef: [String: CLIError] = [:]
    ) {
        self.packagesByRef = packagesByRef
        self.errorsByRef = errorsByRef
        self.fetchCalls = LockedCounter()
    }

    public func fetch(reference: String, destinationDirectory: String) throws -> FetchedFeaturePackage {
        fetchCalls.increment()
        if let err = errorsByRef[reference] {
            throw err
        }
        guard let source = packagesByRef[reference] else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature '\(reference)' not found in mock fetcher",
                hint: "Register the fixture package for this ref in tests"
            )
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true)
        // Copy contents of source into destination
        let contents = try fm.contentsOfDirectory(atPath: source)
        for name in contents {
            let from = (source as NSString).appendingPathComponent(name)
            let to = (destinationDirectory as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: to) {
                try fm.removeItem(atPath: to)
            }
            try fm.copyItem(atPath: from, toPath: to)
        }
        return FetchedFeaturePackage(reference: reference, directoryPath: destinationDirectory)
    }
}

/// Thread-safe call counter for mocks.
public final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    public init() {}

    public func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

import Foundation

public enum PruneCommand {
    /// Removes workspace container, named volumes from config, and config image.
    /// - Returns: `0` if all resources handled or already gone; `1` if a delete of an existing resource failed.
    @discardableResult
    public static func run(
        workspacePath: String,
        runtime: AppleContainerRuntime,
        localEnv: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int32 {
        let resolved = try ConfigResolver.resolve(
            workspacePath: workspacePath,
            localEnv: localEnv
        )

        StatusPrinter.status("Pruning workspace resources")
        var hardFailure = false

        // 1. Container (missing is OK)
        if let info = try runtime.findByName(resolved.containerName) {
            StatusPrinter.status("Deleting container \(info.id)")
            do {
                try runtime.delete(nameOrId: info.id, force: true)
                print("Removed container \(info.id)")
            } catch {
                print("Failed container \(info.id): \(errorMessage(error))")
                hardFailure = true
            }
        } else {
            StatusPrinter.status("No container \(resolved.containerName)")
            print("Skipped container \(resolved.containerName) (not found)")
        }

        // 2. Named volumes from config only (not bind mounts, not global prune)
        let volumeNames = resolved.config.mounts
            .filter { $0.type == .volume }
            .map(\.source)
        var seenVolumes = Set<String>()
        for name in volumeNames where seenVolumes.insert(name).inserted {
            StatusPrinter.status("Deleting volume \(name)")
            let exists: Bool
            do {
                exists = try runtime.volumeExists(name)
            } catch {
                print("Failed volume \(name): \(errorMessage(error))")
                hardFailure = true
                continue
            }
            guard exists else {
                print("Skipped volume \(name) (not found)")
                continue
            }
            do {
                try runtime.deleteVolume(name: name)
                print("Removed volume \(name)")
            } catch {
                print("Failed volume \(name): \(errorMessage(error))")
                hardFailure = true
            }
        }

        // 3. Config image
        let image = resolved.config.image
        StatusPrinter.status("Deleting image \(image)")
        do {
            try runtime.deleteImage(reference: image)
            print("Removed image \(image)")
        } catch {
            let msg = errorMessage(error).lowercased()
            if isMissingResourceMessage(msg) {
                print("Skipped image \(image) (not found)")
            } else {
                print("Failed image \(image): \(errorMessage(error))")
                hardFailure = true
            }
        }

        StatusPrinter.status("Prune complete")
        return hardFailure ? 1 : 0
    }

    private static func errorMessage(_ error: Error) -> String {
        if let cli = error as? CLIError {
            return cli.message
        }
        return error.localizedDescription
    }

    private static func isMissingResourceMessage(_ lowercased: String) -> Bool {
        lowercased.contains("not found")
            || lowercased.contains("no such")
            || lowercased.contains("does not exist")
            || lowercased.contains("unknown")
    }
}

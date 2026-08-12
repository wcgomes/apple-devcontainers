import Foundation

public enum PruneCommand {
    /// Removes managed dev container, named volumes from config labels, config image,
    /// and volume-mode workspace volume (`*-ws` / label) when applicable.
    ///
    /// Selection is managed-only via `--name` / picker. Volumes come from labels
    /// (`config_volumes`, `workspace_volume`); image from runtime inspect.
    /// Candidate volumes are deleted only when unreferenced after target container delete.
    ///
    /// - Returns: `0` if all resources handled or already gone; `1` if a delete of an existing resource failed.
    @discardableResult
    public static func run(
        name: String? = nil,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker = .default
    ) throws -> Int32 {
        let info = try ManagedContainers.resolveSelection(
            name: name,
            runtime: runtime,
            picker: picker
        )

        // A recovery helper is an active repair endpoint. Ordinary prune must not remove the
        // endpoint, its workspace/config volumes, or its image; explicit container-only
        // `delete --name` remains the operator-facing cleanup path.
        if RecoveryHelper.isRecoveryHelper(info) {
            StatusPrinter.status("Skipping recovery helper resources")
            print("Skipped recovery helper \(info.id) and referenced resources")
            return 0
        }

        let target = PruneTarget(
            container: info,
            expectedContainerName: info.name,
            configVolumeNames: ContainerIdentity.parseConfigVolumeNames(from: info.labels),
            workspaceVolumeName: {
                let v = info.labels[ContainerIdentity.labelWorkspaceVolume]
                return (v?.isEmpty == false) ? v : nil
            }(),
            image: info.image
        )

        StatusPrinter.status("Pruning dev container resources")
        var hardFailure = false
        var containerDeleteFailed = false
        let targetContainerID = target.container?.id

        // 1. Container (missing is OK after resolve — should exist, but treat delete failures carefully)
        if let container = target.container {
            StatusPrinter.status("Deleting container", item: container.id)
            do {
                try runtime.delete(nameOrId: container.id, force: true)
                print("Removed container \(container.id)")
            } catch {
                print("Failed container \(container.id): \(errorMessage(error))")
                hardFailure = true
                containerDeleteFailed = true
            }
        } else if let expectedName = target.expectedContainerName {
            StatusPrinter.status("No container", item: expectedName)
            print("Skipped container \(expectedName) (not found)")
        }

        // 2. Named volumes from config + volume-mode workspace volume (only after container is gone)
        if !containerDeleteFailed {
            var volumeNames = target.configVolumeNames
            if let wsVol = target.workspaceVolumeName, !wsVol.isEmpty {
                volumeNames.append(wsVol)
            }
            var seenVolumes = Set<String>()
            for volName in volumeNames where seenVolumes.insert(volName).inserted {
                StatusPrinter.status("Checking volume", item: volName)
                let exists: Bool
                do {
                    exists = try runtime.volumeExists(volName)
                } catch {
                    print("Failed volume \(volName): \(errorMessage(error))")
                    hardFailure = true
                    continue
                }
                guard exists else {
                    print("Skipped volume \(volName) (not found)")
                    continue
                }

                let attached: [ContainerInfo]
                do {
                    attached = try runtime.containersAttached(to: volName).filter { info in
                        // Target is already deleted (or was absent); exclude on race.
                        guard let targetContainerID else { return true }
                        return info.id != targetContainerID
                    }
                } catch {
                    // Fail closed: cannot prove unreferenced → preserve + hard failure.
                    StatusPrinter.warning(
                        "Preserving volume '\(volName)'; could not prove unreferenced: \(errorMessage(error))"
                    )
                    hardFailure = true
                    continue
                }

                if !attached.isEmpty {
                    StatusPrinter.warning(
                        "Preserving volume '\(volName)'; referenced by containers: \(formatReferencingContainers(attached))"
                    )
                    continue
                }

                StatusPrinter.status("Deleting volume", item: volName)
                do {
                    try runtime.deleteVolume(name: volName)
                    print("Removed volume \(volName)")
                } catch {
                    print("Failed volume \(volName): \(errorMessage(error))")
                    hardFailure = true
                }
            }
        }

        // 3. Config image
        if let image = target.image, !image.isEmpty {
            StatusPrinter.status("Deleting image", item: image)
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
        }

        StatusPrinter.status("Prune complete")
        return hardFailure ? 1 : 0
    }

    // MARK: - Target

    private struct PruneTarget {
        var container: ContainerInfo?
        var expectedContainerName: String?
        var configVolumeNames: [String]
        var workspaceVolumeName: String?
        var image: String?
    }

    private static func formatReferencingContainers(_ containers: [ContainerInfo]) -> String {
        containers.map { info in
            // Prefer "name (id)" when both are available (spec warning shape).
            if !info.name.isEmpty && !info.id.isEmpty {
                return "\(info.name) (\(info.id))"
            }
            return info.name.isEmpty ? info.id : info.name
        }.joined(separator: ", ")
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

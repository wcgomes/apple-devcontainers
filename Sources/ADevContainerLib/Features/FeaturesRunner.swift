import Foundation

public struct FeaturesRunnerResult: Equatable, Sendable {
    public var contributions: FeatureContributions
    public var orderedRefs: [String]
    /// Fetched packages on disk (same order as fetch; not necessarily install order).
    public var packages: [FetchedFeaturePackage]
    /// Deterministic local image tag used for create (`adev-{nameBase}:{hash12}`).
    public var derivedImage: String
    /// True when an existing local tag was reused (no `container build`).
    public var reusedExistingImage: Bool
    /// Base image OCI USER from successful inspect (nil/empty when absent).
    /// When `didInspectBaseUser`, equals the derived image final USER after restore.
    public var baseImageUser: String?
    /// True when `baseImageUser` came from a successful base image inspect.
    public var didInspectBaseUser: Bool
    /// `remoteUser` / `containerUser` from base image `devcontainer.metadata` (for connection resolution;
    /// derived image may not carry the base label).
    public var metadataUsers: DevContainerMetadataLabel.ImageMetadataUsers

    public init(
        contributions: FeatureContributions,
        orderedRefs: [String],
        packages: [FetchedFeaturePackage],
        derivedImage: String,
        reusedExistingImage: Bool,
        baseImageUser: String? = nil,
        didInspectBaseUser: Bool = false,
        metadataUsers: DevContainerMetadataLabel.ImageMetadataUsers = .empty
    ) {
        self.contributions = contributions
        self.orderedRefs = orderedRefs
        self.packages = packages
        self.derivedImage = derivedImage
        self.reusedExistingImage = reusedExistingImage
        self.baseImageUser = baseImageUser
        self.didInspectBaseUser = didInspectBaseUser
        self.metadataUsers = metadataUsers
    }
}

/// Orchestrates resolve → fetch → order → Dockerfile generate → `container build` → derived tag.
/// Requires native arm64 BuildKit (`build.rosetta=false`); never passes `--rosetta`.
public enum FeaturesRunner {
    public struct Dependencies: @unchecked Sendable {
        public var fetcher: any FeatureFetching
        public var runtime: AppleContainerRuntime
        public var cacheRoot: String
        public var fileManager: FileManager
        public var platform: String

        public init(
            fetcher: any FeatureFetching = OCIFeatureClient(),
            runtime: AppleContainerRuntime,
            cacheRoot: String = FeatureCache.defaultRoot(),
            fileManager: FileManager = .default,
            platform: String = ContainerPlatform.defaultLinuxPlatform
        ) {
            self.fetcher = fetcher
            self.runtime = runtime
            self.cacheRoot = cacheRoot
            self.fileManager = fileManager
            self.platform = platform
        }
    }

    /// Resolve, fetch, order, merge contributions, and build (or reuse) a derived image.
    public static func run(
        features: [AdmittedFeature],
        baseImage: String,
        deps: Dependencies,
        remoteUser: String? = nil,
        containerUser: String? = nil,
        nameBase: String = ""
    ) throws -> FeaturesRunnerResult {
        guard !features.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.internalError,
                message: "FeaturesRunner.run called with empty features"
            )
        }

        StatusPrinter.status("Resolving features")
        try FeatureCache.ensureRoot(deps.cacheRoot, fileManager: deps.fileManager)

        var packages: [FetchedFeaturePackage] = []
        var orderedInput: [FeatureOrder.OrderedFeature] = []

        for feature in features {
            StatusPrinter.status("Fetching feature", item: feature.reference)
            let dest = FeatureCache.directory(for: feature.reference, cacheRoot: deps.cacheRoot)
            // Always re-fetch into cache dir for correctness when using live client;
            // mock fetcher overwrites. Clear dest first for clean extract.
            try? deps.fileManager.removeItem(atPath: dest)
            let pkg = try deps.fetcher.fetch(reference: feature.reference, destinationDirectory: dest)
            packages.append(pkg)

            let metaPath = pkg.metadataPath
            guard deps.fileManager.fileExists(atPath: metaPath) else {
                throw CLIError(
                    code: CLIErrorCode.featureMetadata,
                    property: "features",
                    message: "Feature '\(feature.reference)' is missing devcontainer-feature.json",
                    hint: "Confirm the feature artifact includes metadata at the package root"
                )
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: metaPath))
            let metadata = try FeatureMetadata.parse(data: data, featureRef: feature.reference)
            metadata.warnStripUnsafeContributions(featureRef: feature.reference)
            orderedInput.append(FeatureOrder.OrderedFeature(admitted: feature, metadata: metadata))
        }

        let ordered = try FeatureOrder.resolve(orderedInput)

        var contributions = try FeatureContributionMerge.collect(from: ordered)

        // Optional: merge base image metadata label when inspect is available.
        var metadataUsers = DevContainerMetadataLabel.ImageMetadataUsers.empty
        if let labels = try? deps.runtime.imageLabels(ref: baseImage) {
            DevContainerMetadataLabel.warnStripUnsafe(from: labels, imageRef: baseImage)
            let labelContrib = DevContainerMetadataLabel.parseContributions(from: labels)
            contributions = unionContributions(labelContrib, contributions)
            metadataUsers = DevContainerMetadataLabel.parseUsers(from: labels)
        }

        let derivedImage = DerivedImageTag.compute(
            baseImage: baseImage,
            ordered: ordered,
            nameBase: nameBase
        )

        // Base USER needed for Dockerfile restore and connection-user fallback after Features.
        // Inspect before reuse/build so both paths expose baseImageUser when inspect succeeds.
        let baseUser: String?
        do {
            baseUser = try deps.runtime.inspectImage(ref: baseImage).user
        } catch let err as CLIError {
            // On pure reuse we can still proceed without base USER if derived exists —
            // connection resolution will inspect the derived image. On build, fail closed below.
            if try deps.runtime.imageExists(ref: derivedImage) {
                StatusPrinter.status("Reusing features image", item: derivedImage)
                return FeaturesRunnerResult(
                    contributions: contributions,
                    orderedRefs: ordered.map(\.admitted.reference),
                    packages: packages,
                    derivedImage: derivedImage,
                    reusedExistingImage: true,
                    baseImageUser: nil,
                    didInspectBaseUser: false,
                    metadataUsers: metadataUsers
                )
            }
            throw CLIError(
                code: err.code,
                property: err.property ?? "features",
                message: "Failed to inspect base image USER for Features restore: \(err.message)",
                hint: err.hint ?? "Image inspect must succeed before building a features-derived image"
            )
        } catch {
            if try deps.runtime.imageExists(ref: derivedImage) {
                StatusPrinter.status("Reusing features image", item: derivedImage)
                return FeaturesRunnerResult(
                    contributions: contributions,
                    orderedRefs: ordered.map(\.admitted.reference),
                    packages: packages,
                    derivedImage: derivedImage,
                    reusedExistingImage: true,
                    baseImageUser: nil,
                    didInspectBaseUser: false,
                    metadataUsers: metadataUsers
                )
            }
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                property: "features",
                message: "Failed to inspect base image USER for Features restore: \(error.localizedDescription)",
                hint: "Image inspect must succeed before building a features-derived image"
            )
        }

        if try deps.runtime.imageExists(ref: derivedImage) {
            StatusPrinter.status("Reusing features image", item: derivedImage)
            return FeaturesRunnerResult(
                contributions: contributions,
                orderedRefs: ordered.map(\.admitted.reference),
                packages: packages,
                derivedImage: derivedImage,
                reusedExistingImage: true,
                baseImageUser: baseUser,
                didInspectBaseUser: true,
                metadataUsers: metadataUsers
            )
        }

        StatusPrinter.status("Building features image", item: derivedImage)

        let buildRoot = FeatureCache.buildContextRoot(cacheRoot: deps.cacheRoot)
        try deps.fileManager.createDirectory(atPath: buildRoot, withIntermediateDirectories: true)
        let contextDirectory = (buildRoot as NSString).appendingPathComponent(
            String(derivedImage.split(separator: ":").last ?? "build")
        )
        try? deps.fileManager.removeItem(atPath: contextDirectory)

        let buildContext = try FeatureDockerfileGenerator.write(
            baseImage: baseImage,
            ordered: ordered,
            packages: packages,
            contextDirectory: contextDirectory,
            remoteUser: remoteUser,
            containerUser: containerUser,
            baseUser: baseUser,
            contributions: contributions,
            fileManager: deps.fileManager
        )

        try deps.runtime.build(
            contextDirectory: buildContext.contextDirectory,
            dockerfilePath: buildContext.dockerfilePath,
            tag: derivedImage,
            platform: deps.platform
        )

        return FeaturesRunnerResult(
            contributions: contributions,
            orderedRefs: ordered.map(\.admitted.reference),
            packages: packages,
            derivedImage: derivedImage,
            reusedExistingImage: false,
            baseImageUser: baseUser,
            didInspectBaseUser: true,
            metadataUsers: metadataUsers
        )
    }

    private static func unionContributions(_ a: FeatureContributions, _ b: FeatureContributions) -> FeatureContributions {
        var out = a
        if b.initProcess { out.initProcess = true }
        for cap in b.capAdd where !out.capAdd.contains(cap) {
            out.capAdd.append(cap)
        }
        for (k, v) in b.containerEnv where out.containerEnv[k] == nil {
            out.containerEnv[k] = v
        }
        out.mounts.append(contentsOf: b.mounts)
        out.onCreateCommands.append(contentsOf: b.onCreateCommands)
        out.updateContentCommands.append(contentsOf: b.updateContentCommands)
        out.postCreateCommands.append(contentsOf: b.postCreateCommands)
        out.postStartCommands.append(contentsOf: b.postStartCommands)
        out.postAttachCommands.append(contentsOf: b.postAttachCommands)
        return out
    }
}

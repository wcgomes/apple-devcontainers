import Foundation

/// Resolve install order from dependsOn / installsAfter with declaration-order tie-break.
public enum FeatureOrder {
    public struct OrderedFeature: Equatable, Sendable {
        public var admitted: AdmittedFeature
        public var metadata: FeatureMetadata

        public init(admitted: AdmittedFeature, metadata: FeatureMetadata) {
            self.admitted = admitted
            self.metadata = metadata
        }
    }

    /// Topologically sort selected features. `declarationOrder` is the original config key order
    /// (we use sorted keys at admission — pass the admitted array order).
    public static func resolve(_ features: [OrderedFeature]) throws -> [OrderedFeature] {
        guard !features.isEmpty else { return [] }
        if features.count == 1 { return features }

        let refs = features.map(\.admitted.reference)
        // Build adjacency: edge A → B means A must install before B.
        var predecessors: [String: Set<String>] = [:]
        for f in features {
            predecessors[f.admitted.reference] = []
        }

        for f in features {
            let selfRef = f.admitted.reference
            // dependsOn: dependency must come first
            for depKey in f.metadata.dependsOn.keys {
                if let depRef = matchSelected(depKey, in: refs) {
                    predecessors[selfRef, default: []].insert(depRef)
                }
            }
            // installsAfter: listed features must come first
            for afterKey in f.metadata.installsAfter {
                if let afterRef = matchSelected(afterKey, in: refs) {
                    predecessors[selfRef, default: []].insert(afterRef)
                }
            }
        }

        // Declaration order for tie-break
        var declarationIndex: [String: Int] = [:]
        for (i, f) in features.enumerated() {
            declarationIndex[f.admitted.reference] = i
        }

        var remaining = Set(refs)
        var result: [OrderedFeature] = []
        let byRef = Dictionary(uniqueKeysWithValues: features.map { ($0.admitted.reference, $0) })

        while !remaining.isEmpty {
            let ready = remaining.filter { ref in
                let preds = predecessors[ref] ?? []
                return preds.isSubset(of: Set(result.map(\.admitted.reference)))
            }
            if ready.isEmpty {
                let cycle = remaining.sorted().joined(separator: ", ")
                throw CLIError(
                    code: CLIErrorCode.featureDependencyCycle,
                    property: "features",
                    message: "Feature dependency cycle detected among: \(cycle)",
                    hint: "Remove or adjust dependsOn / installsAfter so features form a DAG"
                )
            }
            // Tie-break: earliest declaration order
            let next = ready.sorted { a, b in
                (declarationIndex[a] ?? 0) < (declarationIndex[b] ?? 0)
            }.first!
            remaining.remove(next)
            result.append(byRef[next]!)
        }
        return result
    }

    private static func matchSelected(_ key: String, in refs: [String]) -> String? {
        refs.first { FeatureRef.matchesDependencyKey(key, selectedRef: $0) }
    }
}

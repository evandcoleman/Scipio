import Foundation
import PathKit
import ScipioKit

enum Runner {

    static func build(dependencies: [String]?, platforms: [Platform], force: Bool, skipClean: Bool) throws -> [AnyArtifact] {
        let processorOptions = ProcessorOptions(
            platforms: platforms,
            force: force,
            skipClean: skipClean
        )

        var artifacts: [AnyArtifact] = []
        var resolvedDependencies: [DependencyProducts] = []

        if let packages = Config.current.packages, !packages.isEmpty {
            let processor = PackageProcessor(dependencies: packages, options: processorOptions)
            let filtered = dependencies?
                .compactMap { name in packages.first { $0.name == name } }
            let (a, r) = try processor.process(dependencies: filtered, accumulatedResolvedDependencies: resolvedDependencies).wait() ?? ([], [])
            artifacts <<< a
            resolvedDependencies <<< r
        }

        if let binaries = Config.current.binaries, !binaries.isEmpty {
            let processor = BinaryProcessor(dependencies: binaries, options: processorOptions)
            let filtered = dependencies?
                .compactMap { name in binaries.first { $0.name == name } }
            let (a, r) = try processor.process(dependencies: filtered, accumulatedResolvedDependencies: resolvedDependencies).wait() ?? ([], [])
            artifacts <<< a
            resolvedDependencies <<< r
        }

        if let pods = Config.current.pods, !pods.isEmpty {
            let processor = CocoaPodProcessor(dependencies: pods, options: processorOptions)
            let filtered = dependencies?
                .compactMap { name in pods.first { $0.name == name } }
            let (a, r) = try processor.process(dependencies: filtered, accumulatedResolvedDependencies: resolvedDependencies).wait() ?? ([], [])
            artifacts <<< a
            resolvedDependencies <<< r
        }

        return artifacts
    }

    static func upload(artifacts: [AnyArtifact], force: Bool, skipClean: Bool) throws -> [CachedArtifact] {
        return try Config.current.cacheDelegator
            .upload(artifacts, force: force, skipClean: skipClean)
            .wait() ?? []
    }

    static func updatePackageManifest(at path: Path, with artifacts: [CachedArtifact], removeMissing: Bool) throws {
        let packageFile = try SwiftPackageFile(
            name: Config.current.name,
            path: path,
            platforms: Config.current.platformVersions,
            artifacts: artifacts,
            removeMissing: removeMissing
        )

        if packageFile.needsWrite(relativeTo: Config.current.packageRoot) {
            log.info("✍️  Writing \(Config.current.name) package manifest...")

            try packageFile.write(relativeTo: Config.current.packageRoot)
        }
    }
}

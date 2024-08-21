import Foundation
import PathKit
import ScipioKit

import Basics

let observabilitySystem = ObservabilitySystem { scope, diagnostics in
    print("[\(scope.description)] \(diagnostics.severity): \(diagnostics.message)")
}


enum Runner {

    static func build(
        dependencies: [String]?,
        platforms: [Platform],
        force: Bool,
        skipClean: Bool
    ) async throws -> [any LocalArtifact] {

        let processorOptions = ProcessorOptions(
            platforms: platforms,
            force: force,
            skipClean: skipClean
        )

        var artifacts: [any LocalArtifact] = []
        var productVersions: [any Product] = []

        if let packages = Config.current.packages, !packages.isEmpty {
            let processor = PackageProcessor(
                dependencies: packages,
                options: processorOptions,
                observabilityScope: observabilitySystem.topScope
            )
            let filtered = dependencies?
                .compactMap { name in packages.first { $0.name == name } }
            let (a, r) = try await processor.process(
                dependencies: filtered,
                accumulatedProducts: productVersions
            )
            artifacts <<< a
            productVersions <<< r
        }

        if let binaries = Config.current.binaries, !binaries.isEmpty {
            let processor = BinaryProcessor(
                dependencies: binaries,
                options: processorOptions,
                observabilityScope: observabilitySystem.topScope
            )
            let filtered = dependencies?
                .compactMap { name in binaries.first { $0.name == name } }
            let (a, r) = try await processor.process(
                dependencies: filtered,
                accumulatedProducts: productVersions
            )
            artifacts <<< a
            productVersions <<< r
        }

        if let releases = Config.current.githubReleases, !releases.isEmpty {
            let processor = GithubReleaseProcessor(
                dependencies: releases,
                options: processorOptions,
                observabilityScope: observabilitySystem.topScope
            )
            let filtered = dependencies?
                .compactMap { name in releases.first { $0.name == name } }
            let (a, r) = try await processor.process(
                dependencies: filtered,
                accumulatedProducts: productVersions
            )
            artifacts <<< a
            productVersions <<< r
        }

        return artifacts
    }

    static func upload(artifacts: [any LocalArtifact], force: Bool, skipClean: Bool) async throws -> [CachedArtifact] {
        return try await Config.current.cacheDelegator
            .upload(artifacts, force: force, skipClean: skipClean)
    }

    static func updatePackageManifest(
        at path: Path,
        with artifacts: [CachedArtifact],
        removeMissing: Bool
    ) throws {
        let packageFile = try SwiftPackageFile(
            name: Config.current.name,
            path: path,
            platforms: Config.current.platformVersions,
            artifacts: artifacts,
            removeMissing: removeMissing,
            observabilityScope: observabilitySystem.topScope
        )

        if packageFile.needsWrite(relativeTo: Config.current.packageRoot) {
            log.info("✍️  Writing \(Config.current.name) package manifest...")

            try packageFile.write(relativeTo: Config.current.packageRoot)
        }
    }
}

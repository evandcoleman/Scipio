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

        if let packages = Config.current.packages, !packages.isEmpty {
            let processor = PackageProcessor(dependencies: packages, options: processorOptions)
            let filtered = dependencies?
                .compactMap { name in packages.first { $0.name == name } }
            artifacts <<< try processor.process(dependencies: filtered).wait()
        }

        if let binaries = Config.current.binaries, !binaries.isEmpty {
            let processor = BinaryProcessor(dependencies: binaries, options: processorOptions)
            let filtered = dependencies?
                .compactMap { name in binaries.first { $0.name == name } }
            artifacts <<< try processor.process(dependencies: filtered).wait()
        }

        if let pods = Config.current.pods, !pods.isEmpty {
            let processor = CocoaPodProcessor(dependencies: pods, options: processorOptions)
            let filtered = dependencies?
                .compactMap { name in pods.first { $0.name == name } }
            artifacts <<< try processor.process(dependencies: filtered).wait()
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

        try packageFile.write()
    }
}

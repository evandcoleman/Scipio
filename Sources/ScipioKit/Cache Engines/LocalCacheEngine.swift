import Combine
import Foundation
import PathKit

public struct LocalCacheEngine: CacheEngine, Codable, Equatable {
    private let path: String

    public var normalizedPath: Path {
        if path.hasPrefix("/") {
            return Path(path)
        } else {
            return (Config.current.directory + Path(path))
                .normalize()
        }
    }

    public var requiresCompression: Bool { false }

    public enum LocalCacheEngineError: Error {
        case fileNotFound
    }

    public init(path: Path) {
        self.path = path.string
    }

    public func downloadUrl(for product: String, version: String) -> URL {
        return localPath(for: product, version: version).url
    }

    public func exists(product: String, version: String) async throws -> Bool {
        return localPath(for: product, version: version).exists
    }

    public func put(artifact: any LocalArtifact) async throws -> CachedArtifact {
        let cachePath = localPath(for: artifact.name, version: artifact.version)

        if cachePath.exists {
            try cachePath.delete()
        }

        if !cachePath.parent().exists {
            try cachePath.parent().mkpath()
        }

        if let artifact = artifact as? CompressedArtifact {
            try artifact.path.copy(cachePath)
        } else if let artifact = artifact as? Artifact {
            try artifact.path.copy(cachePath)
        }

        return CachedArtifact(
            name: artifact.name, 
            version: artifact.version,
            parentNames: artifact.parentNames,
            url: cachePath.url
        )
    }

    public func get(
        product: String,
        parentNames: [String],
        version: String,
        destination: Path
    ) async throws -> any LocalArtifact {
        let cachePath = localPath(for: product, version: version)

        if cachePath.exists {
            if destination.exists {
                try destination.delete()
            } else {
                try destination.parent().mkpath()
            }

            try cachePath.copy(destination)
            
            return Artifact(
                name: product,
                parentNames: parentNames,
                version: version,
                path: destination
            )
        } else {
            throw LocalCacheEngineError.fileNotFound
        }
    }

    private func localPath(for product: String, version: String) -> Path {
        return normalizedPath + product + "\(product)-\(version).xcframework"
    }
}

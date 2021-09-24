import Combine
import Foundation
import PathKit

public struct LocalCacheEngine: CacheEngine, Decodable, Equatable {
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

    public func exists(product: String, version: String) -> AnyPublisher<Bool, Error> {
        return Just(localPath(for: product, version: version).exists)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    public func put(artifact: Artifact) -> AnyPublisher<CachedArtifact, Error> {
        let cachePath = localPath(for: artifact.name, version: artifact.version)

        return Just(cachePath)
            .tryMap { cachePath -> CachedArtifact in
                if cachePath.exists {
                    try cachePath.delete()
                }

                if !cachePath.parent().exists {
                    try cachePath.parent().mkpath()
                }

                try artifact.path.copy(cachePath)

                return CachedArtifact(
                    name: artifact.name,
                    parentName: artifact.parentName,
                    url: cachePath.url
                )
            }
            .eraseToAnyPublisher()
    }

    public func get(product: String, in parentName: String, version: String, destination: Path) -> AnyPublisher<Artifact, Error> {
        let cachePath = localPath(for: product, version: version)

        return Just(cachePath)
            .tryMap { cachePath -> Artifact in
                if cachePath.exists {
                    if destination.exists {
                        try destination.delete()
                    }

                    try cachePath.copy(destination)

                    return Artifact(
                        name: product,
                        parentName: parentName,
                        version: version,
                        path: destination
                    )
                } else {
                    throw LocalCacheEngineError.fileNotFound
                }
            }
            .eraseToAnyPublisher()
    }

    private func localPath(for product: String, version: String) -> Path {
        return normalizedPath + product + "\(product)-\(version).xcframework"
    }
}

import Combine
import Foundation
import PathKit

struct LocalCacheEngine: CacheEngine, Decodable, Equatable {
    let path: String

    var requiresCompression: Bool { false }

    enum LocalCacheEngineError: Error {
        case fileNotFound
    }

    func downloadUrl(for product: String, version: String) -> URL {
        return localPath(for: product, version: version).url
    }

    func exists(product: String, version: String) -> AnyPublisher<Bool, Error> {
        return Just(localPath(for: product, version: version).exists)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    func put(artifact: Artifact) -> AnyPublisher<CachedArtifact, Error> {
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

                return CachedArtifact(name: artifact.name, url: cachePath.url)
            }
            .eraseToAnyPublisher()
    }

    func get(product: String, version: String, destination: Path) -> AnyPublisher<Artifact, Error> {
        let cachePath = localPath(for: product, version: version)

        return Just(cachePath)
            .tryMap { cachePath -> Artifact in
                if cachePath.exists {
                    try cachePath.copy(destination)

                    return Artifact(
                        name: product,
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
        return Path(path).normalize() + product + "\(product)-\(version).xcframework"
    }
}

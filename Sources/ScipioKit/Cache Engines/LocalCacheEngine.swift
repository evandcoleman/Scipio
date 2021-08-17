import Combine
import Foundation
import PathKit

struct LocalCacheEngine: CacheEngine, Decodable, Equatable {
    let path: String

    enum LocalCacheEngineError: Error {
        case fileNotFound
    }

    func downloadUrl(for product: String, version: String) -> URL {
        return cachePath(for: product, version: version).url
    }

    func exists(product: String, version: String) -> AnyPublisher<Bool, Error> {
        return Just(cachePath(for: product, version: version).exists)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    func put(product: String, version: String, path: Path) -> AnyPublisher<(), Error> {
        let cachePath = cachePath(for: product, version: version)

        return Just(cachePath)
            .tryMap { cachePath -> Void in
                if cachePath.exists {
                    try cachePath.delete()
                }

                if !cachePath.parent().exists {
                    try cachePath.parent().mkdir()
                }

                try path.copy(cachePath)

                return ()
            }
            .eraseToAnyPublisher()
    }

    func get(product: String, version: String, destination: Path) -> AnyPublisher<Path, Error> {
        let cachePath = cachePath(for: product, version: version)

        return Just(cachePath)
            .tryMap { cachePath -> Path in
                if cachePath.exists {
                    try cachePath.copy(destination)

                    return destination
                } else {
                    throw LocalCacheEngineError.fileNotFound
                }
            }
            .eraseToAnyPublisher()
    }

    private func cachePath(for product: String, version: String) -> Path {
        return Path(path) + product + "/\(product)-\(version).xcframework.zip"
    }
}

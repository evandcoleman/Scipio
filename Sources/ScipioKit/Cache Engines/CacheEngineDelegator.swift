import Combine
import Foundation
import PathKit
import Zip

public final class CacheEngineDelegator: Decodable, Equatable, CacheEngine {
    let local: LocalCacheEngine?
    let http: HTTPCacheEngine?

    enum CodingKeys: String, CodingKey {
        case local
        case http
    }

    private var cache: AnyCacheEngine {
        if let local = local {
            return AnyCacheEngine(local)
        } else if let http = http {
            return AnyCacheEngine(http)
        } else {
            log.fatal("At least one cache engine must be specified")
        }
    }

    private var existsCache: [String: Bool] = [:]

    public static func == (lhs: CacheEngineDelegator, rhs: CacheEngineDelegator) -> Bool {
        return lhs.local == rhs.local
            && lhs.http == rhs.http
    }

    public func downloadUrl(for product: String, version: String) -> URL {
        return cache.downloadUrl(for: product, version: version)
    }

    public func exists(product: String, version: String) -> AnyPublisher<Bool, Error> {
        if let exists = existsCache[[product, version].joined(separator: "-")] {
            return Just(exists)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        log.verbose("Checking if \(product)-\(version) exists")

        return cache.exists(product: product, version: version)
            .handleEvents(receiveOutput: { exists in
                self.existsCache[[product, version].joined(separator: "-")] = exists
            })
            .eraseToAnyPublisher()
    }

    public func get(product: String, version: String, destination: Path) -> AnyPublisher<AnyArtifact, Error> {
        log.verbose("Fetching \(product)-\(version)")
        return cache.get(product: product, version: version, destination: destination)
    }

    public func put(artifact: AnyArtifact) -> AnyPublisher<CachedArtifact, Error> {
        log.verbose("Caching \(artifact.name)-\(artifact.version)")
        return cache.put(artifact: artifact)
    }
}

extension CacheEngineDelegator {
    public func upload(_ artifacts: [Artifact], force: Bool) -> AnyPublisher<[CachedArtifact], Error> {
        return artifacts
            .publisher
            .setFailureType(to: Error.self)
            .flatMap { artifact -> AnyPublisher<CachedArtifact, Error> in
                return self.exists(artifact: artifact)
                    .flatMap { exists -> AnyPublisher<CachedArtifact, Error> in
                        if !exists || force {
                            log.info("☁️ Uploading \(artifact.name)...")

                            if self.cache.requiresCompression {
                                return self.compress(artifact)
                                    .flatMap { self.put(artifact: AnyArtifact($0)) }
                                    .eraseToAnyPublisher()
                            } else {
                                return self.put(artifact: AnyArtifact(artifact))
                            }
                        } else {
                            return Just(CachedArtifact(name: artifact.name, url: self.downloadUrl(for: artifact)))
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }
                    }
                    .eraseToAnyPublisher()
            }
            .collect()
            .eraseToAnyPublisher()
    }

    public func compress(_ artifact: Artifact) -> AnyPublisher<CompressedArtifact, Error> {
        return Future.try { promise in

            let compressed = CompressedArtifact(
                name: artifact.name,
                version: artifact.version,
                path: artifact.path.parent() + "\(artifact.path.lastComponent).zip"
            )

            if compressed.path.exists {
                try compressed.path.delete()
            }

            do {
                try Zip.zipFiles(
                    paths: [artifact.path.url],
                    zipFilePath: compressed.path.url,
                    password: nil,
                    progress: { log.progress("Compressing \(artifact.name)", percent: $0) }
                )
            } catch ZipError.zipFail {
                throw ScipioError.zipFailure(artifact)
            }

            promise(.success(compressed))
        }
        .eraseToAnyPublisher()
    }
}

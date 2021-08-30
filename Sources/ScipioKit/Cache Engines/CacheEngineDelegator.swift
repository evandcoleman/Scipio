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
        if let cache = _cache {
            return cache
        } else if let local = local {
            return AnyCacheEngine(local)
        } else if let http = http {
            return AnyCacheEngine(http)
        } else {
            log.fatal("At least one cache engine must be specified")
        }
    }

    private var _cache: AnyCacheEngine?
    private var existsCache: [String: Bool] = [:]

    public static func == (lhs: CacheEngineDelegator, rhs: CacheEngineDelegator) -> Bool {
        return lhs.local == rhs.local
            && lhs.http == rhs.http
    }

    public init<T: CacheEngine>(cache: T) {
        self.local = nil
        self.http = nil
        self._cache = AnyCacheEngine(cache)
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

    public func get(product: String, in parentName: String, version: String, destination: Path) -> AnyPublisher<AnyArtifact, Error> {
        log.verbose("Fetching \(product)-\(version)")

        let normalizedDestination = cache.requiresCompression && destination.extension != "zip" ? destination.parent() + "\(destination.lastComponent).zip" : destination

        return Future<AnyArtifact?, Error>.try {
            if normalizedDestination.exists, self.versionCachePath(for: product, version: version).exists, try normalizedDestination.checksum(.sha256) == (try self.versionCachePath(for: product, version: version).read()) {
                if self.cache.requiresCompression {
                    return AnyArtifact(CompressedArtifact(
                        name: product,
                        parentName: parentName,
                        version: version,
                        path: normalizedDestination
                    ))
                } else {
                    return AnyArtifact(Artifact(
                        name: product,
                        parentName: parentName,
                        version: version,
                        path: destination
                    ))
                }
            } else {
                return nil
            }
        }
        .flatMap { artifact -> AnyPublisher<AnyArtifact, Error> in
            if let artifact = artifact {
                return Just(artifact)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            } else {
                return self.cache
                    .get(product: product, in: parentName, version: version, destination: normalizedDestination)
                    .tryMap { artifact in
                        try self.versionCachePath(for: artifact.name, version: artifact.version)
                            .write(artifact.path.checksum(.sha256))

                        return artifact
                    }
                    .eraseToAnyPublisher()
            }
        }
        .eraseToAnyPublisher()
    }

    public func put(artifact: AnyArtifact) -> AnyPublisher<CachedArtifact, Error> {
        log.verbose("Caching \(artifact.name)-\(artifact.version)")

        return cache.put(artifact: artifact)
            .tryMap { cachedArtifact in
                try self.versionCachePath(for: artifact.name, version: artifact.version)
                    .write(artifact.path.checksum(.sha256))

                return cachedArtifact
            }
            .eraseToAnyPublisher()
    }

    private func versionCachePath(for product: String, version: String) -> Path {
        return Config.current.buildPath + ".version-\(product)-\(version)"
    }
}

extension CacheEngineDelegator {
    public func upload(_ artifacts: [AnyArtifact], force: Bool, skipClean: Bool) -> AnyPublisher<[CachedArtifact], Error> {
        return artifacts
            .publisher
            .setFailureType(to: Error.self)
            .flatMap(maxPublishers: .max(1)) { artifact -> AnyPublisher<CachedArtifact, Error> in
                return self.exists(artifact: artifact)
                    .flatMap { exists -> AnyPublisher<CachedArtifact, Error> in
                        if !exists || force {
                            log.info("☁️ Uploading \(artifact.name)...")

                            if self.cache.requiresCompression {
                                return self.compress(artifact, skipClean: skipClean)
                                    .flatMap { self.put(artifact: AnyArtifact($0)) }
                                    .eraseToAnyPublisher()
                            } else {
                                return self.put(artifact: AnyArtifact(artifact))
                            }
                        } else {
                            return Just(CachedArtifact(name: artifact.name, parentName: artifact.parentName, url: self.downloadUrl(for: artifact)))
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }
                    }
                    .eraseToAnyPublisher()
            }
            .collect()
            .eraseToAnyPublisher()
    }

    public func compress(_ artifact: AnyArtifact, skipClean: Bool) -> AnyPublisher<CompressedArtifact, Error> {
        return Future.try {

            if let base = artifact.base as? CompressedArtifact {
                return base
            }

            let compressed = CompressedArtifact(
                name: artifact.name,
                parentName: artifact.parentName,
                version: artifact.version,
                path: artifact.path.parent() + "\(artifact.path.lastComponent).zip"
            )

            if compressed.path.exists, !skipClean {
                try compressed.path.delete()
            } else if compressed.path.exists {
                return compressed
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

            return compressed
        }
        .eraseToAnyPublisher()
    }
}

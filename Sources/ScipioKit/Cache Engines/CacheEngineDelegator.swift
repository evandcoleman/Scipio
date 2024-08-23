import Combine
import Foundation
import PathKit
import Zip

public final class CacheEngineDelegator: Codable, Equatable, CacheEngine {
    let local: LocalCacheEngine?
    let s3: S3CacheEngine?
    let http: HTTPCacheEngine?

    enum CodingKeys: String, CodingKey {
        case local
        case s3
        case http
    }

    private var cache: AnyCacheEngine {
        if let cache = _cache {
            return cache
        } else if let local = local {
            return AnyCacheEngine(local)
        } else if let s3 = s3 {
            return AnyCacheEngine(s3)
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
            && lhs.s3 == rhs.s3
            && lhs.http == rhs.http
    }

    public init<T: CacheEngine>(cache: T) {
        self.local = cache as? LocalCacheEngine
        self.s3 = cache as? S3CacheEngine
        self.http = cache as? HTTPCacheEngine
        self._cache = AnyCacheEngine(cache)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(local, forKey: .local)
        try container.encodeIfPresent(s3, forKey: .s3)
        try container.encodeIfPresent(http, forKey: .http)
    }

    public func downloadUrl(for product: String, version: String) -> URL {
        return cache.downloadUrl(for: product, version: version)
    }

    public func exists(product: String, version: String) async throws -> Bool {
        if let exists = existsCache[[product, version].joined(separator: "-")] {
            return exists
        }

        log.verbose("Checking if \(product)-\(version) exists")

        let exists = try await cache.exists(product: product, version: version)
        existsCache[[product, version].joined(separator: "-")] = exists

        return exists
    }

    public func get(
        product: String,
        parentNames: [String],
        version: String,
        destination: Path
    ) async throws -> any LocalArtifact {
        log.verbose("Fetching \(product)-\(version)")

        let normalizedDestination = cache.requiresCompression && destination.extension != "zip" ? destination.parent() + "\(destination.lastComponent).zip" : destination

        let artifact: (any LocalArtifact)? =
            if
                normalizedDestination.exists,
                self.versionCachePath(for: product, version: version).exists,
                try normalizedDestination.checksum(.sha256) == (try self.versionCachePath(for: product, version: version).read())
            {
                if self.cache.requiresCompression {
                    CompressedArtifact(
                        name: product,
                        parentNames: parentNames,
                        version: version,
                        path: normalizedDestination
                    )
                } else {
                    Artifact(
                        name: product,
                        parentNames: parentNames,
                        version: version,
                        path: destination
                    )
                }
            } else {
                nil
            }

            if let artifact {
                return artifact
            } else {
                let artifact = try await self.cache
                    .get(product: product, parentNames: parentNames, version: version, destination: normalizedDestination)
                if artifact.path.exists, artifact.path.isFile {
                    try self.versionCachePath(for: artifact.name, version: artifact.version)
                        .write(artifact.path.checksum(.sha256))
                }

                return artifact
            }
    }

    public func put(artifact: any LocalArtifact) async throws -> CachedArtifact {
        log.verbose("Caching \(artifact.name)-\(artifact.version)")

        let cachedArtifact = try await cache.put(artifact: artifact)
        if artifact.path.isFile {
            try self.versionCachePath(for: artifact.name, version: artifact.version)
                .write(artifact.path.checksum(.sha256))
        }

        return cachedArtifact
    }

    private func versionCachePath(for product: String, version: String) -> Path {
        return Config.current.buildPath + ".version-\(product)-\(version)"
    }
}

extension CacheEngineDelegator {
    public func upload(_ artifacts: [any LocalArtifact], force: Bool, skipClean: Bool) async throws -> [CachedArtifact] {
        var cachedArtifacts: [CachedArtifact] = []

        for artifact in artifacts {
            let exists = try await exists(artifact: artifact)

            if !exists || force {
                log.info("☁️ Uploading \(artifact.name)...")

                if self.cache.requiresCompression {
                    let compessed = try self.compress(artifact, skipClean: skipClean)
                    let cached = try await self.put(artifact: compessed)
                    cachedArtifacts.append(cached)
                } else {
                    let cached = try await self.put(artifact: artifact)
                    cachedArtifacts.append(cached)
                }
            } else {
                if let compressed = artifact as? CompressedArtifact {
                    let cached = try CachedArtifact(name: artifact.name, version: compressed.version, parentNames: artifact.parentNames, url: self.downloadUrl(for: artifact), localPath: compressed.path)
                    cachedArtifacts.append(cached)
                } else {
                    let cached = CachedArtifact(name: artifact.name, version: artifact.version, parentNames: artifact.parentNames, url: self.downloadUrl(for: artifact))
                    cachedArtifacts.append(cached)
                }
            }
        }

        return cachedArtifacts
    }

    public func compress(_ artifact: any LocalArtifact, skipClean: Bool) throws -> CompressedArtifact {
        if let base = artifact as? CompressedArtifact {
            return base
        }

        let compressed = CompressedArtifact(
            name: artifact.name,
            parentNames: artifact.parentNames,
            version: artifact.version,
            path: artifact.path.parent() + "\(artifact.path.lastComponent).zip"
        )

        if compressed.path.exists, !skipClean {
            try compressed.path.delete()
        } else if compressed.path.exists {
            return compressed
        }

        do {
            log.info("Compressing \(artifact.name):")
            try Zip.zipFiles(
                paths: [artifact.path.url],
                zipFilePath: compressed.path.url,
                password: nil,
                progress: { log.progress(percent: $0) }
            )
        } catch ZipError.zipFail {
            throw ScipioError.zipFailure(artifact)
        }

        return compressed
    }
}

import Combine
import Foundation
import PathKit

public protocol CacheEngine {
    var requiresCompression: Bool { get }

    func downloadUrl(for product: String, version: String) -> URL
    func exists(product: String, version: String) async throws -> Bool
    func get(product: String, parentNames: [String], version: String, destination: Path) async throws -> any LocalArtifact
    func put(artifact: any LocalArtifact) async throws -> CachedArtifact
}

public extension CacheEngine {
    var requiresCompression: Bool {
        return true
    }

    func downloadUrl(for artifact: AnyArtifact) -> URL {
        return downloadUrl(for: artifact.name, version: artifact.version)
    }

    func exists(artifact: AnyArtifact) async throws -> Bool {
        return try await exists(product: artifact.name, version: artifact.version)
    }
}

public struct AnyCacheEngine {

    public let requiresCompression: Bool

    private let _downloadUrl: (String, String) -> URL
    private let _exists: (String, String) async throws -> Bool
    private let _get: (String, [String], String, Path) async throws -> any LocalArtifact
    private let _put: (any LocalArtifact) async throws -> CachedArtifact

    public init<T: CacheEngine>(_ base: T) {
        requiresCompression = base.requiresCompression
        _downloadUrl = base.downloadUrl
        _exists = base.exists
        _get = { try await base.get(product: $0, parentNames: $1, version: $2, destination: $3) }
        _put = { try await base.put(artifact: $0) }
    }

    public func downloadUrl(for product: String, version: String) -> URL {
        return _downloadUrl(product, version)
    }

    public func exists(product: String, version: String) async throws -> Bool {
        return try await _exists(product, version)
    }

    public func get(product: String, parentNames: [String], version: String, destination: Path) async throws -> any LocalArtifact {
        return try await _get(product, parentNames, version, destination)
    }

    public func put(artifact: any LocalArtifact) async throws -> CachedArtifact {
        return try await _put(artifact)
    }
}

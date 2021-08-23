import Combine
import Foundation
import PathKit

public protocol CacheEngine {
    associatedtype ArtifactType: ArtifactProtocol

    var requiresCompression: Bool { get }

    func downloadUrl(for product: String, version: String) -> URL
    func exists(product: String, version: String) -> AnyPublisher<Bool, Error>
    func get(product: String, version: String, destination: Path) -> AnyPublisher<ArtifactType, Error>
    func put(artifact: ArtifactType) -> AnyPublisher<CachedArtifact, Error>
}

public extension CacheEngine {
    var requiresCompression: Bool {
        return true
    }

    func downloadUrl(for artifact: Artifact) -> URL {
        return downloadUrl(for: artifact.name, version: artifact.version)
    }

    func exists(artifact: Artifact) -> AnyPublisher<Bool, Error> {
        return exists(product: artifact.name, version: artifact.version)
    }
}

public struct AnyCacheEngine {

    public let requiresCompression: Bool

    private let _downloadUrl: (String, String) -> URL
    private let _exists: (String, String) -> AnyPublisher<Bool, Error>
    private let _get: (String, String, Path) -> AnyPublisher<AnyArtifact, Error>
    private let _put: (AnyArtifact) -> AnyPublisher<CachedArtifact, Error>

    public init<T: CacheEngine>(_ base: T) {
        requiresCompression = base.requiresCompression
        _downloadUrl = base.downloadUrl
        _exists = base.exists
        _get = { base.get(product: $0, version: $1, destination: $2)
            .map { AnyArtifact($0) }.eraseToAnyPublisher() }
        _put = { base.put(artifact: $0.base as! T.ArtifactType) }
    }

    public func downloadUrl(for product: String, version: String) -> URL {
        return _downloadUrl(product, version)
    }

    public func exists(product: String, version: String) -> AnyPublisher<Bool, Error> {
        return _exists(product, version)
    }

    public func get(product: String, version: String, destination: Path) -> AnyPublisher<AnyArtifact, Error> {
        return _get(product, version, destination)
    }

    public func put(artifact: AnyArtifact) -> AnyPublisher<CachedArtifact, Error> {
        return _put(artifact)
    }
}

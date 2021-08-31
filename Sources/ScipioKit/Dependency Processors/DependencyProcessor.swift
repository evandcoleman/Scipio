import Combine
import Foundation
import PathKit

public protocol DependencyProcessor {
    associatedtype Input: Dependency
    associatedtype ResolvedInput: DependencyProducts

    var dependencies: [Input] { get }
    var options: ProcessorOptions { get }

    init(dependencies: [Input], options: ProcessorOptions)

    func preProcess() -> AnyPublisher<[ResolvedInput], Error>
    func process(_ dependency: Input?, resolvedTo resolvedDependency: ResolvedInput) -> AnyPublisher<[AnyArtifact], Error>
    func postProcess() -> AnyPublisher<(), Error>
}

public protocol DependencyProducts {
    var name: String { get }
    var productNames: [String]? { get }

    func version(for productName: String) -> String
}

extension DependencyProcessor {
    public func process(dependencies onlyDependencies: [Input]? = nil) -> AnyPublisher<[AnyArtifact], Error> {
        return preProcess()
            .tryFlatMap { dependencyProducts -> AnyPublisher<[[AnyArtifact]], Error> in

                let conflictingDependencies: [String: [String]] = dependencyProducts
                    .reduce(into: [:]) { accumulated, dependency in
                        let productNames = Dictionary(
                            uniqueKeysWithValues: (dependency.productNames ?? [])
                                .map { ($0, [dependency.name]) }
                                .filter { !$0.0.isEmpty }
                        )

                        accumulated.merge(productNames) { $0 + $1 }
                    }
                    .filter { $0.value.count > 1 }

                if let conflict = conflictingDependencies.first {
                    throw ScipioError.conflictingDependencies(
                        product: conflict.key,
                        conflictingDependencies: conflict.value
                    )
                }

                return dependencyProducts
                    .publisher
                    .setFailureType(to: Error.self)
                    .tryFlatMap(maxPublishers: .max(1)) { dependencyProduct -> AnyPublisher<[AnyArtifact], Error> in
                        let dependencies = onlyDependencies ?? self.dependencies
                        let dependency = dependencies.first(where: { $0.name == dependencyProduct.name })

                        if let onlyDependencies = onlyDependencies,
                           !onlyDependencies.contains(where: { $0.name == dependencyProduct.name }) {
                            return Empty()
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }

                        guard let productNames = dependencyProduct.productNames else {
                            return self.process(dependency, resolvedTo: dependencyProduct)
                        }

                        return productNames
                            .publisher
                            .setFailureType(to: Error.self)
                            .flatMap(maxPublishers: .max(2)) { productName -> AnyPublisher<String, Error> in
                                if self.options.force {
                                    return Just(productName)
                                        .setFailureType(to: Error.self)
                                        .eraseToAnyPublisher()
                                }

                                return Config.current.cacheDelegator
                                    .exists(product: productName, version: dependencyProduct.version(for: productName))
                                    .filter { !$0 }
                                    .map { _ in productName }
                                    .eraseToAnyPublisher()
                            }
                            .collect()
                            .flatMap { missingProducts -> AnyPublisher<[AnyArtifact], Error> in
                                if missingProducts.isEmpty {
                                    return productNames
                                        .publisher
                                        .setFailureType(to: Error.self)
                                        .tryFlatMap(maxPublishers: .max(1)) { productName -> AnyPublisher<AnyArtifact, Error> in
                                            let path = Config.current.buildPath + "\(productName).xcframework"

                                            if path.exists, self.options.skipClean {
                                                return Just(AnyArtifact(Artifact(
                                                    name: productName,
                                                    parentName: dependencyProduct.name,
                                                    version: dependencyProduct.version(for: productName),
                                                    path: path
                                                )))
                                                .setFailureType(to: Error.self)
                                                .eraseToAnyPublisher()
                                            } else {
                                                return Config.current.cacheDelegator
                                                    .get(
                                                        product: productName,
                                                        in: dependencyProduct.name,
                                                        version: dependencyProduct.version(for: productName),
                                                        destination: path
                                                    )
                                                    .eraseToAnyPublisher()
                                            }
                                        }
                                        .collect()
                                        .eraseToAnyPublisher()
                                } else {
                                    return self.process(dependency, resolvedTo: dependencyProduct)
                                }
                            }
                            .eraseToAnyPublisher()
                    }
                    .collect()
                    .eraseToAnyPublisher()
            }
            .map { $0.flatMap { $0 } }
            .flatMap { next in self.postProcess().map { _ in next } }
            .eraseToAnyPublisher()
    }
}

public struct ProcessorOptions {
    public let platforms: [Platform]
    public let force: Bool
    public let skipClean: Bool

    public init(platforms: [Platform], force: Bool, skipClean: Bool) {
        self.platforms = platforms
        self.force = force
        self.skipClean = skipClean
    }
}

public protocol ArtifactProtocol {
    var name: String { get }
    var parentName: String { get }
    var version: String { get }
    var resource: URL { get }
}

public struct AnyArtifact: ArtifactProtocol {
    public let name: String
    public let parentName: String
    public let version: String
    public let resource: URL

    public var path: Path {
        return Path(resource.path)
    }

    public let base: Any

    public init<T: ArtifactProtocol>(_ base: T) {
        self.base = base
        
        name = base.name
        parentName = base.parentName
        version = base.version
        resource = base.resource
    }
}

public struct Artifact: ArtifactProtocol {
    public let name: String
    public let parentName: String
    public let version: String
    public let path: Path

    public var resource: URL { path.url }
}

public struct CompressedArtifact: ArtifactProtocol {
    public let name: String
    public let parentName: String
    public let version: String
    public let path: Path

    public var resource: URL { path.url }

    public func checksum() throws -> String {
        return try path.checksum(.sha256)
    }
}

public struct CachedArtifact {
    public let name: String
    public let parentName: String
    public let url: URL
    public let checksum: String?

    internal var localPath: Path?

    init(name: String, parentName: String, url: URL, localPath: Path) throws {
        self.name = name
        self.parentName = parentName
        self.url = url
        self.checksum = try localPath.checksum(.sha256)
        self.localPath = localPath
    }

    init(name: String, parentName: String, url: URL) {
        self.name = name
        self.parentName = parentName
        self.url = url
        self.checksum = nil
        self.localPath = nil
    }
}

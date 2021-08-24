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
    func process(_ dependency: Input?, resolvedTo resolvedDependency: ResolvedInput) -> AnyPublisher<[Artifact], Error>
    func postProcess() -> AnyPublisher<(), Error>
}

public protocol DependencyProducts {
    var name: String { get }
    var productNames: [String]? { get }

    func version(for productName: String) -> String
}

extension DependencyProcessor {
    public func process(dependencies onlyDependencies: [Input]? = nil) -> AnyPublisher<[Artifact], Error> {
        return preProcess()
            .flatMap { dependencyProducts in
                return dependencyProducts
                    .publisher
                    .setFailureType(to: Error.self)
                    .tryFlatMap(maxPublishers: .max(1)) { dependencyProduct -> AnyPublisher<[Artifact], Error> in
                        let dependency = (onlyDependencies ?? dependencies).first(where: { $0.name == dependencyProduct.name })

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
                            .flatMap { missingProducts -> AnyPublisher<[Artifact], Error> in
                                if missingProducts.isEmpty {
                                    return Just(productNames
                                        .compactMap { productName in
                                            let path = Config.current.buildPath + "\(productName).xcframework"

                                            // TODO: Probably shouldn't fail silently here
                                            guard path.exists else { return nil }

                                            return Artifact(
                                                name: productName,
                                                version: dependencyProduct.version(for: productName),
                                                path: path
                                            )
                                        })
                                        .setFailureType(to: Error.self)
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
    var version: String { get }
    var resource: URL { get }
}

public struct AnyArtifact: ArtifactProtocol {
    public let name: String
    public let version: String
    public let resource: URL

    public let base: Any

    public init<T: ArtifactProtocol>(_ base: T) {
        self.base = base
        
        name = base.name
        version = base.version
        resource = base.resource
    }
}

public struct Artifact: ArtifactProtocol {
    public let name: String
    public let version: String
    public let path: Path

    public var resource: URL { path.url }
}

public struct CompressedArtifact: ArtifactProtocol {
    public let name: String
    public let version: String
    public let path: Path

    public var resource: URL { path.url }

    public func checksum() throws -> String {
        return try path.checksum(.sha256)
    }
}

public struct CachedArtifact {
    public let name: String
    public let url: URL
    public let checksum: String?

    init(name: String, url: URL, localPath: Path) throws {
        self.name = name
        self.url = url
        self.checksum = try localPath.checksum(.sha256)
    }

    init(name: String, url: URL) {
        self.name = name
        self.url = url
        self.checksum = nil
    }
}

import Combine
import Foundation
import PathKit

import Basics

public protocol NamedDependency {
    var name: String { get }
}

public protocol DependencyProcessor {
    associatedtype Input: Dependency
    associatedtype ResolvedInput: Product

    var dependencies: [Input] { get }
    var options: ProcessorOptions { get }

    init(dependencies: [Input], options: ProcessorOptions, observabilityScope: ObservabilityScope)

    func preProcess() async throws -> [ResolvedInput]
    func process(
        dependencies: [Input],
        product: ResolvedInput
    ) async throws -> [AnyArtifact]
    func postProcess() async throws
}

public protocol Product: Equatable, Hashable {
    var productName: String { get }
    var version: String { get }
    var parentNames: [String] { get }
}

public struct ProductVersion: Equatable, Hashable {

    public var productName: String
    public var version: String
    public var parentNames: [String]
}

extension DependencyProcessor {
    public func existingArtifacts(dependencies onlyDependencies: [Input]? = nil) async throws -> [AnyArtifact] {
        let dependencies = onlyDependencies ?? self.dependencies

        return try await preProcess()
            .filter { resolved in dependencies.contains(where: { resolved.parentNames.contains($0.name) }) }
            .compactMap { dependencyProduct -> AnyArtifact? in
                let path =
                    if Config.current.cacheDelegator.requiresCompression {
                        try Config.current.getCompressedFrameworkPath(
                            productName: dependencyProduct.productName
                        )
                    } else {
                        try Config.current.getFrameworkPath(
                            productName: dependencyProduct.productName
                        )
                    }

                guard path.exists else {
                    log.warning("Skipping \(path.lastComponent) because it doesn't exist.")
                    return nil
                }

                return AnyArtifact(Artifact(
                    name: dependencyProduct.productName,
                    parentNames: dependencyProduct.parentNames,
                    version: dependencyProduct.version,
                    path: path
                ))
            }
    }

    public func process(
        dependencies onlyDependencies: [Input]? = nil,
        accumulatedProducts: [any Product]
    ) async throws -> ([AnyArtifact], [ResolvedInput]) {

        let dependencyProducts = try await preProcess()
        let conflictingDependencies: [String: [String]] = (dependencyProducts + accumulatedProducts)
            .reduce(into: [:]) { accumulated, dependency in
                let productNames = [
                    dependency.productName: dependency.parentNames
                ]

                accumulated.merge(productNames) { $0 + $1 }
            }
            .filter { $0.value.count > 1 }

        if let conflict = conflictingDependencies.first {
            throw ScipioError.conflictingDependencies(
                product: conflict.key,
                conflictingDependencies: conflict.value
            )
        }

        var allArtifacts: [AnyArtifact] = []
        var missingProducts: [ResolvedInput] = []

        for dependencyProduct in dependencyProducts {
            let dependencies = onlyDependencies ?? self.dependencies
            let dependency = dependencies.first(where: { dependencyProduct.parentNames.contains($0.name) })

            if 
                let onlyDependencies = onlyDependencies,
                !onlyDependencies.contains(
                    where: { dependencyProduct.parentNames.contains($0.name) || dependencyProduct.productName == $0.name }
                )
            {
                continue
            }

            if options.force {
                missingProducts.append(dependencyProduct)
            }

            let exists = try await Config.current.cacheDelegator
                .exists(product: dependencyProduct.productName, version: dependencyProduct.version)

            if !exists {
                missingProducts.append(dependencyProduct)
            }
        }

        missingProducts = missingProducts.uniqued()

        if missingProducts.isEmpty {
            for dependencyProduct in dependencyProducts {
                let path = try Config.current.getFrameworkPath(productName: dependencyProduct.productName)

                if path.exists, self.options.skipClean {
                    allArtifacts.append(AnyArtifact(Artifact(
                        name: dependencyProduct.productName, 
                        parentNames: dependencyProduct.parentNames,
                        version: dependencyProduct.version,
                        path: path
                    )))
                } else {
                    let artifact = try await Config.current.cacheDelegator
                        .get(
                            product: dependencyProduct.productName,
                            parentNames: dependencyProduct.parentNames,
                            version: dependencyProduct.version,
                            destination: path
                        )
                    allArtifacts.append(artifact)
                }
            }
        } else {
            let dependencies = onlyDependencies ?? self.dependencies

            for product in missingProducts {
                let filteredDependencies = dependencies
                    .filter { product.parentNames.contains($0.name) || $0.name == product.productName }

                allArtifacts.append(
                    contentsOf: try await process(
                        dependencies: filteredDependencies,
                        product: product
                    )
                )
            }
        }

        try await postProcess()

        return (allArtifacts, dependencyProducts)
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
    var parentNames: [String] { get }
    var version: String { get }
    var resource: URL { get }
}

public struct AnyArtifact: ArtifactProtocol {
    public let name: String
    public let parentNames: [String]
    public let version: String
    public let resource: URL

    public var path: Path {
        return Path(resource.path)
    }

    public let base: Any

    public init<T: ArtifactProtocol>(_ base: T) {
        self.base = base
        
        name = base.name
        parentNames = base.parentNames
        version = base.version
        resource = base.resource
    }
}

public struct Artifact: ArtifactProtocol {
    public let name: String
    public let parentNames: [String]
    public let version: String
    public let path: Path

    public var resource: URL { path.url }
}

public struct CompressedArtifact: ArtifactProtocol {
    public let name: String
    public let parentNames: [String]
    public let version: String
    public let path: Path

    public var resource: URL { path.url }

    public func checksum() throws -> String {
        return try path.checksum(.sha256)
    }
}

public struct CachedArtifact {
    public let name: String
    public let parentNames: [String]
    public let url: URL
    public let checksum: String?

    internal var localPath: Path?

    init(name: String, parentNames: [String], url: URL, localPath: Path) throws {
        self.name = name
        self.parentNames = parentNames
        self.url = url
        self.checksum = try localPath.checksum(.sha256)
        self.localPath = localPath
    }

    init(name: String, parentNames: [String], url: URL) {
        self.name = name
        self.parentNames = parentNames
        self.url = url
        self.checksum = nil
        self.localPath = nil
    }
}

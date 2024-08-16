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
    ) async throws -> [any LocalArtifact]
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
    public func existingArtifacts(dependencies onlyDependencies: [Input]? = nil) async throws -> [any LocalArtifact] {
        let dependencies = onlyDependencies ?? self.dependencies

        return try await preProcess()
            .filter { resolved in dependencies.contains(where: { resolved.parentNames.contains($0.name) }) }
            .compactMap { dependencyProduct -> (any LocalArtifact)? in
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

                return Artifact(
                    name: dependencyProduct.productName,
                    parentNames: dependencyProduct.parentNames,
                    version: dependencyProduct.version,
                    path: path
                )
            }
    }

    public func process(
        dependencies onlyDependencies: [Input]? = nil,
        accumulatedProducts: [any Product]
    ) async throws -> ([any LocalArtifact], [ResolvedInput]) {

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

        var allArtifacts: [any LocalArtifact] = []
        var missingProducts: [ResolvedInput] = []
        var existingProducts: [ResolvedInput] = []

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
            } else {
                existingProducts.append(dependencyProduct)
            }
        }

        missingProducts = missingProducts.uniqued()

        if missingProducts.isEmpty {
            for dependencyProduct in dependencyProducts {
                let path = try Config.current.getFrameworkPath(productName: dependencyProduct.productName)

                if path.exists, self.options.skipClean {
                    allArtifacts.append(Artifact(
                        name: dependencyProduct.productName, 
                        parentNames: dependencyProduct.parentNames,
                        version: dependencyProduct.version,
                        path: path
                    ))
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

        for product in existingProducts {
            let path = try Config.current.getFrameworkPath(productName: product.productName)

            if path.exists {
                allArtifacts.append(Artifact(
                    name: product.productName,
                    parentNames: product.parentNames,
                    version: product.version,
                    path: path
                ))
            }
        }

        try await postProcess()

        return (
            Array(
                allArtifacts
                    .reduce(
                        into: [String: any LocalArtifact]()
                    ) { $0[$1.name] = $1 }
                    .values
            ),
            dependencyProducts
        )
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

public protocol LocalArtifact: ArtifactProtocol {
    var path: Path { get }
}

public protocol ArtifactProtocol: Hashable {
    var name: String { get }
    var parentNames: [String] { get }
    var version: String { get }
    var resource: URL { get }
}

public typealias AnyArtifact = any ArtifactProtocol

//public struct AnyArtifact: ArtifactProtocol {
//    public let name: String
//    public let parentNames: [String]
//    public let version: String
//    public let resource: URL
//
//    public var path: Path {
//        return Path(resource.path)
//    }
//
//    public let base: AnyHashable
//
//    public init<T: ArtifactProtocol>(_ base: T) {
//        self.base = base
//        
//        name = base.name
//        parentNames = base.parentNames
//        version = base.version
//        resource = base.resource
//    }
//
//    public func hash(into hasher: inout Hasher) {
//        hasher.combine(name)
//        hasher.combine(parentNames)
//        hasher.combine(version)
//    }
//}

public struct Artifact: LocalArtifact {
    public let name: String
    public let parentNames: [String]
    public let version: String
    public let path: Path

    public var resource: URL { path.url }
}

public struct CompressedArtifact: LocalArtifact {
    public let name: String
    public let parentNames: [String]
    public let version: String
    public let path: Path

    public var resource: URL { path.url }

    public func checksum() throws -> String {
        return try path.checksum(.sha256)
    }
}

public struct CachedArtifact: ArtifactProtocol {

    public let name: String
    public let version: String
    public let parentNames: [String]
    public let url: URL
    public let checksum: String?

    internal var localPath: Path?

    public var resource: URL {
        url
    }

    init(name: String, version: String, parentNames: [String], url: URL, localPath: Path) throws {
        self.name = name
        self.version = version
        self.parentNames = parentNames
        self.url = url
        self.checksum = try localPath.checksum(.sha256)
        self.localPath = localPath
    }

    init(name: String, version: String, parentNames: [String], url: URL) {
        self.name = name
        self.version = version
        self.parentNames = parentNames
        self.url = url
        self.checksum = nil
        self.localPath = nil
    }

    init(artifact: any LocalArtifact) {
        self.name = artifact.name
        self.version = artifact.version
        self.parentNames = artifact.parentNames
        self.url = artifact.path.url
        self.localPath = artifact.path
        self.checksum = nil
    }
}

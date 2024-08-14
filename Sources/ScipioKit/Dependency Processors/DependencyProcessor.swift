import Combine
import Foundation
import PathKit

import Basics

public protocol NamedDependency {
    var name: String { get }
}

public protocol DependencyProcessor {
    associatedtype Input: Dependency
    associatedtype ResolvedInput: DependencyProducts

    var dependencies: [Input] { get }
    var options: ProcessorOptions { get }

    init(dependencies: [Input], options: ProcessorOptions, observabilityScope: ObservabilityScope)

    func preProcess() async throws -> [ResolvedInput]
    func process(_ dependency: Input?, resolvedTo resolvedDependency: ResolvedInput) async throws -> [AnyArtifact]
    func postProcess() async throws
}

public protocol DependencyProducts: NamedDependency {
    var productNames: [String]? { get }

    func version(for productName: String) -> String
}

extension DependencyProcessor {
    public func existingArtifacts(dependencies onlyDependencies: [Input]? = nil) async throws -> [AnyArtifact] {
        let dependencies = onlyDependencies ?? self.dependencies

        return try await preProcess()
            .filter { resolved in dependencies.contains(where: { $0.name == resolved.name }) }
            .flatMap { dependency -> [AnyArtifact] in
                return (dependency
                    .productNames ?? [])
                    .compactMap { productName in
                        let path = Config.current.getCompressedFrameworkPath(
                            for: dependency,
                            productName: productName
                        )

                        guard path.exists else {
                            log.warning("Skipping \(path.lastComponent) because it doesn't exist.")
                            return nil
                        }

                        return AnyArtifact(Artifact(
                            name: productName,
                            parentName: dependency.name,
                            version: dependency.version(for: productName),
                            path: path
                        ))
                    }
            }
    }

    public func process(
        dependencies onlyDependencies: [Input]? = nil,
        accumulatedResolvedDependencies: [DependencyProducts]
    ) async throws -> ([AnyArtifact], [DependencyProducts]) {

        let dependencyProducts = try await preProcess()
        let conflictingDependencies: [String: [String]] = (dependencyProducts + accumulatedResolvedDependencies)
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

        var allArtifacts: [AnyArtifact] = []

        for dependencyProduct in dependencyProducts {
            let dependencies = onlyDependencies ?? self.dependencies
            let dependency = dependencies.first(where: { $0.name == dependencyProduct.name })

            if let onlyDependencies = onlyDependencies,
               !onlyDependencies.contains(where: { $0.name == dependencyProduct.name || dependencyProduct.productNames?.contains($0.name) == true }) {
                continue
            }

            guard let productNames = dependencyProduct.productNames else {
                allArtifacts.append(
                    contentsOf: try await process(dependency, resolvedTo: dependencyProduct)
                )
                continue
            }

            var missingProductNames: [String] = []

            for productName in productNames {
                if options.force {
                    missingProductNames.append(productName)
                }

                let exists = try await Config.current.cacheDelegator
                    .exists(product: productName, version: dependencyProduct.version(for: productName))

                if !exists {
                    missingProductNames.append(productName)
                }
            }

            if missingProductNames.isEmpty {
                for productName in productNames {
                    let path = Config.current.getFrameworkPath(for: dependencyProduct, productName: productName)

                    if path.exists, self.options.skipClean {
                        allArtifacts.append(AnyArtifact(Artifact(
                            name: productName,
                            parentName: dependencyProduct.name,
                            version: dependencyProduct.version(for: productName),
                            path: path
                        )))
                    } else {
                        let artifact = try await Config.current.cacheDelegator
                            .get(
                                product: productName,
                                in: dependencyProduct.name,
                                version: dependencyProduct.version(for: productName),
                                destination: path
                            )
                        allArtifacts.append(artifact)
                    }
                }
            } else {
                let artifacts = try await self.process(dependency, resolvedTo: dependencyProduct)
                allArtifacts.append(contentsOf: artifacts)
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

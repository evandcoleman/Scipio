//
//  PackageWorkspace.swift
//  
//
//  Created by Evan Coleman on 8/23/24.
//

import Basics
import Foundation
import PackageGraph
import PackageModel
import PackageLoading
import PathKit
import SourceControl
import TSCBasic
import Workspace

public final class PackageWorkspace {

    public let dependencies: [PackageDependency]
    public let rootPath: Path

    private let observabilityScope: ObservabilityScope
    private let repositoryManager: RepositoryManager
    private let workspace: Workspace
    private let graph: PackageGraph

    private let paths: Config.Paths

    public init(
        name: String,
        deploymentTarget: [Platform: String],
        dependencies: [PackageDependency],
        rootPath: Path
    ) throws {
        self.dependencies = dependencies
        self.rootPath = rootPath
        self.observabilityScope = log.observabilityScope("PackageWorkspace")
        self.paths = .init(rootPath: rootPath)

        let packageFile = PackageFile(
            name: name,
            deploymentTarget: deploymentTarget,
            dependencies: dependencies,
            rootPath: rootPath
        )

        try packageFile.write()

        let outputDir = try AbsolutePath(validating: rootPath.string)
        let toolchain = try UserToolchain(destination: try .hostDestination())
        let loader = ManifestLoader(toolchain: toolchain)
        self.workspace = try Workspace(forRootPackage: outputDir, customManifestLoader: loader)
        self.graph = try workspace.loadPackageGraph(rootPath: outputDir, observabilityScope: observabilityScope)

        let repositoryProvider = GitRepositoryProvider()
        self.repositoryManager = RepositoryManager(
            fileSystem: localFileSystem,
            path: outputDir,
            provider: repositoryProvider,
            cachePath: .none,
            initializationWarningHandler: { log.warning($0) },
            delegate: nil
        )
    }

    // MARK: Private

    private func observabilityScope(for package: PackageDependency) -> ObservabilityScope {
        return log.observabilityScope(package.name)
    }

    private func observabilityScope(description: String) -> ObservabilityScope {
        return log.observabilityScope(description)
    }

    private func writeProject(
        directory: Path
    ) throws -> Xcode.Project {
        let outputDir = try AbsolutePath(validating: directory.string)
        let projectAbsolutePath = XcodeProject.makePath(outputDir: outputDir, projectName: "Packages")
        let projectPath = Path(projectAbsolutePath.pathString)

        if projectPath.exists {
            try projectPath.delete()
        }
        try projectPath.mkpath()

        let project = try pbxproj (
            xcodeprojPath: projectAbsolutePath,
            graph: graph,
            extraDirs: [],
            extraFiles: [],
            options: XcodeprojOptions (
                xcconfigOverrides: nil,
                useLegacySchemeGenerator: true
            ),
            fileSystem: localFileSystem,
            observabilityScope: observabilityScope(description: "Xcodeproj")
        )

        if let deploymentTarget = Config.current.platformVersions[.iOS] {
            project.buildSettings.common.IPHONEOS_DEPLOYMENT_TARGET = deploymentTarget
        }
        if let deploymentTarget = Config.current.platformVersions[.macOS] {
            project.buildSettings.common.MACOSX_DEPLOYMENT_TARGET = deploymentTarget
        }

        project.buildSettings.common.SWIFT_ACTIVE_COMPILATION_CONDITIONS = nil
        project.buildSettings.release.SWIFT_ACTIVE_COMPILATION_CONDITIONS = nil

        try project.save(to: projectAbsolutePath)

        return project
    }

    private func managedDependency(for package: PackageIdentity) -> Workspace.ManagedDependency? {
        return workspace.state.dependencies
            .first { $0.packageRef.identity == package }
    }

    private func managedDependency(for packageName: String) -> Workspace.ManagedDependency? {
        return workspace.state.dependencies
            .first { $0.packageRef.identity.description == packageName }
    }

    // MARK: Public

    public var products: [PackageProduct] {
        let targets = graph
            .reachableTargets
            .filter { $0.type == .library && $0.name != Config.current.name }
            .compactMap { target -> PackageProduct? in
                guard
                    let package = graph.package(for: target)
                else { return nil }

                let version = versionIdentifier(for: package.identity)

                return PackageProduct(
                    target: target,
                    package: package,
                    version: version
                )
            }

        let binaries = graph
            .binaryArtifacts
            .flatMap { package, binaries -> [PackageProduct] in
                guard
                    let dependency = managedDependency(for: package)
                else { return [] }

                let version = versionIdentifier(for: package)

                return binaries
                    .map { name, binary in
                        return PackageProduct(
                            name: name,
                            packageUrl: dependency.packageRef.locationString,
                            binary: binary,
                            package: package,
                            version: version
                        )
                    }
            }

        return targets + binaries
    }

    public func versionIdentifier(for package: PackageIdentity) -> String? {
        guard
            let dependency = managedDependency(for: package)
        else { return nil }

        return dependency.state.versionIdentifier
    }

    public func versionIdentifier(for packageName: String) -> String? {
        guard
            let dependency = managedDependency(for: packageName)
        else { return nil }

        return dependency.state.versionIdentifier
    }

    @discardableResult
    public func writeXcodeProject() throws -> Xcode.Project {
        return try writeProject(directory: rootPath)
    }

    @discardableResult
    public func loadManifest() async throws -> Manifest {
        let packagePath = paths.rootPath
        let outputDir = try AbsolutePath(validating: packagePath.string)

        return try await withCheckedThrowingContinuation { continuation in
            workspace.loadRootManifest(
                at: outputDir,
                observabilityScope: observabilityScope,
                completion: { continuation.resume(with: $0) }
            )
        }
    }

    public func checkoutPackage(
        _ package: PackageDependency
    ) async throws {
        let checkoutPath = try paths.packageCheckout(packageName: package.name)
        let path = try AbsolutePath(validating: checkoutPath.string)
        let repository = RepositorySpecifier(url: .init(package.url))
        let fileSystem = localFileSystem

        // Remove any existing content at that path.
        try fileSystem.chmod(.userWritable, path: path, options: [.recursive, .onlyFiles])
        try fileSystem.removeFileTree(path)

        let handle = try await withCheckedThrowingContinuation { continuation in
            repositoryManager.lookup(
                package: .init(urlString: package.url.absoluteString),
                repository: repository,
                skipUpdate: true,
                observabilityScope: observabilityScope(description: package.name),
                delegateQueue: .sharedConcurrent,
                callbackQueue: .sharedConcurrent,
                completion: { result in
                    continuation.resume(with: result)
                }
            )
        }

        // Create the working copy.
        let workingCheckout = try handle.createWorkingCopy(at: path, editable: false)

        do {
            if let version = versionIdentifier(for: package.name) {
                try workingCheckout.checkout(revision: .init(identifier: version))
            } else {
                observabilityScope(description: package.name).emit(error: "Missing version")
            }
        } catch let error as GitRepositoryError {
            observabilityScope(description: package.name).emit(error: error.message)
        } catch {
            observabilityScope(description: package.name).emit(error: error.localizedDescription)
        }
    }
}

private extension Workspace.ManagedDependency.State {

    var versionIdentifier: String? {
        switch self {
        case .sourceControlCheckout(let checkoutState):
            switch checkoutState {
            case .branch(_, let revision):
                return revision.identifier
            case .revision(let revision):
                return revision.identifier
            case .version(_, let revision):
                return revision.identifier
            }
        default:
            return nil
        }
    }
}

// MARK: PackageFile

extension PackageWorkspace {

    public struct PackageFile {

        public var name: String
        public var deploymentTarget: [Platform: String]
        public var dependencies: [PackageDependency]
        public var rootPath: Path

        public init(
            name: String,
            deploymentTarget: [Platform: String],
            dependencies: [PackageDependency],
            rootPath: Path
        ) {
            self.name = name
            self.deploymentTarget = deploymentTarget
            self.dependencies = dependencies
            self.rootPath = rootPath
        }

        public func write() throws {
            let packagesPath = rootPath + "Package.swift"

            let sourcesPath = rootPath + "Sources" + name
            if !sourcesPath.exists {
                try sourcesPath.mkpath()
            }
            let sourceFilePath = sourcesPath + "\(name).swift"
            if !sourceFilePath.exists {
                try sourceFilePath.write("", encoding: .utf8)
            }

            var packageFile = try SwiftPackageFile(
                name: name,
                path: packagesPath,
                platforms: deploymentTarget.reduce(into: [:]) { result, target in
                    switch target.key {
                    case .iOS:
                        result[.iOS] = target.value
                    case .macOS:
                        result[.macOS] = target.value
                    }
                },
                removeMissing: false
            )
            packageFile.targets = [
                .init(
                    name: name,
                    dependencies: dependencies
                        .flatMap { dependency -> [SwiftPackageFile.Target.Dependency] in
                            if let productNames = dependency.products {
                                return productNames
                                    .map { name in
                                        return .init(
                                            name: name,
                                            package: PackageIdentity(urlString: dependency.url.absoluteString).description
                                        )
                                    }
                            } else {
                                return [
                                    .init(
                                        name: dependency.name,
                                        package: PackageIdentity(urlString: dependency.url.absoluteString).description
                                    )
                                ]
                            }
                        }
                )
            ]
            packageFile.dependencies = dependencies
                .map { dependency in
                    return .remoteSourceControl(
                        identity: .init(urlString: dependency.url.absoluteString),
                        nameForTargetDependencyResolutionOnly: nil,
                        url: .init(dependency.url.absoluteString),
                        requirement: dependency.packageVersionRequirement,
                        productFilter: .nothing
                    )
                }
            packageFile.products = []

            try packageFile.write(relativeTo: rootPath)
        }
    }
}

import Combine
import Foundation
import PathKit
import Regex
import Zip

import Basics
import PackageGraph
import PackageLoading
import PackageModel
import SourceControl
import TSCBasic
import Workspace

public final class PackageProcessor: DependencyProcessor {

    public let dependencies: [PackageDependency]
    public let options: ProcessorOptions

    private var derivedDataPath: Path {
        return Config.current.buildPath + "DerivedData"
    }

    private var sourcePackagesPath: Path {
        return Config.current.buildPath + "SourcePackages"
    }

    private let urlSession: URLSession = .createWithExtensionsSupport()
    private let observabilityScope: ObservabilityScope

    private var repositoryManager: RepositoryManager?

    public init(
        dependencies: [PackageDependency],
        options: ProcessorOptions,
        observabilityScope: ObservabilityScope
    ) {
        self.dependencies = dependencies
        self.options = options
        self.observabilityScope = observabilityScope.makeChildScope(description: "Package Processor")
    }

    private func observabilityScope(for package: PackageDependency) -> ObservabilityScope {
        return observabilityScope(description: package.name)
    }

    //    private func observabilityScope(for package: SwiftPackageDescriptor) -> ObservabilityScope {
    //        return observabilityScope(description: package.name)
    //    }

    private func observabilityScope(description: String) -> ObservabilityScope {
        return observabilityScope
            .makeChildScope(description: description)
    }

    private func getRepositoryManager() throws -> RepositoryManager {
        let packagePath = try Config.current.getPackagesPath()
        let outputDir = try AbsolutePath(validating: packagePath.string)
        let repositoryProvider = GitRepositoryProvider()

        let repositoryManager = RepositoryManager(
            fileSystem: localFileSystem,
            path: outputDir,
            provider: repositoryProvider,
            cachePath: .none,
            initializationWarningHandler: { log.warning($0) },
            delegate: nil
        )

        self.repositoryManager = repositoryManager

        return repositoryManager
    }

    public func preProcess() async throws -> [PackageProduct] {
        try writeSwiftPackageFile()

        let packagePath = try Config.current.getPackagesPath()
        let outputDir = try AbsolutePath(validating: packagePath.string)
        let toolchain = try UserToolchain(destination: try .hostDestination())
        let loader = ManifestLoader(toolchain: toolchain)
        let workspace = try Workspace(forRootPackage: outputDir, customManifestLoader: loader)
        let graph = try workspace.loadPackageGraph(rootPath: outputDir, observabilityScope: observabilityScope)
        _ = try tsc_await {
            workspace.loadRootManifest(
                at: outputDir,
                observabilityScope: observabilityScope,
                completion: $0
            )
        }

        _ = try writeProject(
            graph: graph,
            directory: packagePath
        )

        if !derivedDataPath.exists {
            try derivedDataPath.mkpath()
        }

        let targets = graph
            .reachableTargets
            .filter { $0.type == .library && $0.name != Config.current.name }
            .compactMap { target -> PackageProduct? in
                guard 
                    let package = graph.package(for: target),
                    let dependency = workspace.state.dependencies.first(where: { $0.packageRef.identity == package.identity })
                else { return nil }

                let version: String? = {
                    switch dependency.state {
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
                }()

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
                    let dependency = workspace.state.dependencies.first(where: { $0.packageRef.identity == package })
                else { return [] }

                let version: String? = {
                    switch dependency.state {
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
                }()

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

    public func process(
        dependencies: [PackageDependency],
        product: PackageProduct
    ) async throws -> [any LocalArtifact] {

        let path = try Config.current.getPackagesPath()

        let excludedProducts = dependencies
            .flatMap { $0.excludes ?? [] }

        if excludedProducts.contains(where: { $0 == product.productName }) {
            return []
        }

        try await checkoutPackage(product: product, rootPath: path)

        var xcFrameworks: [any LocalArtifact] = []

        switch product.buildable {
        case .binary(let binary):
            let artifact = try processBinaryTarget(
                product: product,
                binary: binary,
                sourcePath: path
            )

            xcFrameworks.append(artifact)
        case .target(let target):
            xcFrameworks.append(
                contentsOf: try buildAndExport(
                    product: product,
                    target: target,
                    dependencies: dependencies,
                    path: path
                )
            )
        }

        return xcFrameworks
    }

    public func postProcess() async throws {}

    private func checkoutPackage(
        product: PackageProduct,
        rootPath: Path
    ) async throws {
        let repositoryManager = try getRepositoryManager()

        let checkoutPath = try Config.current.getPackageCheckoutPath(packageName: product.packageName)
        let path = try AbsolutePath(validating: checkoutPath.string)
        let repository = RepositorySpecifier(url: .init(product.packageUrl))
        let fileSystem = localFileSystem

        // Remove any existing content at that path.
        try fileSystem.chmod(.userWritable, path: path, options: [.recursive, .onlyFiles])
        try fileSystem.removeFileTree(path)

        let handle = try await withCheckedThrowingContinuation { continuation in
            repositoryManager.lookup(
                package: .init(urlString: product.packageUrl),
                repository: repository,
                skipUpdate: true,
                observabilityScope: observabilityScope(description: product.packageName),
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
            try workingCheckout.checkout(revision: .init(identifier: product.version))
        } catch let error as GitRepositoryError {
            observabilityScope(description: product.packageName).emit(error: error.message)
        } catch {
            observabilityScope(description: product.packageName).emit(error: error.localizedDescription)
        }
    }

    private func processBinaryTarget(
        product: PackageProduct,
        binary: BinaryArtifact,
        sourcePath: Path
    ) throws -> Artifact {
        let targetPath = try Config.current.getFrameworkPath(
            productName: product.productName
        )
        let artifact = Artifact(
            name: product.productName,
            parentNames: product.parentNames,
            version: product.version,
            path: targetPath
        )

        if self.options.skipClean, targetPath.exists {
            return artifact
        }

        let fullPath = sourcePath + Path(binary.path.pathString)

        if targetPath.exists {
            try targetPath.delete()
        }

        if !targetPath.parent().exists {
            try targetPath.parent().mkpath()
        }

        try fullPath.copy(targetPath)

        return artifact
    }

    private func writeProject(
        graph: PackageGraph,
        directory: Path
    ) throws -> Path {
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

        return projectPath
    }

    private func writeSwiftPackageFile() throws {
        let packageRoot = try Config.current.getPackagesPath()
        let packagesPath = packageRoot + "Package.swift"

        let sourcesPath = packageRoot + "Sources" + Config.current.name
        if !sourcesPath.exists {
            try sourcesPath.mkpath()
        }
        let sourceFilePath = sourcesPath + "\(Config.current.name).swift"
        if !sourceFilePath.exists {
            try sourceFilePath.write("", encoding: .utf8)
        }

        var packageFile = try SwiftPackageFile(
            name: Config.current.name,
            path: packagesPath,
            platforms: Config.current.deploymentTarget.reduce(into: [:]) { result, target in
                switch target.key {
                case "iOS":
                    result[.iOS] = target.value
                case "macOS":
                    result[.macOS] = target.value
                default:
                    break
                }
            },
            removeMissing: false,
            observabilityScope: observabilityScope(description: "writeSwiftPackageFile")
        )
        packageFile.targets = [
            .init(
                name: Config.current.name,
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
        try packageFile.write(relativeTo: Config.current.getPackagesPath())
    }

    private func buildAndExport(
        product: PackageProduct,
        target: ResolvedTarget,
        dependencies: [PackageDependency],
        path: Path
    ) throws -> [Artifact] {
        let useLibraryEvolution = dependencies
            .contains { $0.useLibraryEvolution != false }

        let archivePaths = try options.platforms.sdks.map { sdk -> Path in

            let archivePath = try XcodeBuilder.getArchivePath(
                scheme: target.name,
                sdk: sdk
            )

            if options.skipClean, archivePath.exists {
                return archivePath
            } else if archivePath.exists {
                try archivePath.delete()
            }

            var additionalBuildSettings = dependencies
                .compactMap(\.additionalBuildSettings)
                .reduce(
                    into: [:]
                ) { $0.merge($1, uniquingKeysWith: { _, new in new }) }

            additionalBuildSettings["BUILD_LIBRARY_FOR_DISTRIBUTION"] = useLibraryEvolution ? "YES" : "NO"

            do {
                let archivePath = try XcodeBuilder.archive(
                    scheme: target.name,
                    in: path,
                    for: sdk,
                    derivedDataPath: derivedDataPath,
                    additionalBuildSettings: additionalBuildSettings
                )

                try copyModulesAndHeaders(
                    product: product,
                    target: target,
                    sdk: sdk,
                    archivePath: archivePath,
                    derivedDataPath: derivedDataPath,
                    sourcePath: path
                )

                return archivePath
            } catch {
                log.error("Failed to build \(product.productName), scheme=\(target.name), sdk=\(sdk.rawValue)")
                throw error
            }
        }

        let artifacts = try XcodeBuilder.createXCFramework(
            archivePaths: archivePaths,
            skipIfExists: options.skipClean,
            useLibraryEvolution: useLibraryEvolution
        ).map { path in
            return Artifact(
                name: path.lastComponentWithoutExtension,
                parentNames: product.parentNames,
                version: product.version,
                path: path
            )
        }

        return artifacts
    }

    private func copyModulesAndHeaders(
        product: PackageProduct,
        target: ResolvedTarget,
        sdk: Xcodebuild.SDK,
        archivePath: Path,
        derivedDataPath: Path,
        sourcePath: Path
    ) throws {
        // https://forums.swift.org/t/how-to-build-swift-package-as-xcframework/41414/4
        let frameworksPath = archivePath + "Products/Library/Frameworks"
        let frameworks = frameworksPath.glob("*.framework")

        if frameworks.isEmpty {
            throw ScipioError.missingFrameworks(package: product.productName)
        }

        for frameworkPath in frameworks {
            let frameworkName = frameworkPath.lastComponentWithoutExtension
            let modulesPath = frameworkPath + "Modules"
            let headersPath = frameworkPath + "Headers"

            if !modulesPath.exists {
                try modulesPath.mkdir()
            }

            let archiveIntermediatesPath = derivedDataPath + "Build/Intermediates.noindex/ArchiveIntermediates/\(frameworkName)"
            let buildProductsPath = archiveIntermediatesPath + "BuildProductsPath"
            let releasePath = buildProductsPath + "Release-\(sdk.rawValue)"
            let swiftModulePath = releasePath + "\(frameworkName).swiftmodule"
            let resourcesBundlePath = releasePath + "\(frameworkName)_\(frameworkName).bundle"

            if swiftModulePath.exists {
                // Swift projects
                try swiftModulePath.copy(modulesPath + "\(frameworkName).swiftmodule")
            }

            let hasHeaderSearchPath = target
                .underlyingTarget
                .buildSettings
                .assignments
                .contains { setting, _ in
                    switch setting {
                    case .HEADER_SEARCH_PATHS:
                        return true
                    default:
                        return false
                    }
                }

            if !swiftModulePath.exists || hasHeaderSearchPath {
                // Objective-C projects
                let moduleMapDirectory = archiveIntermediatesPath + "IntermediateBuildFilesPath/\(product.productName).build/Release-\(sdk.rawValue)/\(frameworkName).build"
                var moduleMapPath = moduleMapDirectory.glob("*.modulemap").first
                var moduleMapContent = "module \(frameworkName) { export * }"
                var includeDirectory: Path? = nil

                // If we can't find the generated modulemap, we check
                // to see if the package includes its own.
                if
                    (moduleMapPath == nil || moduleMapPath?.exists == false),
                    product.isBinary
                {
                    let path = target.underlyingTarget.path.pathString
                    moduleMapPath = try (sourcePath + Path(path))
                        .normalize()
                        .recursiveChildren()
                        .filter { $0.extension == "modulemap" }
                        .first

                    if let moduleMapPath = moduleMapPath, moduleMapPath.parent().lastComponent == "include" {
                        includeDirectory = moduleMapPath.parent()
                    }
                }

                if let moduleMapPath = moduleMapPath, moduleMapPath.exists {
                    let umbrellaHeaderRegex = Regex(#"umbrella (?:header )?"(.*)""#)
                    let umbrellaHeaderMatch = umbrellaHeaderRegex.firstMatch(in: try moduleMapPath.read())

                    if let match = umbrellaHeaderMatch, !match.captures.isEmpty,
                       let umbrellaHeaderPathString = match.captures[0] {

                        var umbrellaHeaderPath = Path(umbrellaHeaderPathString)
                        if umbrellaHeaderPath.isRelative {
                            umbrellaHeaderPath = (moduleMapPath.parent() + umbrellaHeaderPath).normalize()
                        }
                        var sourceHeadersDirectory = umbrellaHeaderPath.isFile ? umbrellaHeaderPath.parent() : umbrellaHeaderPath + frameworkName

                        if umbrellaHeaderPath.isDirectory, !sourceHeadersDirectory.exists {
                            sourceHeadersDirectory = umbrellaHeaderPath
                        }

                        if !headersPath.exists {
                            try headersPath.mkdir()
                        }

                        // If the modulemap declares an umbrella header instead of an
                        // umbrella directory, we make sure the umbrella header references
                        // its headers using <Framework/Header.h> syntax.
                        // And then we recusively look through the header files for
                        // imports to gather a list of files to include.
                        if umbrellaHeaderPath.isFile, includeDirectory == nil {
                            let headerContent = try umbrellaHeaderPath
                                .read()
                                .replacingFirst(matching: Regex(#"^#import "(.*).h""#, options: [.anchorsMatchLines]), with: "#import <\(frameworkName)/$1.h>")
                            let path = headersPath + umbrellaHeaderPath.lastComponent
                            try path.write(headerContent)
                        } else if includeDirectory == nil {
                            umbrellaHeaderPath = headersPath + "\(frameworkName).h"
                            let umbrellaHeaderContent = sourceHeadersDirectory
                                .glob("*.h")
                                .map { "#import <\(frameworkName)/\($0.lastComponent)>" }
                                .joined(separator: "\n")
                            try umbrellaHeaderPath.write(umbrellaHeaderContent)
                        }

                        let allHeaderPaths: [Path]

                        if let includeDirectory = includeDirectory {
                            allHeaderPaths = try (includeDirectory + frameworkName)
                                .recursiveChildren()
                                .filter { $0.extension == "h" }
                        } else {
                            allHeaderPaths = try getHeaders(in: umbrellaHeaderPath, frameworkName: frameworkName, sourceHeadersDirectory: sourceHeadersDirectory)
                        }

                        if !headersPath.exists, !allHeaderPaths.isEmpty {
                            try headersPath.mkdir()
                        }

                        for headerPath in allHeaderPaths {
                            let targetPath = headersPath + headerPath.lastComponent

                            if !targetPath.exists, headerPath.exists {
                                if headerPath.isSymlink {
                                    try headerPath.symlinkDestination().copy(targetPath)
                                } else {
                                    try headerPath.copy(targetPath)
                                }
                            }
                        }

                        moduleMapContent = """
                            framework module \(frameworkName) {
                                umbrella header "\(umbrellaHeaderPath.lastComponent)"

                                export *
                                module * { export * }
                            }
                            """
                    }
                } else {
                    //                    let dependencies = target
                    //                        .dependencies
                    //                        .map { dependency in
                    //                            switch dependency {
                    //                            case .target(let target, _):
                    //                                return target.productName
                    //                            case .product(let product, _):
                    //                                return product.name
                    //                            }
                    //                        }
                    //                    let headerPaths: [Path] = allTargets
                    //                        .compactMap { target in
                    //                            guard let publicHeadersPath = target.publicHeadersPath else { return nil }
                    //
                    //                            if let path = target.path {
                    //                                return Path(path) + Path(publicHeadersPath)
                    //                            } else {
                    //                                return Path(publicHeadersPath)
                    //                            }
                    //                        }
                    //                    let headers = try headerPaths
                    //                        .flatMap { headerPath -> [Path] in
                    //                            guard headerPath.exists else { return [] }
                    //
                    //                            return try (package.path + headerPath)
                    //                                .recursiveChildren()
                    //                                .filter { $0.extension == "h" }
                    //                        }
                    //
                    //                    if !headersPath.exists, !headers.isEmpty {
                    //                        try headersPath.mkdir()
                    //                    }
                    //
                    //                    for headerPath in headers {
                    //                        let targetPath = headersPath + headerPath.lastComponent
                    //
                    //                        if !targetPath.exists, headerPath.exists {
                    //                            try headerPath.copy(targetPath)
                    //                        }
                    //                    }
                    //
                    //                    moduleMapContent = """
                    //                        framework module \(frameworkName) {
                    //                        \(headers.map { "    header \"\($0.lastComponent)\"" }.joined(separator: "\n"))
                    //
                    //                            export *
                    //                        }
                    //                        """
                }
                //
                //                try (modulesPath + "module.modulemap").write(moduleMapContent)
            }

            if resourcesBundlePath.exists {
                try resourcesBundlePath.copy(frameworkPath)
            }
        }
    }

    private func getHeaders(in header: Path, frameworkName: String, sourceHeadersDirectory: Path, allHeaders: [Path] = []) throws -> [Path] {
        guard header.exists else { return [] }

        let localHeaderRegex = Regex(#"^#import "(.*)\.h""#, options: [.anchorsMatchLines])
        let frameworkHeaderRegex = try Regex(string: #"^#import <\#(frameworkName)/(.*)\.h>"#, options: [.anchorsMatchLines])

        let contents: String = try header.read()
        let headerMatches = localHeaderRegex.allMatches(in: contents)
        + frameworkHeaderRegex.allMatches(in: contents)

        guard !headerMatches.isEmpty else { return [header] }

        let headerPaths = headerMatches
            .map { sourceHeadersDirectory + "\($0.captures[0] ?? "").h" }
            .filter { !allHeaders.contains($0) && $0 != header }
            .uniqued()
        var accumulated = allHeaders + [header]

        for headerPath in headerPaths where !accumulated.contains(headerPath) {
            accumulated.append(contentsOf: try getHeaders(in: headerPath, frameworkName: frameworkName, sourceHeadersDirectory: sourceHeadersDirectory, allHeaders: accumulated))
        }

        return accumulated.uniqued()
    }
}

// MARK: PackageProduct

extension PackageProcessor {

    public struct PackageProduct: Product {

        public var productName: String
        public var version: String
        public var parentNames: [String]
        public var packageName: String
        public var packageUrl: String

        public var buildable: Buildable

        public var isBinary: Bool {
            switch buildable {
            case .binary:
                return true
            default:
                return false
            }
        }
    }
}

extension PackageProcessor.PackageProduct {

    public enum Buildable: Equatable, Hashable {
        case target(ResolvedTarget)
        case binary(BinaryArtifact)

        public static func == (lhs: Buildable, rhs: Buildable) -> Bool {
            switch (lhs, rhs) {
            case (.target(let lhs), .target(let rhs)):
                return lhs == rhs
            case (.binary(let lhs), .binary(let rhs)):
                return lhs.kind == rhs.kind
                && lhs.originURL == rhs.originURL
                && lhs.path == rhs.path
            default:
                return false
            }
        }

        public func hash(into hasher: inout Hasher) {
            switch self {
            case .target(let target):
                hasher.combine(target)
            case .binary(let binary):
                hasher.combine(binary.kind)
                hasher.combine(binary.originURL)
                hasher.combine(binary.path)
            }
        }
    }

    init(
        target: ResolvedTarget,
        package: ResolvedPackage,
        version: String?
    ) {
        self.productName = target.name
        self.version = version ?? package.manifest.version?.description ?? "unknown"
        self.parentNames = [package.manifest.displayName]
        self.packageName = package.identity.description
        self.packageUrl = package.manifest.packageLocation
        self.buildable = .target(target)
    }
    
        init(
            name: String,
            packageUrl: String,
            binary: BinaryArtifact,
            package: PackageIdentity,
            version: String?
        ) {
            self.productName = name
            self.version = version ?? "unknown"
            self.parentNames = [package.description]
            self.packageName = package.description
            self.packageUrl = packageUrl
            self.buildable = .binary(binary)
        }
}

// MARK: - WorkspaceState

private struct WorkspaceState: Decodable {
    let object: Object
}

extension WorkspaceState {
    struct Object: Codable {
        let artifacts: [Artifact]
        let dependencies: [Dependency]

        struct Dependency: Codable {
            let packageRef: PackageRef
            let state: State
            let subpath: String

            struct State: Codable {
                let checkoutState: CheckoutState
                let name: String?

                struct CheckoutState: Codable {
                    let branch: String?
                    let revision: String
                    let version: String?
                }
            }
        }

        struct PackageRef: Codable {
            let identity: String
            let kind: String?
            let name: String
            let path: String?
        }

        struct Artifact: Codable {
            let packageRef: PackageRef
            let source: Source
            let targetName: String

            struct Source: Codable {
                let path: String?
                let type: String?
                let checksum, subpath: String?
                let url: String?
            }
        }
    }
}

struct SchemesList: Decodable {
    let project: Project

    struct Project: Decodable {
        let schemes: [String]
    }
}

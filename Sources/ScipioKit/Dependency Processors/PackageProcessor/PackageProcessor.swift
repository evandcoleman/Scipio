import Foundation
import PathKit
import Regex
import XcodeProj
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
    private var workspace: PackageWorkspace!

    public init(
        dependencies: [PackageDependency],
        options: ProcessorOptions
    ) {
        self.dependencies = dependencies
        self.options = options
    }

    public func preProcess() async throws -> [PackageProduct] {
        let packagePath = try Config.paths.packagesRoot()

        self.workspace = try PackageWorkspace(
            name: Config.current.name,
            deploymentTarget: Config.current.platformVersions,
            dependencies: dependencies,
            rootPath: packagePath
        )

        try await workspace.loadManifest()
        try workspace.writeXcodeProject()

        if !derivedDataPath.exists {
            try derivedDataPath.mkpath()
        }

        return workspace.products
    }

    public func process(
        dependencies: [PackageDependency],
        product: PackageProduct
    ) async throws -> [any LocalArtifact] {

        let path = try Config.paths.packagesRoot()

        let excludedProducts = dependencies
            .flatMap { $0.excludes ?? [] }

        if excludedProducts.contains(where: { $0 == product.productName }) {
            return []
        }

        for dependency in dependencies {
            try await workspace.checkoutPackage(dependency)
        }

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

    private func processBinaryTarget(
        product: PackageProduct,
        binary: BinaryArtifact,
        sourcePath: Path
    ) throws -> Artifact {
        let targetPath = try Config.paths.framework(
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

// MARK: - SchemesList

struct SchemesList: Decodable {
    let project: Project

    struct Project: Decodable {
        let schemes: [String]
    }
}

// MARK: - Read Dependencies

extension PackageProcessor {

    public static func readDependencies(from path: Path, project: XcodeProj?) async throws -> [Input] {
        guard let project else { return [] }

        let packageProducts = project
            .pbxproj
            .nativeTargets
            .flatMap { $0.packageProductDependencies ?? [] }
            .reduce(into: [String: Set<String>]()) { acc, value in
                guard let package = value.package?.name else { return }

                acc[package, default: []].insert(value.productName)
            }
        let packages = try project
            .pbxproj
            .rootObject?
            .remotePackages
            .compactMap { package in
                if
                    let name = package.name,
                    let productNames = packageProducts[name]
                {
                    let availableProducts = try getPackageProducts(package: package)

                    if availableProducts != productNames {
                        return makePackage(
                            package: package,
                            products: Array(productNames).sorted()
                        )
                    }
                }

                return makePackage(package: package)
            }

        return packages ?? []
    }

    private static func makePackage(
        package: XCRemoteSwiftPackageReference,
        products: [String]? = nil
    ) -> PackageDependency? {
        guard
            let versionRequirement = package.versionRequirement,
            let urlString = package.repositoryURL,
            let url = URL(string: urlString)
        else { return nil }

        return PackageDependency(
            name: package.name ?? url.lastPathComponent,
            url: url,
            versionRequirement: versionRequirement,
            products: products
        )
    }

    private static func getPackageProducts(
        package: XCRemoteSwiftPackageReference
    ) throws -> Set<String> {
        guard let dependency = makePackage(package: package) else { return [] }

        let path = try Path.uniqueTemporary()
        let workspace = try PackageWorkspace(
            name: dependency.name,
            deploymentTarget: [
                .iOS: "16.0",
            ],
            dependencies: [dependency],
            rootPath: path
        )

        return Set(workspace.products.map(\.productName))
    }
}

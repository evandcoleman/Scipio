import Combine
import Foundation
import PathKit
import Regex
import Zip

import Basics
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

    public init(
        dependencies: [PackageDependency],
        options: ProcessorOptions,
        observabilityScope: ObservabilityScope
    ) {
        self.dependencies = dependencies
        self.options = options
        self.observabilityScope = observabilityScope
    }

    private func observabilityScope(for package: PackageDependency) -> ObservabilityScope {
        return observabilityScope(description: package.name)
    }

    private func observabilityScope(for package: SwiftPackageDescriptor) -> ObservabilityScope {
        return observabilityScope(description: package.name)
    }

    private func observabilityScope(description: String) -> ObservabilityScope {
        return observabilityScope
            .makeChildScope(description: description)
    }

    public func preProcess() async throws -> [SwiftPackageDescriptor] {
//        let projectPath = try writeProject()

        if !derivedDataPath.exists {
            try derivedDataPath.mkpath()
        }

        

//        try resolvePackageDependencies(in: projectPath, sourcePackagesPath: sourcePackagesPath)

//        return try readPackages(sourcePackagesPath: sourcePackagesPath)

        let fileSystem = localFileSystem
        let packagesPath = Config.current.getPackageRepositoriesPath()
        let path = try AbsolutePath(validating: packagesPath.string)
        let repositoryProvider = GitRepositoryProvider()
        let repositoryManager = RepositoryManager(
            fileSystem: fileSystem,
            path: path,
            provider: repositoryProvider,
            cachePath: .none,
            initializationWarningHandler: { log.warning($0) },
            delegate: nil
        )

        var packages: [SwiftPackageDescriptor] = []
//        let root = try AbsolutePath(validating: packagesPath.string)

        for dependency in dependencies {
            let checkoutPath = packagesPath + dependency.name
            let path = try AbsolutePath(validating: checkoutPath.string)
            let repository = RepositorySpecifier(url: .init(dependency.url.absoluteString))

            if checkoutPath.exists {
                let workingCopy = try repositoryManager.openWorkingCopy(at: path)

                try fileSystem.chmod(.userWritable, path: path, options: [.recursive, .onlyFiles])
                try workingCopy.fetch()
                try? fileSystem.chmod(.userUnWritable, path: path, options: [.recursive, .onlyFiles])
            }

            let handle = try await withCheckedThrowingContinuation { continuation in
                repositoryManager.lookup(
                    package: .init(urlString: dependency.url.absoluteString),
                    repository: repository,
                    skipUpdate: true,
                    observabilityScope: observabilityScope(for: dependency),
                    delegateQueue: .sharedConcurrent,
                    callbackQueue: .sharedConcurrent,
                    completion: { result in
                        continuation.resume(with: result)
                    }
                )
            }

            // Remove any existing content at that path.
            try fileSystem.chmod(.userWritable, path: path, options: [.recursive, .onlyFiles])
            try fileSystem.removeFileTree(path)

            // Create the working copy.
            let workingCheckout = try handle.createWorkingCopy(at: path, editable: false)

            do {
                try workingCheckout.checkout(revision: .init(identifier: dependency.resolvedRevision))
            } catch let error as GitRepositoryError {
                observabilityScope(for: dependency).emit(error: error.message)
            } catch {
                observabilityScope(for: dependency).emit(error: error.localizedDescription)
            }

            packages.append(try SwiftPackageDescriptor(
                path: checkoutPath,
                name: dependency.name,
                version: dependency.resolvedRevision,
                observabilityScope: observabilityScope(for: dependency)
            ))
        }

        return packages
    }

    public func process(
        _ dependency: PackageDependency?,
        resolvedTo resolvedDependency: SwiftPackageDescriptor
    ) async throws -> [AnyArtifact] {

        let path = try getWorkingPath(for: resolvedDependency)
        try preBuild(dependency: resolvedDependency, path: path)
        let projectPath = try writeProject(dependency: resolvedDependency, path: path)
        var buildables = try getBuildables(dependency: resolvedDependency, path: path)

        if let excludes = dependency?.excludes {
            buildables = buildables.filter { buildable in !excludes.contains(buildable.name) }
        }

        var xcFrameworks: [AnyArtifact] = []
        var downloads: [() -> Task<AnyArtifact, Error>] = []

        for product in buildables {
            if case .binaryTarget(let target) = product {
                let (artifact, downloadTask) = try processBinaryTarget(
                    buildable: product,
                    target: target,
                    dependency: resolvedDependency
                )

                if let downloadTask {
                    downloads.append(downloadTask)
                } else {
                    xcFrameworks.append(AnyArtifact(artifact))
                }
            } else {
                xcFrameworks.append(
                    contentsOf: try buildAndExport(
                        buildable: product,
                        package: resolvedDependency,
                        dependency: dependency,
                        path: projectPath.parent()
                    ).map(AnyArtifact.init)
                )
            }
        }

        for downloadTask in downloads {
            xcFrameworks.append(try await downloadTask().value)
        }

        return xcFrameworks
    }

    public func postProcess() async throws {}

    private func getBuildables(dependency: SwiftPackageDescriptor, path: Path) throws -> [SwiftPackageBuildable] {
        var buildables = dependency.buildables

        let availableSchemes = try path.chdir {
            let cmd = try xcrun("xcodebuild", "-list", "-json")
            let output = try cmd.output()
            let decoder = JSONDecoder()
            return try decoder.decode(SchemesList.self, from: output)
                .project
                .schemes
        }
        if buildables.count == 1, case .target(let target, _) = buildables.first,
           !availableSchemes.contains(target), let scheme = availableSchemes.first {

            buildables = [.target(target, buildName: scheme)]
        }

        return buildables
    }

    private func processBinaryTarget(
        buildable: SwiftPackageBuildable,
        target: TargetDescription,
        dependency: SwiftPackageDescriptor
    ) throws -> (Artifact, (() -> Task<AnyArtifact, Error>)?) {
        let targetPath = Config.current.getFrameworkPath(for: dependency, productName: target.name)
        let artifact = Artifact(
            name: buildable.name,
            parentName: dependency.name,
            version: dependency.version,
            path: targetPath
        )

        if self.options.skipClean, targetPath.exists {
            return (artifact, nil)
        }

        if 
            let urlString = target.url,
            let url = URL(string: urlString),
            let checksum = target.checksum
        {
            let downloadTask = {
                Task.detached {
                    let downloadPath: Path = try await withCheckedThrowingContinuation { continuation in
                        let task = self.urlSession
                            .downloadTask(with: url, progressHandler: { log.progress(percent: $0) }) { url, response, error in
                                if let error = error {
                                    continuation.resume(throwing: error)
                                } else if let url = url {
                                    continuation.resume(returning: Path(url.path))
                                } else {
                                    log.fatal("Unexpected download result")
                                }
                            }

                        log.info("Downloading \(url.lastPathComponent):")

                        task.resume()
                    }

                    let zipPath = Config.current.getCompressedFrameworkPath(for: dependency, productName: url.lastPathComponent.components(separatedBy: ".").dropLast().joined(separator: "."))

                    if zipPath.exists {
                        try zipPath.delete()
                    }

                    try downloadPath.copy(zipPath)

                    guard try zipPath.checksum(.sha256) == checksum else {
                        throw ScipioError.checksumMismatch(product: buildable.name)
                    }

                    if targetPath.exists {
                        try targetPath.delete()
                    }

                    log.info("Decompressing \(zipPath.lastComponent):")

                    var unzippedPath: Path? = nil
                    try Zip.unzipFile(
                        zipPath.url,
                        destination: targetPath.parent().url,
                        overwrite: true,
                        password: nil,
                        progress: { log.progress(percent: $0) },
                        fileOutputHandler: { unzippedFile in
                            if unzippedPath == nil {
                                if unzippedFile.pathExtension == "xcframework" {
                                    unzippedPath = Path(unzippedFile.path)
                                } else if
                                    let children = try? Path(unzippedFile.path()).children(),
                                    let frameworkChild = children.first(where: { $0.extension == "xcframework" })
                                {
                                    unzippedPath = frameworkChild
                                }
                            }
                        }
                    )

                    if let unzippedPath, unzippedPath != targetPath {
                        try unzippedPath.move(targetPath)
                    }

                    if unzippedPath == nil {
                        log.error("Couldn't find xcframework in archive: \(zipPath)")
                    }

                    return AnyArtifact(artifact)
                }
            }

            return (artifact, downloadTask)
        } else if let targetPath = target.path {
            let fullPath = dependency.path + Path(targetPath)
            let targetPath = Config.current.getFrameworkPath(for: dependency, productName: buildable.name)

            if targetPath.exists {
                try targetPath.delete()
            }

            if !targetPath.parent().exists {
                try targetPath.parent().mkpath()
            }

            try fullPath.copy(targetPath)

            return (artifact, nil)
        } else {
            fatalError("unexpected binary target")
        }
    }

    private func writeProject(dependency: SwiftPackageDescriptor, path: Path) throws -> Path {
        let outputDir = try AbsolutePath(validating: path.string)
        let projectAbsolutePath = XcodeProject.makePath(outputDir: outputDir, projectName: dependency.name)
        let projectPath = Path(projectAbsolutePath.pathString)

        if projectPath.exists {
            try projectPath.delete()
        }
        try projectPath.mkpath()

        let project = try pbxproj (
            xcodeprojPath: projectAbsolutePath,
            graph: dependency.graph,
            extraDirs: [],
            extraFiles: [],
            options: XcodeprojOptions (
                xcconfigOverrides: nil,
                useLegacySchemeGenerator: true
            ),
            fileSystem: localFileSystem,
            observabilityScope: observabilityScope(for: dependency)
        )

        if let deploymentTarget = Config.current.deploymentTarget["iOS"] {
            project.buildSettings.common.IPHONEOS_DEPLOYMENT_TARGET = deploymentTarget
        }
        if let deploymentTarget = Config.current.deploymentTarget["tvOS"] {
            project.buildSettings.common.TVOS_DEPLOYMENT_TARGET = deploymentTarget
        }
        if let deploymentTarget = Config.current.deploymentTarget["watchOS"] {
            project.buildSettings.common.WATCHOS_DEPLOYMENT_TARGET = deploymentTarget
        }
        if let deploymentTarget = Config.current.deploymentTarget["macOS"] {
            project.buildSettings.common.MACOSX_DEPLOYMENT_TARGET = deploymentTarget
        }

        try project.save(to: projectAbsolutePath)

        return projectPath
    }

    private func resolvePackageDependencies(in project: Path, sourcePackagesPath: Path) throws {
        log.info("📦  Resolving package dependencies...")

        let command = Xcodebuild(
            command: .resolvePackageDependencies,
            project: project.string,
            clonedSourcePackageDirectory: sourcePackagesPath.string
        )

        try command.run()
    }

    private func getWorkingPath(for dependency: SwiftPackageDescriptor) throws -> Path {
        return Config.current.getPackageRepositoryPath(for: dependency)
    }

    private func preBuild(dependency: SwiftPackageDescriptor, path: Path) throws {
        // Xcodebuild doesn't provide an option for specifying a Package.swift
        // file to build from and if there's an xcodeproj in the same directory
        // it will favor that. So we need to hide them from xcodebuild
        // temporarily while we build.
        try path.glob("*.xcodeproj").forEach { try $0.delete() }
        try path.glob("*.xcworkspace").forEach { try $0.delete() }
    }

    private func buildAndExport(
        buildable: SwiftPackageBuildable,
        package: SwiftPackageDescriptor,
        dependency: PackageDependency?,
        path: Path
    ) throws -> [Artifact] {
        let archivePaths = try options.platforms.sdks.map { sdk -> Path in

            let archivePath = XcodeBuilder.getArchivePath(dependency: package, scheme: buildable.name, sdk: sdk)

            if options.skipClean, archivePath.exists {
                return archivePath
            }

            try forceDynamicFrameworkProduct(scheme: buildable.name, in: path)

            do {
                let archivePath = try XcodeBuilder.archive(
                    dependency: package, 
                    scheme: buildable.buildName,
                    in: path,
                    for: sdk,
                    derivedDataPath: derivedDataPath,
                    additionalBuildSettings: dependency?.additionalBuildSettings
                )

                try copyModulesAndHeaders(
                    package: package,
                    scheme: buildable.name,
                    sdk: sdk,
                    archivePath: archivePath,
                    derivedDataPath: derivedDataPath
                )

                return archivePath
            } catch {
                log.error("Failed to build \(package.name), scheme=\(buildable.name), sdk=\(sdk.rawValue)")
                throw error
            }
        }

        let artifacts = try XcodeBuilder.createXCFramework(
            archivePaths: archivePaths,
            skipIfExists: options.skipClean
        ).map { path in
            return Artifact(
                name: path.lastComponentWithoutExtension,
                parentName: package.name,
                version: package.version,
                path: path
            )
        }

        return artifacts
    }

    // We need to rewrite Package.swift to force build a dynamic framework
    // https://forums.swift.org/t/how-to-build-swift-package-as-xcframework/41414/4
    private func forceDynamicFrameworkProduct(scheme: String, in path: Path) throws {
        precondition(path.exists, "You must call preBuild() before calling this function")

        for file in path.glob("Package*.swift") {
            var contents: String = try file.read()

            let productRegex = try Regex(string: #"(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)"#)

            if let _ = productRegex.firstMatch(in: contents) {
                // TODO: This should be rewritten using the Regex library
                try sh("/usr/bin/perl", "-i", "-p0e", #"s/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)[^,]*type: \.static[^,]*,/$1/g"#, file.string)
                try sh("/usr/bin/perl", "-i", "-p0e", #"s/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)[^,]*type: \.dynamic[^,]*,/$1/g"#, file.string)
                try sh("/usr/bin/perl", "-i", "-p0e", #"s/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)/$1 type: \.dynamic,/g"#, file.string)
            } else {
                let insertRegex = Regex(#"products:[^\[]*\["#)
                guard let match = insertRegex.firstMatch(in: contents)?.range else {
                    fatalError("failed to force dynamic framework")
                }

                contents.insert(contentsOf: #".library(name: "\#(scheme)", type: .dynamic, targets: ["\#(scheme)"]),"#, at: match.upperBound)
                try file.write(contents)
            }
        }
    }

    private func renameProducts(using mapping: [String: String], in path: Path) throws {
        precondition(path.exists, "You must call preBuild() before calling this function")

        for file in path.glob("Package*.swift") {
            let contents: String = try file.read()
            var packageFile = contents.swiftPackageFile

            for (productName, newValue) in mapping {
                packageFile.replaceProductName(productName, newName: newValue)
            }

            try file.write(packageFile.contents)
        }
    }

    private func renameTargets(using mapping: [String: String], in path: Path) throws {
        precondition(path.exists, "You must call preBuild() before calling this function")

        for file in path.glob("Package*.swift") {
            let contents: String = try file.read()
            var packageFile = contents.swiftPackageFile

            for (productName, newValue) in mapping {
                packageFile.replaceTargetName(productName, newName: newValue)
            }

            try file.write(packageFile.contents)
        }
    }

    private func copyModulesAndHeaders(package: SwiftPackageDescriptor, scheme: String, sdk: Xcodebuild.SDK, archivePath: Path, derivedDataPath: Path) throws {
        // https://forums.swift.org/t/how-to-build-swift-package-as-xcframework/41414/4
        let frameworksPath = archivePath + "Products/Library/Frameworks"
        let frameworks = frameworksPath.glob("*.framework")

        if frameworks.isEmpty {
            throw ScipioError.missingFrameworks(package: package.name)
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

            let target = package.manifest.targets.first(where: { $0.name == frameworkName })

            if swiftModulePath.exists {
                // Swift projects
                try swiftModulePath.copy(modulesPath + "\(frameworkName).swiftmodule")
            }

            let hasHeaderSearchPath = target?.settings
                .contains { setting in
                    switch setting.kind {
                    case .headerSearchPath:
                        return true
                    default:
                        return false
                    }
                } ?? false

            if !swiftModulePath.exists || hasHeaderSearchPath {
                // Objective-C projects
                let moduleMapDirectory = archiveIntermediatesPath + "IntermediateBuildFilesPath/\(package.name).build/Release-\(sdk.rawValue)/\(frameworkName).build"
                var moduleMapPath = moduleMapDirectory.glob("*.modulemap").first
                var moduleMapContent = "module \(frameworkName) { export * }"
                var includeDirectory: Path? = nil

                // If we can't find the generated modulemap, we check
                // to see if the package includes its own.
                if (moduleMapPath == nil || moduleMapPath?.exists == false),
                   let target = package.manifest.targets.first(where: { $0.name == frameworkName }),
                   target.type != .binary,
                   let path = target.path {

                    moduleMapPath = try (package.path + Path(path))
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
                    let targets = package
                        .manifest
                        .products
                        .filter { $0.name == frameworkName }
                        .flatMap(\.targets)
                        .compactMap { target in package.manifest.targets.first { $0.name == target } }
                    let dependencies = targets
                        .flatMap { $0.dependencies }
                        .map { dependency in
                            switch dependency {
                            case .target(let name, _):
                                return name
                            case .product(let name, _, _, _):
                                return name
                            case .byName(let name, _):
                                return name
                            }
                        }
                        .compactMap { target in package.targets.first { $0.name == target } }
                    let allTargets: [TargetDescription] = (targets + dependencies)
                    let headerPaths: [Path] = allTargets
                        .compactMap { target in
                            guard let publicHeadersPath = target.publicHeadersPath else { return nil }

                            if let path = target.path {
                                return Path(path) + Path(publicHeadersPath)
                            } else {
                                return Path(publicHeadersPath)
                            }
                        }
                    let headers = try headerPaths
                        .flatMap { headerPath -> [Path] in
                            guard headerPath.exists else { return [] }

                            return try (package.path + headerPath)
                                .recursiveChildren()
                                .filter { $0.extension == "h" }
                        }

                    if !headersPath.exists, !headers.isEmpty {
                        try headersPath.mkdir()
                    }

                    for headerPath in headers {
                        let targetPath = headersPath + headerPath.lastComponent

                        if !targetPath.exists, headerPath.exists {
                            try headerPath.copy(targetPath)
                        }
                    }

                    moduleMapContent = """
                        framework module \(frameworkName) {
                        \(headers.map { "    header \"\($0.lastComponent)\"" }.joined(separator: "\n"))

                            export *
                        }
                        """
                }

                try (modulesPath + "module.modulemap").write(moduleMapContent)
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

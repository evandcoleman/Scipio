import Combine
import Foundation
import PathKit
import ProjectSpec
import Regex
import Version
import XcodeGenKit
import Zip

public final class PackageProcessor: DependencyProcessor {

    public let dependencies: [PackageDependency]
    public let options: ProcessorOptions

    private var derivedDataPath: Path {
        return Config.current.cachePath + "DerivedData" + Config.current.name
    }

    private var sourcePackagesPath: Path {
        return Config.current.cachePath + "SourcePackages" + Config.current.name
    }

    private let urlSession: URLSession = .createWithExtensionsSupport()

    public init(dependencies: [PackageDependency], options: ProcessorOptions) {
        self.dependencies = dependencies
        self.options = options
    }

    public func preProcess() -> AnyPublisher<[SwiftPackageDescriptor], Error> {
        return Future.try {
            let projectPath = try self.writeProject()

            if !self.derivedDataPath.exists {
                try self.derivedDataPath.mkpath()
            }

            try self.resolvePackageDependencies(in: projectPath, sourcePackagesPath: self.sourcePackagesPath)

            return try self.readPackages(sourcePackagesPath: self.sourcePackagesPath)
        }
        .eraseToAnyPublisher()
    }

    public func process(_ dependency: PackageDependency?, resolvedTo resolvedDependency: SwiftPackageDescriptor) -> AnyPublisher<[AnyArtifact], Error> {
        return Future<([AnyArtifact], [AnyPublisher<AnyArtifact, Error>]), Error>.try {

            var xcFrameworks: [Artifact] = []
            var downloads: [AnyPublisher<AnyArtifact, Error>] = []

            for product in resolvedDependency.buildables {
                if case .binaryTarget(let target) = product {
                    let targetPath = Config.current.buildPath + "\(product.name).xcframework"
                    let artifact = Artifact(
                        name: product.name,
                        parentName: resolvedDependency.name,
                        version: resolvedDependency.version,
                        path: targetPath
                    )

                    if self.options.skipClean, targetPath.exists {
                        xcFrameworks <<< artifact
                        continue
                    }

                    if let urlString = target.url, let url = URL(string: urlString),
                       let checksum = target.checksum {
                        downloads <<< Future<Path, Error>.deferred { promise in
                            let task = self.urlSession
                                .downloadTask(with: url, progressHandler: { log.progress(percent: $0) }) { url, response, error in
                                    if let error = error {
                                        promise(.failure(error))
                                    } else if let url = url {
                                        promise(.success(Path(url.path)))
                                    } else {
                                        log.fatal("Unexpected download result")
                                    }
                                }

                            log.info("Downloading \(url.lastPathComponent):")

                            task.resume()
                        }
                        .tryMap { downloadPath -> AnyArtifact in
                            let zipPath = Config.current.cachePath + url.lastPathComponent

                            if zipPath.exists {
                                try zipPath.delete()
                            }

                            try downloadPath.copy(zipPath)

                            guard try zipPath.checksum(.sha256) == checksum else {
                                throw ScipioError.checksumMismatch(product: product.name)
                            }

                            if targetPath.exists {
                                try targetPath.delete()
                            }

                            log.info("Decompressing \(zipPath.lastComponent):")

                            try Zip.unzipFile(zipPath.url, destination: targetPath.parent().url, overwrite: true, password: nil, progress: { log.progress(percent: $0) })

                            return AnyArtifact(artifact)
                        }
                        .eraseToAnyPublisher()
                    } else if let targetPath = target.path {
                        let fullPath = resolvedDependency.path + Path(targetPath)
                        let targetPath = Config.current.buildPath + fullPath.lastComponent

                        if targetPath.exists {
                            try targetPath.delete()
                        }

                        try fullPath.copy(targetPath)

                        xcFrameworks <<< artifact
                    }
                } else {
                    xcFrameworks <<< try self.buildAndExport(
                        buildable: product,
                        package: resolvedDependency
                    )
                }
            }

            return (xcFrameworks.map { AnyArtifact($0) }, downloads)
        }
        .flatMap { frameworks, downloads -> AnyPublisher<[AnyArtifact], Error> in
            return downloads
                .publisher
                .flatMap(maxPublishers: .max(1)) { $0 }
                .collect()
                .map { frameworks + $0 }
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }

    public func postProcess() -> AnyPublisher<(), Error> {
        return Just(())
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    private func writeProject() throws -> Path {
        let projectName = "Packages.xcodeproj"
        let projectPath = Config.current.cachePath + Config.current.name + projectName

        if projectPath.exists {
            try projectPath.delete()
        }
        if !projectPath.parent().exists {
            try projectPath.parent().mkpath()
        }

        let projectSpec = Project(
            basePath: Config.current.cachePath,
            name: projectName,
            packages: dependencies.reduce(into: [:]) { $0[$1.name] = .remote(url: $1.url.absoluteString, versionRequirement: $1.versionRequirement) },
            options: .init(
                deploymentTarget: .init(
                    iOS: Version(Config.current.deploymentTarget["iOS"] ?? ""),
                    tvOS: Version(Config.current.deploymentTarget["tvOS"] ?? ""),
                    watchOS: Version(Config.current.deploymentTarget["watchOS"] ?? ""),
                    macOS: Version(Config.current.deploymentTarget["macOS"] ?? "")
                )
            ))
        let projectGenerator = ProjectGenerator(project: projectSpec)
        let project = try projectGenerator.generateXcodeProject(in: Config.current.cachePath)
        try project.write(path: projectPath)

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

    private func readPackages(sourcePackagesPath: Path) throws -> [SwiftPackageDescriptor] {
        log.info("🧮  Loading Swift packages...")

        let decoder = JSONDecoder()
        let workspacePath = sourcePackagesPath + "workspace-state.json"
        let workspaceState = try decoder.decode(WorkspaceState.self, from: try workspacePath.read())

        return try workspaceState.object
            .dependencies
            .map { try SwiftPackageDescriptor(path: workspacePath.parent() + "checkouts" + Path($0.subpath), name: $0.packageRef.name) }
    }

    private func setupWorkingPath(for dependency: SwiftPackageDescriptor) throws -> Path {
        let workingPath = Config.current.cachePath + dependency.name
        // Copy the repo to a temporary directory first so we don't modify
        // it in place.
        if workingPath.exists {
            try workingPath.delete()
        }
        try dependency.path.copy(workingPath)

        return workingPath
    }

    private func preBuild(path: Path) throws {
        // Xcodebuild doesn't provide an option for specifying a Package.swift
        // file to build from and if there's an xcodeproj in the same directory
        // it will favor that. So we need to hide them from xcodebuild
        // temporarily while we build.
        try path.glob("*.xcodeproj").forEach { try $0.move($0.parent() + "\($0.lastComponent).bak") }
        try path.glob("*.xcworkspace").forEach { try $0.move($0.parent() + "\($0.lastComponent).bak") }
    }

    private func postBuild(path: Path) throws {
        try path.glob("*.xcodeproj.bak").forEach { try $0.move($0.parent() + "\($0.lastComponentWithoutExtension)") }
        try path.glob("*.xcworkspace.bak").forEach { try $0.move($0.parent() + "\($0.lastComponentWithoutExtension)") }

        try path.delete()
    }

    private func buildAndExport(buildable: SwiftPackageBuildable, package: SwiftPackageDescriptor) throws -> [Artifact] {
        var path: Path? = nil

        let archivePaths = try options.platforms.sdks.map { sdk -> Path in

            if options.skipClean, Xcode.getArchivePath(for: buildable.name, sdk: sdk).exists {
                return Xcode.getArchivePath(for: buildable.name, sdk: sdk)
            }

            if path == nil {
                path = try self.setupWorkingPath(for: package)
                try self.preBuild(path: path!)
            }

            try forceDynamicFrameworkProduct(scheme: buildable.name, in: path!)

            let archivePath = try Xcode.archive(
                scheme: buildable.name,
                in: path!,
                for: sdk,
                derivedDataPath: derivedDataPath
            )

            try copyModulesAndHeaders(
                package: package,
                scheme: buildable.name,
                sdk: sdk,
                archivePath: archivePath,
                derivedDataPath: derivedDataPath
            )

            return archivePath
        }

        let artifacts = try Xcode.createXCFramework(
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

        if let path = path {
            try self.postBuild(path: path)
        }

        return artifacts
    }

    // We need to rewrite Package.swift to force build a dynamic framework
    // https://forums.swift.org/t/how-to-build-swift-package-as-xcframework/41414/4
    private func forceDynamicFrameworkProduct(scheme: String, in path: Path) throws {
        precondition(path.exists, "You must call preBuild() before calling this function")

        var contents: String = try (path + "Package.swift").read()

        let productRegex = try Regex(string: #"(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)"#)

        if let _ = productRegex.firstMatch(in: contents) {
            // TODO: This should be rewritten using the Regex library
            try path.chdir {
                try sh(#"perl -i -p0e 's/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)[^,]*type: \.static[^,]*,/$1/g' Package.swift"#).waitUntilExit()
                try sh(#"perl -i -p0e 's/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)[^,]*type: \.dynamic[^,]*,/$1/g' Package.swift"#).waitUntilExit()
                try sh(#"perl -i -p0e 's/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)/$1 type: \.dynamic,/g' Package.swift"#).waitUntilExit()
            }
        } else {
            let insertRegex = Regex(#"products:[^\[]*\["#)
            guard let match = insertRegex.firstMatch(in: contents)?.range else {
                fatalError()
            }

            contents.insert(contentsOf: #".library(name: "\#(scheme)", type: .dynamic, targets: ["\#(scheme)"]),"#, at: match.upperBound)
            try (path + "Package.swift").write(contents)
        }
    }

    private func copyModulesAndHeaders(package: SwiftPackageDescriptor, scheme: String, sdk: Xcodebuild.SDK, archivePath: Path, derivedDataPath: Path) throws {
        // https://forums.swift.org/t/how-to-build-swift-package-as-xcframework/41414/4
        let frameworksPath = archivePath + "Products/Library/Frameworks"

        for frameworkPath in frameworksPath.glob("*.framework") {
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

            if !swiftModulePath.exists || target?.settings?.contains(where: { $0.name == .headerSearchPath }) == true {
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
                        .flatMap { $0.names }
                        .compactMap { target in package.manifest.targets.first { $0.name == target } }
                    let allTargets: [PackageManifest.Target] = (targets + dependencies)
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
                let name: Name

                enum Name: String, Codable {
                    case checkout
                }

                struct CheckoutState: Codable {
                    let branch: String?
                    let revision: String
                    let version: String?
                }
            }
        }

        struct PackageRef: Codable {
            let identity: String
            let kind: Kind
            let name: String
            let path: String
        }

        enum Kind: String, Codable {
            case local
            case remote
        }

        struct Artifact: Codable {
            let packageRef: PackageRef
            let source: Source
            let targetName: String

            struct Source: Codable {
                let path: String?
                let type: Kind
                let checksum, subpath: String?
                let url: String?
            }
        }
    }
}

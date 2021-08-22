import Combine
import Foundation
import PathKit
import ProjectSpec
import Regex
import Version
import XcodeGenKit

public struct PackageProcessor: DependencyProcessor {

    let dependencies: [PackageDependency]
    let options: ProcessorOptions

    public init(dependencies: [PackageDependency], options: ProcessorOptions) {
        self.dependencies = dependencies
        self.options = options
    }
    
    public func process() -> AnyPublisher<[Path], Error> {
        return Future.try { promise in
            let projectPath = try writeProject()
            let derivedDataPath = Config.current.cachePath + "DerivedData" + Config.current.name

            if !derivedDataPath.exists {
                try derivedDataPath.mkpath()
            }

            resolvePackageDependencies(in: projectPath, derivedDataPath: derivedDataPath)

            let packages = try readPackages(derivedDataPath: derivedDataPath)
            var xcFrameworks: [Path] = []

            for package in packages {
                let path = try setupWorkingPath(for: package)
                try preBuild(path: path)

                for product in package.productNames {
                    forceDynamicFrameworkProduct(scheme: product, in: path)

                    for sdk in options.platform.sdks {
                        let archivePath = try Xcode.archive(
                            scheme: product,
                            in: path,
                            for: sdk,
                            derivedDataPath: derivedDataPath
                        )

                        try copyModulesAndHeaders(
                            package: package,
                            scheme: product,
                            sdk: sdk,
                            archivePath: archivePath,
                            derivedDataPath: derivedDataPath
                        )
                    }

                    xcFrameworks.append(contentsOf: try Xcode.createXCFramework(
                        scheme: product,
                        path: path,
                        sdks: options.platform.sdks,
                        force: options.forceBuild,
                        skipClean: options.skipClean
                    ))
                }

                try postBuild(path: path)
            }

            promise(.success(xcFrameworks))
        }
        .eraseToAnyPublisher()
    }

    private func writeProject() throws -> Path {
        let projectName = "Packages.xcodeproj"
        let projectPath = Config.current.cachePath + Config.current.name + projectName

        if !options.skipClean, projectPath.exists {
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
                    iOS: Version(Config.current.deploymentTarget?["iOS"] ?? ""),
                    tvOS: Version(Config.current.deploymentTarget?["tvOS"] ?? ""),
                    watchOS: Version(Config.current.deploymentTarget?["watchOS"] ?? ""),
                    macOS: Version(Config.current.deploymentTarget?["macOS"] ?? "")
                )
            ))
        let projectGenerator = ProjectGenerator(project: projectSpec)
        let project = try projectGenerator.generateXcodeProject(in: Config.current.cachePath)
        try project.write(path: projectPath)

        return projectPath
    }

    private func resolvePackageDependencies(in project: Path, derivedDataPath: Path) {
        let command = Xcodebuild(
            command: .resolvePackageDependencies,
            project: project.string,
            derivedDataPath: derivedDataPath.string
        )

        command.run()
    }

    private func readPackages(derivedDataPath: Path) throws -> [SwiftPackageDescriptor] {
        let decoder = JSONDecoder()
        let workspacePath = derivedDataPath + "SourcePackages" + "workspace-state.json"
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

    private func forceDynamicFrameworkProduct(scheme: String, in path: Path) {
        precondition(path.exists, "You must call preBuild() before calling this function")

        path.chdir {
            // We need to rewrite Package.swift to force build a dynamic framework
            // https://forums.swift.org/t/how-to-build-swift-package-as-xcframework/41414/4
            // TODO: This should be rewritten using the Regex library
            sh(#"perl -i -p0e 's/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)[^,]*type: \.static[^,]*,/$1/g' Package.swift"#).logOutput().waitUntilExit()
            sh(#"perl -i -p0e 's/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)[^,]*type: \.dynamic[^,]*,/$1/g' Package.swift"#).logOutput().waitUntilExit()
            sh(#"perl -i -p0e 's/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)/$1 type: \.dynamic,/g' Package.swift"#).logOutput().waitUntilExit()
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

                // If we can't find the generated modulemap, we check
                // to see if the package includes its own.
                if (moduleMapPath == nil || moduleMapPath?.exists == false),
                   let target = package.manifest.targets.first(where: { $0.name == frameworkName }),
                   let path = target.path {

                    moduleMapPath = try Path(path)
                        .recursiveChildren()
                        .filter { $0.extension == "modulemap" }
                        .first
                }

                if let moduleMapPath = moduleMapPath, moduleMapPath.exists {
                    let umbrellaHeaderRegex = Regex(#"umbrella (?:header )?"(.*)""#)
                    let umbrellaHeaderMatch = umbrellaHeaderRegex.firstMatch(in: try moduleMapPath.read())

                    if let match = umbrellaHeaderMatch, !match.captures.isEmpty,
                       let umbrellaHeaderPathString = match.captures[0] {

                        var umbrellaHeaderPath = Path(umbrellaHeaderPathString)
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
                        if umbrellaHeaderPath.isFile {
                            let headerContent = try umbrellaHeaderPath
                                .read()
                                .replacingFirst(matching: Regex(#"^#import "(.*).h""#, options: [.anchorsMatchLines]), with: "#import <\(frameworkName)/$1.h>")
                            let path = headersPath + umbrellaHeaderPath.lastComponent
                            try path.write(headerContent)
                        } else {
                            umbrellaHeaderPath = headersPath + "\(frameworkName).h"
                            let umbrellaHeaderContent = sourceHeadersDirectory
                                .glob("*.h")
                                .map { "#import <\(frameworkName)/\($0.lastComponent)>" }
                                .joined(separator: "\n")
                            try umbrellaHeaderPath.write(umbrellaHeaderContent)
                        }

                        let allHeaderPaths = try getHeaders(in: umbrellaHeaderPath, frameworkName: frameworkName, sourceHeadersDirectory: sourceHeadersDirectory)

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

// MARK: - SwiftPackageDescriptor
private struct SwiftPackageDescriptor {

    let name: String
    let version: String
    let path: Path
    let manifest: PackageManifest

    var productNames: [String] {
        return manifest.products.map(\.name)
    }

    init(path: Path, name: String) throws {
        self.name = name
        self.path = path

        var gitPath = path + ".git"

        guard gitPath.exists else {
            log.fatal("Missing git directory for package: \(name)")
        }

        if gitPath.isFile {
            guard let actualPath = (try gitPath.read()).components(separatedBy: "gitdir: ").last?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                log.fatal("Couldn't parse .git file in \(path)")
            }

            gitPath = (gitPath.parent() + Path(actualPath)).normalize()
        }

        let headPath = gitPath + "HEAD"

        guard headPath.exists else {
            log.fatal("Missing HEAD file in \(gitPath)")
        }

        self.version = (try headPath.read())
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let cachedManifestPath = Config.current.cachePath + "\(path.lastComponent)-\(try path.glob("Package.swift")[0].checksum(.sha256)).json"
        let data: Data
        if cachedManifestPath.exists {
            log.verbose("Loading cached Package.swift for \(path.lastComponent)")
            data = try cachedManifestPath.read()
        } else {
            log.verbose("Reading Package.swift for \(path.lastComponent)")
            data = sh("swift package dump-package --package-path \(path.string)")
                .waitForOutput()
            try cachedManifestPath.write(data)
        }
        let decoder = JSONDecoder()
        self.manifest = try decoder.decode(PackageManifest.self, from: data)
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

// MARK: - PackageManifest
private struct PackageManifest: Codable {
    let name: String
    let products: [Product]
    let targets: [Target]
}

extension PackageManifest {

    struct Product: Codable {
        let name: String
        let targets: [String]
    }

    struct Target: Codable {
        let dependencies: [TargetDependency]
        let name: String
        let path: String?
        let publicHeadersPath: String?
        let type: TargetType
        let checksum: String?
        let url: String?
        let settings: [Setting]?

        struct Setting: Codable {
            let name: Name
            let value: [String]

            enum Name: String, Codable {
                case define
                case headerSearchPath
                case linkedFramework
                case linkedLibrary
            }
        }
    }

    struct TargetDependency: Codable {
        let byName: [Dependency?]?
        let product: [Dependency?]?
        let target: [Dependency?]?

        var names: [String] {
            return [byName, product, target]
                .compactMap { $0 }
                .flatMap { $0 }
                .compactMap { dependency in
                    switch dependency {
                    case .name(let name):
                        return name
                    default:
                        return nil
                    }
                }
        }

        enum Dependency: Codable {
            case name(String)
            case constraint(platforms: [String])

            enum CodingKeys: String, CodingKey {
                case platformNames
            }

            init(from decoder: Decoder) throws {
                if let container = try? decoder.singleValueContainer(),
                   let stringValue = try? container.decode(String.self) {

                    self = .name(stringValue)
                } else {
                    let container = try decoder.container(keyedBy: CodingKeys.self)

                    self = .constraint(platforms: try container.decode([String].self, forKey: .platformNames))
                }
            }

            func encode(to encoder: Encoder) throws {
                switch self {
                case .name(let name):
                    var container = encoder.singleValueContainer()
                    try container.encode(name)
                case .constraint(let platforms):
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(platforms, forKey: .platformNames)
                }
            }
        }
    }

    enum TargetType: String, Codable {
        case binary = "binary"
        case regular = "regular"
        case test = "test"
    }
}

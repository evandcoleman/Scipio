import Combine
import Foundation
import PathKit
import Regex
import Zip

public struct Package {

    public let path: Path
    public let description: Description
    public let version: String
    public let productNames: [String: [String]] // [scheme: [product]]
    public let buildables: [Buildable]

    public var name: String { description.name }

    private let workingPath: Path

    private let cancelBag = CancelBag()

    enum UploadError: Error {
        case zipFailed(product: String, path: Path)
    }

    public init(path: Path) throws {
        let packagePath = path.isFile ? path.parent() : path
        self.path = packagePath
        let description = try Description(path: path)
        self.description = description
        self.productNames = try description.getProductNames()
        self.buildables = description.getBuildables()
        self.workingPath = Config.current.cachePath + description.name

        let readGitHead: (Path) throws -> String = { path in
            var gitPath = path + ".git"

            guard gitPath.exists else {
                log.fatal("Missing git directory for package: \(description.name)")
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

            return (try headPath.read())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch description {
        case .package:
            self.version = try readGitHead(packagePath)
        case .project:
            self.version = try readGitHead(packagePath.parent())
        }
    }

    public func upload(parent: Package, force: Bool) -> AnyPublisher<(), Error> {
        return productNames
            .flatMap { $0.value }
            .publisher
            .flatMap { product -> AnyPublisher<(String, Bool), Error> in
                guard !force else {
                    return Just((product, true))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }

                return Config.current.cache
                    .exists(product: product, version: self.version)
                    .flatMap { exists -> AnyPublisher<Bool, Error> in
                        if exists, !self.compressedPath(for: product).exists {
                            return Config.current.cache
                                .get(
                                    product: product,
                                    version: self.version,
                                    destination: self.compressedPath(for: product)
                                )
                                .map { _ in exists }
                                .eraseToAnyPublisher()
                        } else {
                            return Just(exists)
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }
                    }
                    .filter { _ in self.artifactPath(for: product).exists || self.compressedPath(for: product).exists }
                    .map { (product, !$0) }
                    .eraseToAnyPublisher()
            }
            .tryFlatMap { product, shouldUpload -> AnyPublisher<(), Error> in
                let frameworkPath = self.artifactPath(for: product)
                let zipPath = self.compressedPath(for: product)

                if zipPath.exists {
                    try zipPath.delete()
                }

                if frameworkPath.exists {
                    do {
                        try Zip.zipFiles(paths: [frameworkPath.url], zipFilePath: zipPath.url, password: nil, progress: nil)
                    } catch ZipError.zipFail {
                        throw UploadError.zipFailed(product: product, path: frameworkPath)
                    }
                }

                let url = Config.current.cache.downloadUrl(for: product, version: self.version)
                let checksum = try zipPath.checksum(.sha256)

                let uploadOrNotPublisher: AnyPublisher<(), Error>
                if shouldUpload {
                    log.info("☁️ Uploading \(product)...")
                    uploadOrNotPublisher = Config.current.cache
                        .put(product: product, version: self.version, path: zipPath)
                } else {
                    uploadOrNotPublisher = Just(())
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }

                return uploadOrNotPublisher
                    .tryMap { value in
                        switch parent.description {
                        case .package(let manifest):
                            let target = manifest.targets.first { $0.name == product }
                            let manifestPath = parent.path + "Package.swift"
                            var packageContents: String = try manifestPath.read()

                            if let target = target, target.checksum != checksum {
                                log.info("✍️ Updating checksum for \(product) because they do not match...")

                                if url.isFileURL {
                                    let regex = try Regex(string: #"(\.binaryTarget\([\n\r\s]+name\s?:\s"\#(product)"\s?,[\n\r\s]+path:\s?)"(.*)""#)

                                    packageContents = packageContents.replacingFirst(
                                        matching: regex,
                                        with: #"$1"\#(url.path)"$3"#
                                    )
                                } else {
                                    let regex = try Regex(string: #"(\.binaryTarget\([\n\r\s]+name\s?:\s"\#(product)"\s?,[\n\r\s]+url:\s?)"(.*)"(\s?,[\n\r\s]+checksum:\s?)"(.*)""#)

                                    packageContents = packageContents.replacingFirst(
                                        matching: regex,
                                        with: #"$1"\#(url)"$3"\#(checksum)""#
                                    )
                                }
                            } else if target == nil {
                                self.addProduct(product, to: &packageContents)

                                let allTargetMatches = Regex(#"(\.binaryTarget\([\n\r\s]*name\s?:\s"[A-Za-z]*"[^,]*,[^,]*,[^,]*,)"#).allMatches(in: packageContents)
                                packageContents.insert(contentsOf: "\n        .binaryTarget(\n            name: \"\(product)\",\n            url: \"\(url)\",\n            checksum: \"\(checksum)\"\n        ),", at: allTargetMatches.last!.range.upperBound)
                            }

                            try manifestPath.write(packageContents)
                        default:
                            log.fatal("Parent package must be a Swift package")
                        }

                        return value
                    }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    internal func missingProducts() -> AnyPublisher<[String], Error> {
        let publishers = productNames
            .flatMap { $0.value }
            .map { product -> AnyPublisher<String, Error> in
                if self.artifactPath(for: product).exists {
                    return Empty()
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }

                return Config.current.cache
                    .exists(product: product, version: version)
                    .filter { !$0 }
                    .map { _ in product }
                    .eraseToAnyPublisher()
            }

        return Publishers
            .MergeMany(publishers)
            .collect()
            .eraseToAnyPublisher()
    }

    internal func preBuild() throws {
        // Copy the repo to a temporary directory first so we don't modify
        // it in place.
        if workingPath.exists {
            try workingPath.delete()
        }
        try path.copy(workingPath)

        // Xcodebuild doesn't provide an option for specifying a Package.swift
        // file to build from and if there's an xcodeproj in the same directory
        // it will favor that. So we need to hide them from xcodebuild
        // temporarily while we build.
        try workingPath.glob("*.xcodeproj").forEach { try $0.move($0.parent() + "\($0.lastComponent).bak") }
        try workingPath.glob("*.xcworkspace").forEach { try $0.move($0.parent() + "\($0.lastComponent).bak") }
    }

    internal func postBuild() throws {
        try workingPath.glob("*.xcodeproj.bak").forEach { try $0.move($0.parent() + "\($0.lastComponentWithoutExtension)") }
        try workingPath.glob("*.xcworkspace.bak").forEach { try $0.move($0.parent() + "\($0.lastComponentWithoutExtension)") }
        
        try workingPath.delete()
    }

    internal func build(_ scheme: String, in project: String? = nil, for sdk: Xcodebuild.SDK, derivedDataPath: Path) throws {

        log.info("🏗  Building \(scheme)-\(sdk.rawValue)...")

        let buildSettings: [String: String] = [
            "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
            "SKIP_INSTALL": "NO",
            "ENABLE_BITCODE": "NO",
            "INSTALL_PATH": "/Library/Frameworks"
        ]

        let archivePath = Config.current.buildPath + "\(scheme)-\(sdk.rawValue).xcarchive"
        let command = Xcodebuild(
            command: .archive,
            project: project,
            scheme: scheme,
            archivePath: archivePath.string,
            derivedDataPath: derivedDataPath.string,
            sdk: sdk,
            disableAutomaticPackageResolution: true,
            additionalBuildSettings: buildSettings
        )

        workingPath.chdir {
            command.run()
        }

        if project == nil {
            try copyModulesAndHeaders(
                scheme: scheme,
                sdk: sdk,
                archivePath: archivePath,
                derivedDataPath: derivedDataPath
            )
        }
    }

    internal func createXCFramework(scheme: String, sdks: [Xcodebuild.SDK], skipIfExists: Bool, force: Bool) throws {
        let buildDirectory = Config.current.buildPath
        let firstArchivePath = buildDirectory + "\(scheme)-\(sdks[0].rawValue).xcarchive"
        let frameworkPaths = (firstArchivePath + "Products/Library/Frameworks").glob("*.framework")

        for frameworkPath in frameworkPaths {
            let productName = frameworkPath.lastComponentWithoutExtension
            let frameworks = sdks
                .map { buildDirectory + "\(scheme)-\($0.rawValue).xcarchive/Products/Library/Frameworks/\(productName).framework" }
            let output = buildDirectory + "\(productName).xcframework"

            if !force, skipIfExists, output.exists {
                log.info("⏭  Skipping creating XCFramework for \(productName)...")
                continue
            }

            log.info("📦  Creating \(productName).xcframework...")

            if output.exists {
                try output.delete()
            }

            let command = Xcodebuild(
                command: .createXCFramework,
                additionalArguments: frameworks
                    .map { "-framework \($0)" } + ["-output \(output)"]
            )
            workingPath.chdir {
                command.run()
            }
        }
    }

    internal func forceDynamicFrameworkProduct(scheme: String) {
        precondition(workingPath.exists, "You must call preBuild() before calling this function")

        workingPath.chdir {
            // We need to rewrite Package.swift to force build a dynamic framework
            // https://forums.swift.org/t/how-to-build-swift-package-as-xcframework/41414/4
            // TODO: This should be rewritten using the Regex library
            sh(#"perl -i -p0e 's/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)[^,]*type: \.static[^,]*,/$1/g' Package.swift"#).logOutput().waitUntilExit()
            sh(#"perl -i -p0e 's/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)[^,]*type: \.dynamic[^,]*,/$1/g' Package.swift"#).logOutput().waitUntilExit()
            sh(#"perl -i -p0e 's/(\.library\([\n\r\s]*name\s?:\s"\#(scheme)"[^,]*,)/$1 type: \.dynamic,/g' Package.swift"#).logOutput().waitUntilExit()
        }
    }

    internal func copyModulesAndHeaders(project: Path? = nil, scheme: String, sdk: Xcodebuild.SDK, archivePath: Path, derivedDataPath: Path) throws {
        // https://forums.swift.org/t/how-to-build-swift-package-as-xcframework/41414/4
        let frameworksPath = archivePath + "Products/Library/Frameworks"

        for frameworkPath in frameworksPath.glob("*.framework") {
            let frameworkName = frameworkPath.lastComponentWithoutExtension
            let modulesPath = frameworkPath + "Modules"
            let headersPath = frameworkPath + "Headers"
            let projectName = project == nil ? nil : scheme

            if project == nil, !modulesPath.exists {
                try modulesPath.mkdir()
            }

            let archiveIntermediatesPath = derivedDataPath + "Build/Intermediates.noindex/ArchiveIntermediates/\(projectName ?? frameworkName)"
            let buildProductsPath = archiveIntermediatesPath + "BuildProductsPath"
            let releasePath = buildProductsPath + "Release-\(sdk.rawValue)"
            let swiftModulePath = releasePath + "\(frameworkName).swiftmodule"
            let resourcesBundlePath = releasePath + "\(frameworkName)_\(frameworkName).bundle"
            var headerSearchPaths: [Path] = []

            if case .package(let manifest) = description {
                let allTargets = ((manifest
                    .targets
                    .first { $0.name == frameworkName }?
                    .dependencies ?? [])
                    .flatMap { $0.names } + [frameworkName])
                    .compactMap { name in manifest.targets.first { $0.name == name } }
                headerSearchPaths = allTargets
                    .flatMap { target -> [(target: Manifest.Target, setting: Manifest.Target.Setting)] in
                        return (target.settings ?? [])
                            .map { (target: target, setting: $0) }
                    }
                    .filter { $0.setting.name == .headerSearchPath }
                    .flatMap { (target, setting) -> [(Manifest.Target, String)] in
                        return setting.value
                            .map { (target, $0) }
                    }
                    .map { target, searchPath -> Path in
                        if let path = target.path {
                            return Path(path) + Path(searchPath)
                        } else {
                            return Path(searchPath)
                        }
                    }
            }

            if swiftModulePath.exists, project == nil, headerSearchPaths.isEmpty {
                // Swift projects
                try swiftModulePath.copy(modulesPath + "\(frameworkName).swiftmodule")
            }

            if !swiftModulePath.exists || !headerSearchPaths.isEmpty {
                // Objective-C projects
                let moduleMapDirectory = archiveIntermediatesPath + "IntermediateBuildFilesPath/\(projectName ?? self.name).build/Release-\(sdk.rawValue)/\(frameworkName).build"
                let moduleMapPath = moduleMapDirectory.glob("*.modulemap").first
                var moduleMapContent = "module \(frameworkName) { export * }"

                if let moduleMapPath = moduleMapPath, moduleMapPath.exists, headerSearchPaths.isEmpty {
                    let umbrellaHeaderRegex = Regex(#"umbrella (?:header )?"(.*)""#)
                    let umbrellaHeaderMatch = umbrellaHeaderRegex.firstMatch(in: try moduleMapPath.read())

                    if let match = umbrellaHeaderMatch, !match.captures.isEmpty,
                       let umbrellaHeaderPathString = match.captures[0] {

                        var umbrellaHeaderPath = Path(umbrellaHeaderPathString)
                        var sourceHeadersDirectory = umbrellaHeaderPath.isFile ? umbrellaHeaderPath.parent() : umbrellaHeaderPath + frameworkName

                        if project != nil {
                            sourceHeadersDirectory = headersPath
                            umbrellaHeaderPath = headersPath + umbrellaHeaderPath
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

                        if project == nil {
                            let allHeaderPaths = try getHeaders(in: umbrellaHeaderPath, frameworkName: frameworkName, sourceHeadersDirectory: sourceHeadersDirectory)

                            if !headersPath.exists, !allHeaderPaths.isEmpty {
                                try headersPath.mkdir()
                            }

                            for headerPath in allHeaderPaths {
                                let targetPath = headersPath + headerPath.lastComponent

                                if !targetPath.exists, headerPath.exists {
                                    try headerPath.copy(targetPath)
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
                    }
                } else if case .package(let manifest) = description {
                    let targets = manifest
                        .products
                        .filter { $0.name == frameworkName }
                        .flatMap(\.targets)
                        .compactMap { target in manifest.targets.first { $0.name == target } }
                    let dependencies = targets
                        .flatMap { $0.dependencies }
                        .flatMap { $0.names }
                        .compactMap { target in manifest.targets.first { $0.name == target } }
                    let allTargets: [Manifest.Target] = (targets + dependencies)
                    let headerPaths: [Path] = allTargets
                        .compactMap { target in
                            guard let publicHeadersPath = target.publicHeadersPath else { return nil }

                            if let path = target.path {
                                return Path(path) + Path(publicHeadersPath)
                            } else {
                                return Path(publicHeadersPath)
                            }
                        } + headerSearchPaths
                    let headers = try headerPaths
                        .flatMap { headerPath -> [Path] in
                            guard headerPath.exists else { return [] }

                            return try (self.path + headerPath)
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

                if project == nil {
                    try (modulesPath + "module.modulemap").write(moduleMapContent)
                }
            }

            if resourcesBundlePath.exists {
                try resourcesBundlePath.copy(frameworkPath)
            }
        }
    }

    internal func downloadOrBuildTarget(named targetName: String, to destinationPath: Path, sdks: [Xcodebuild.SDK], derivedDataPath: Path, skipClean: Bool, force: Bool) -> AnyPublisher<Path, Error> {
        guard case .package(let manifest) = description else {
            log.fatal("Target specifier is only supported for Swift packages.")
        }

        let target = manifest.targets.first { $0.name == targetName }

        if let urlString = target?.url,
              let url = URL(string: urlString),
              let checksum = target?.checksum {

            return Future<URL, Error> { promise in
                let task = URLSession
                    .shared
                    .downloadTask(with: url) { url, response, error in
                        if let error = error {
                            promise(.failure(error))
                        } else if let url = url {
                            promise(.success(url))
                        } else {
                            log.fatal("Unexpected download result")
                        }
                    }

                task.resume()
            }
            .tryMap { url -> Path in
                let data = try Path(url.path).read()

                guard data.checksum(.sha256) == checksum else {
                    log.fatal("Checksums for target \(targetName) do not match.")
                }

                try (destinationPath + ".zip").write(data)

                return (destinationPath + ".zip")
            }
            .eraseToAnyPublisher()
        } else if let path = target?.path {
            return Future.try { promise in
                let frameworkPath = self.path + path
                try frameworkPath.copy(destinationPath)

                promise(.success(destinationPath))
            }
            .eraseToAnyPublisher()
        } else if target?.type == .regular {
            return Future.try { promise in
                try self.preBuild()

                let manifestPath = self.workingPath + "Package.swift"
                var packageContents: String = try manifestPath.read()
                self.addProduct(targetName, targets: [targetName], dynamic: true, to: &packageContents)
                try manifestPath.write(packageContents)

                for sdk in sdks {
                    try self.build(targetName, for: sdk, derivedDataPath: derivedDataPath)
                }

                try self.postBuild()

                try self.createXCFramework(scheme: targetName, sdks: sdks, skipIfExists: skipClean, force: force)

                promise(.success(self.artifactPath(for: targetName)))
            }
            .eraseToAnyPublisher()
        } else {
            log.fatal(#"Target named "\#(targetName)" was not found in package \#(name)."#)
        }
    }

    private func addProduct(_ product: String, targets: [String]? = nil, dynamic: Bool = false, to packageContents: inout String) {
        let allProductMatches = Regex(#"(\.library\([\n\r\s]*name\s?:\s"[A-Za-z]*"[^,]*,[^,]*,)"#).allMatches(in: packageContents)
        packageContents.insert(contentsOf: "        .library(name: \"\(product)\", \(dynamic ? "type: .dynamic, " : "")targets: [\((targets ?? [product]).map { "\"\($0)\"" }.joined(separator: ", "))]),\n", at: allProductMatches.first!.range.lowerBound)
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

    private func artifactPath(for product: String) -> Path {
        return Config.current.buildPath + "\(product).xcframework"
    }

    private func compressedPath(for product: String) -> Path {
        return Config.current.buildPath + "\(product).xcframework.zip"
    }
}

public extension Package {
    enum Buildable {
        case scheme(String)
        case target(String)
        case project(_ path: Path, scheme: String)

        init(_ product: Config.Product) {
            switch product {
            case .scheme(let name):
                self = .scheme(name)
            case .target(let name):
                self = .target(name)
            }
        }
    }
}

public extension Package {
    enum Description {
        case package(Manifest)
        case project(Project)

        var name: String {
            switch self {
            case .package(let manifest): return manifest.name
            case .project(let project): return project.name
            }
        }

        init(path: Path) throws {
            if path.isDirectory, !path.glob("Package.swift").isEmpty {
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
                self = .package(try decoder.decode(Manifest.self, from: data))
            } else if path.extension == "xcodeproj" {
                self = .project(try .init(path: path))
            } else {
                fatalError("Unexpected package path \(path.string)")
            }
        }

        func getProductNames() throws -> [String: [String]] {
            let package = Config.current.packages?[name]

            switch self {
            case .package(let manifest):
                if let products = package?.products {
                    return products.reduce(into: [:]) { $0[$1.name] = [$1.name] }
                } else {
                    return manifest.products.reduce(into: [:]) { $0[$1.name] = [$1.name] }
                }
            case .project(let project):
                return try project.productNames(config: package)
            }
        }

        func getBuildables() -> [Package.Buildable] {
            if let products = Config.current.packages?[name]?.products {
                return products.map { .init($0) }
            } else {
                switch self {
                case .package(let manifest):
                    return [.scheme(manifest.name)]
                case .project(let project):
                    return [.project(project.path, scheme: project.name)]
                }
            }
        }
    }
}

public extension Package {
    struct Manifest: Codable {
        let name: String
        let products: [Product]
        let targets: [Target]
    }
}

public extension Package.Manifest {

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

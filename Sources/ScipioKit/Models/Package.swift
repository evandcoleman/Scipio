import Combine
import Foundation
import Gzip
import PathKit
import ProjectSpec
import Regex
import XcodeGenKit
import XcodeProj
import Zip

public struct Package {

    public let path: Path!
    public let description: Description
    public let version: String
    public let buildables: [Buildable]

    public var name: String { description.name }

    private let workingPath: Path

    private let urlSession: URLSession = .createWithExtensionsSupport()
    private let cancelBag = CancelBag()

    enum UploadError: Error {
        case zipFailed(product: String, path: Path)
    }

    enum LoadError: Error {
        case missingUrl
        case missingVersion
    }

    public init(path: Path, name: String? = nil, package: Config.Package? = nil) throws {
        if !path.exists, package?.cocoapod != nil {
            try path.mkpath()
        }

        let packagePath = path.isFile ? path.parent() : path
        self.path = packagePath
        let description = package?.cocoapod != nil ? .cocoapod(name!, package!.cocoapod!) : try Description(path: path)
        self.description = description
        self.buildables = description.getBuildables()
        self.workingPath = Config.current.cachePath + description.name
        var cocoapodVersion: String? = nil

        if let podName = package?.cocoapod {
//            sh("which pod").logOutput().waitUntilExit()

            try path.chdir {

                
            }
        }

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
        case .cocoapod:
            self.version = cocoapodVersion!
        case .url:
            fatalError()
        }
    }

    internal init(name: String, package: Config.Package) throws {
        guard let url = package.url else { throw LoadError.missingUrl }
        guard let version = package.version else { throw LoadError.missingVersion }

        self.path = nil
        let description: Description = .url(name: name, url: url, version: version)
        self.description = description
        self.buildables = description.getBuildables()
        self.workingPath = Config.current.cachePath + description.name
        self.version = version
    }

    public func upload(parent: Package, force: Bool) -> AnyPublisher<(), Error> {
        return productNames()
            .flatMap { $0.flatMap(\.value).publisher }
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

                if frameworkPath.exists, !zipPath.exists {
                    do {
                        try Zip.zipFiles(paths: [frameworkPath.url], zipFilePath: zipPath.url, password: nil, progress: { log.progress("Compressing \(frameworkPath.lastComponent)", percent: $0) })
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

    internal func productNames() -> AnyPublisher<[String: [String]] /* [scheme: [product]] */, Error> {
        let package = Config.current.packages?[name]

        return Just(description)
            .setFailureType(to: Error.self)
            .tryFlatMap { description -> AnyPublisher<[String: [String]], Error> in
                switch description {
                case .package(let manifest):
                    if let products = package?.products {
                        return Just(products.reduce(into: [:]) { $0[$1.name] = [$1.name] })
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    } else {
                        return Just(manifest.products.reduce(into: [:]) { $0[$1.name] = [$1.name] })
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    }
                case .project(let project):
                    return Just(try project.productNames(config: package))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                case .url(let name, let url, _):
                    let cachedProductNamesPath = Config.current.cachePath + "\(url.path.checksum(.sha256)).json"

                    if cachedProductNamesPath.exists {
                        let result = try JSONSerialization.jsonObject(with: try cachedProductNamesPath.read(), options: []) as! [String: [String]]

                        return Just(result)
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    }

                    return self.download(from: url)
                        .tryMap { paths in
                            let filteredPaths = paths
                                .map(\.lastComponentWithoutExtension)
                                .uniqued()
                                .filter { Config.current.packages?[name]?.exclude?.contains($0) != true }
                            let result = [name: filteredPaths]
                            let data = try JSONSerialization.data(withJSONObject: result, options: [])
                            try cachedProductNamesPath.write(data)

                            return result
                        }
                        .eraseToAnyPublisher()
                case .cocoapod(let name, _):
                    return Future.try { promise in
                        let podsProjectPath = path + "Pods/Pods.xcodeproj"
                        let project = try XcodeProj(path: podsProjectPath)
                        let products = project
                            .pbxproj
                            .groups
                            .first { $0.name == "Products" }?
                            .children
                            .compactMap { $0.name?.components(separatedBy: ".").first }
                            .filter { !$0.hasPrefix("Pods_") } ?? []
                        promise(.success([name: products]))
                    }
                    .eraseToAnyPublisher()
                }
            }
            .eraseToAnyPublisher()
    }

    internal func missingProducts() -> AnyPublisher<[String], Error> {
        return productNames()
            .flatMap { $0.flatMap(\.value).publisher }
            .flatMap { product -> AnyPublisher<String, Error> in
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
            .collect()
            .eraseToAnyPublisher()
    }



    internal func build(target: String, in project: String, for sdk: Xcodebuild.SDK, derivedDataPath: Path) throws {

        log.info("🏗  Building \(target)-\(sdk.rawValue)...")

        let buildSettings: [String: String] = [
            "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
            "SKIP_INSTALL": "NO",
            "ENABLE_BITCODE": "NO",
            "INSTALL_PATH": "/Library/Frameworks"
        ]

        let archivePath = Config.current.buildPath + "\(target)-\(sdk.rawValue).xcarchive"
        let command = Xcodebuild(
            command: .archive,
            project: project,
            target: target,
            archivePath: archivePath.string,
            derivedDataPath: derivedDataPath.string,
            sdk: sdk,
            additionalBuildSettings: buildSettings
        )

        workingPath.chdir {
            command.run()
        }
    }


    internal func downloadOrBuildTarget(named targetName: String, to destinationPath: Path, sdks: [Xcodebuild.SDK], derivedDataPath: Path, skipClean: Bool, force: Bool) -> AnyPublisher<Path, Error> {
        guard case .package(let manifest) = description else {
            log.fatal("Target specifier is only supported for Swift packages.")
        }

        let target = manifest.targets.first { $0.name == targetName }

        if let urlString = target?.url,
              let url = URL(string: urlString),
              let checksum = target?.checksum,
              target?.type == .binary {

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

                let zipPath = self.compressedPath(for: targetName)

                try zipPath.write(data)

                return zipPath
            }
            .eraseToAnyPublisher()
        } else if let path = target?.path, target?.type == .binary {
            return Future.try { promise in
                let frameworkPath = self.path + path

                if destinationPath.exists {
                    try destinationPath.delete()
                }

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
        packageContents.insert(contentsOf: ".library(name: \"\(product)\", \(dynamic ? "type: .dynamic, " : "")targets: [\((targets ?? [product]).map { "\"\($0)\"" }.joined(separator: ", "))]),\n", at: allProductMatches.first!.range.lowerBound)
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
        case download(URL)
        case cocoapod(String)

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
        case url(name: String, url: URL, version: String)
        case cocoapod(String, String)

        var name: String {
            switch self {
            case .package(let manifest): return manifest.name
            case .project(let project): return project.name
            case .url(let name, _, _): return name
            case .cocoapod(let name, _): return name
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

        func getBuildables() -> [Package.Buildable] {
            if let products = Config.current.packages?[name]?.products {
                return products.map { .init($0) }
            } else {
                switch self {
                case .package(let manifest):
                    return [.scheme(manifest.name)]
                case .project(let project):
                    return [.project(project.path, scheme: project.name)]
                case .url(_, let url, _):
                    return [.download(url)]
                case .cocoapod(let name, _):
                    return [.cocoapod(name)]
                }
            }
        }
    }
}



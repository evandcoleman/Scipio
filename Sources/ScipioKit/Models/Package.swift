import Foundation
import PathKit
import Regex

public struct Package {

    public let path: Path
    public let description: Description
    public let productNames: [String]
    public let buildables: [Buildable]

    public var name: String { description.name }

    public init(path: Path) throws {
        self.path = path.isFile ? path.parent() : path
        let description = try Description(path: path)
        self.description = description
        self.productNames = try description.getProductNames()
        self.buildables = description.getBuildables()
    }

    internal func preBuild() throws {
        // Xcodebuild doesn't provide an option for specifying a Package.swift
        // file to build from and if there's an xcodeproj in the same directory
        // it will favor that. So we need to hide them from xcodebuild
        // temporarily while we build.
        try path.glob("*.xcodeproj").forEach { try $0.move($0.parent() + "\($0.lastComponent).bak") }
        try path.glob("*.xcworkspace").forEach { try $0.move($0.parent() + "\($0.lastComponent).bak") }
    }

    internal func postBuild() throws {
        try path.glob("*.xcodeproj.bak").forEach { try $0.move($0.parent() + "\($0.lastComponentWithoutExtension).xcodeproj") }
        try path.glob("*.xcworkspace.bak").forEach { try $0.move($0.parent() + "\($0.lastComponentWithoutExtension).xcworkspace") }
        
        path.chdir {
            sh("git checkout .").waitUntilExit()
        }
    }

    internal func createXCFramework(scheme: String, sdks: [Xcodebuild.SDK], skipIfExists: Bool) {
        let buildDirectory = Config.current.buildPath
        let firstArchivePath = buildDirectory + "\(scheme)-\(sdks[0].rawValue).xcarchive"
        let frameworkPaths = (firstArchivePath + "Products/Library/Frameworks").glob("*.framework")

        for frameworkPath in frameworkPaths {
            let productName = frameworkPath.lastComponentWithoutExtension
            let frameworks = sdks
                .map { buildDirectory + "\(scheme)-\($0.rawValue).xcarchive/Products/Library/Frameworks/\(productName).framework" }
            let output = buildDirectory + "\(productName).xcframework"

            if skipIfExists, output.exists {
                print("⏭  Skipping creating XCFramework for #{product_name}...")
                continue
            }

            print("📦  Creating #{product_name}.xcframework...")

            let command = Xcodebuild(
                command: .createXCFramework,
                additionalArguments: frameworks
                    .map { "-framework \($0)" } + ["-output \(output)"]
            )
            command.run()
        }
    }

    internal func forceDynamicFrameworkProduct(scheme: String) {
        path.chdir {
            // We need to rewrite Package.swift to force build a dynamic framework
            // https://forums.swift.org/t/how-to-build-swift-package-as-xcframework/41414/4
            sh(#"perl -i -p0e 's/(\.library\\([\\n\\r\\s]*name\\s?:\\s\"\#(scheme)\"[^,]*,)[^,]*type: \.static[^,]*,/$1/g' Package.swift"#).waitUntilExit()
            sh(#"perl -i -p0e 's/(\.library\\([\\n\\r\\s]*name\\s?:\\s\"\#(scheme)\"[^,]*,)[^,]*type: \.dynamic[^,]*,/$1/g' Package.swift"#).waitUntilExit()
            sh(#"perl -i -p0e 's/(\.library\\([\\n\\r\\s]*name\\s?:\\s\"\#(scheme)\"[^,]*,)/$1 type: \.dynamic,/g' Package.swift"#).waitUntilExit()
        }
    }

    internal func copyModulesAndHeaders(project: Path? = nil, scheme: String, sdk: Xcodebuild.SDK, archivePath: Path, derivedDataPath: Path) throws {
        // https://forums.swift.org/t/how-to-build-swift-package-as-xcframework/41414/4
        let frameworksPath = archivePath + "Products/Library/Frameworks"

        for frameworkPath in frameworksPath.glob("*.framework") {
            let frameworkName = frameworksPath.lastComponentWithoutExtension
            let modulesPath = frameworksPath + "Modules"
            let headersPath = frameworksPath + "Headers"
            let projectName = project == nil ? nil : scheme

            if project == nil {
                try modulesPath.mkdir()
            }

            let archiveIntermediatesPath = derivedDataPath + "Build/Intermediates.noindex/ArchiveIntermediates/\(projectName ?? frameworkName)"
            let buildProductsPath = archiveIntermediatesPath + "BuildProductsPath"
            let releasePath = buildProductsPath + "Release-\(sdk.rawValue)"
            let swiftModulePath = releasePath + "\(frameworkName).swiftmodule"
            let resourcesBundlePath = releasePath + "\(frameworkName)_\(frameworkName).bundle"

            if swiftModulePath.exists, project == nil {
                // Swift projects
                sh("cp -r \(swiftModulePath) \(modulesPath)")
                    .waitUntilExit()
            } else {
                // Objective-C projects
                let moduleMapDirectory = archiveIntermediatesPath + "IntermediateBuildFilesPath/\(projectName ?? frameworkName).build/Release-\(sdk.rawValue)/\(frameworkName).build"
                let moduleMapPath = moduleMapDirectory.glob("*.modulemap").first
                var moduleMapContent = "module \(frameworkName) { export * }"

                if let moduleMapPath = moduleMapPath, moduleMapPath.exists {
                    let umbrellaHeaderRegex = Regex(#"umbrella (?:header )?"(.*)""#)
                    let umbrellaHeaderMatch = umbrellaHeaderRegex.firstMatch(in: try modulesPath.read())

                    if let match = umbrellaHeaderMatch, match.captures.count > 1,
                       let umbrellaHeaderPathString = match.captures[1] {

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
                                .replacingFirst(matching: #"^#import "(.*).h""#, with: "#import <\(frameworkName)/$1.h>")
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

                    for target in (targets + dependencies) {
                        guard let publicHeadersPathString = target.publicHeadersPath else { continue }

                        var publicHeadersPath = Path(publicHeadersPathString)

                        if let path = target.path {
                            publicHeadersPath = Path(path) + publicHeadersPath
                        }

                        let headers = (self.path + publicHeadersPath).glob("/**/*.h")

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

    private func getHeaders(in header: Path, frameworkName: String, sourceHeadersDirectory: Path, allHeaders: [Path] = []) throws -> [Path] {
        guard header.exists else { return [] }

        let localHeaderRegex = Regex(#"^#import "(.*)\.h""#)
        let frameworkHeaderRegex = try Regex(string: #"^#import <\#(frameworkName)\/(.*)\.h>"#)

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
            if path.isDirectory, path.contains("Package.swift") {
                let decoder = JSONDecoder()
                let data = sh("swift package dump-package --package-path \(path.string)")
                    .waitForOutput()
                self = .package(try decoder.decode(Manifest.self, from: data))
            } else if path.isFile, path.extension == "xcodeproj" {
                self = .project(try .init(path: path))
            } else {
                fatalError("Unexpected package path \(path.string)")
            }
        }

        func getProductNames() throws -> [String] {
            let package = Config.current.packages[name]

            switch self {
            case .package(let manifest):
                if let products = package?.products {
                    return products.map(\.name)
                } else {
                    return manifest.products.map(\.name)
                }
            case .project(let project):
                return try project.productNames(config: package)
            }
        }

        func getBuildables() -> [Package.Buildable] {
            if let products = Config.current.packages[name]?.products {
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
    }

    struct TargetDependency: Codable {
        let byName: [String?]?
        let product: [String?]?
        let target: [String?]?

        var names: [String] {
            return [byName, product, target]
                .compactMap { $0 }
                .flatMap { $0 }
                .compactMap { $0 }
        }
    }

    enum TargetType: String, Codable {
        case binary = "binary"
        case regular = "regular"
        case test = "test"
    }
}

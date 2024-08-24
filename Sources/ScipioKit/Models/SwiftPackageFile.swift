import Foundation
import PathKit

import Basics
import PackageLoading
import PackageModel
import TSCBasic
import Workspace

public struct SwiftPackageFile {
    public var name: String
    public var path: Path
    public var platforms: [Platform: String]
    public var products: [Product] = []
    public var targets: [Target] = []
    public var dependencies: [PackageModel.PackageDependency] = []

    public var artifacts: [CachedArtifact]
    public var removeMissing: Bool

    private let observabilityScope: ObservabilityScope

    public init(
        name: String,
        path: Path,
        platforms: [Platform: String],
        artifacts: [CachedArtifact] = [],
        removeMissing: Bool
    ) throws {
        self.name = name
        self.path = path.lastComponent == "Package.swift" ? path : path + "Package.swift"
        self.platforms = platforms
        self.artifacts = artifacts
        self.removeMissing = removeMissing
        self.observabilityScope = log.observabilityScope("SwiftPackageFile (\(name)")

        try read()
    }

    public func needsWrite(relativeTo: Path) -> Bool {
        let existing: String? = try? path.read()

        return existing != asString(relativeTo: relativeTo)
    }

    public mutating func read() throws {
        let manifest = try readManifest()
        var artifactsAndTargets: [(name: String, artifact: CachedArtifact?, target: Target?)] = manifest?
            .targets
            .compactMap { target -> (String, CachedArtifact?, Target?)? in
                if let artifact = artifacts.first(where: { $0.name == target.name }) {
                    return (artifact.name, artifact, nil)
                } else if !removeMissing {
                    return (target.name, nil, Target(target))
                } else {
                    return nil
                }
            } ?? artifacts.map { ($0.name, $0, nil) }

        if let targets = manifest?.targets.map(\.name) {
            for artifact in artifacts where !targets.contains(artifact.name) {
                artifactsAndTargets <<< (artifact.name, artifact, nil)
            }
        }

        let sortedArtifacts = artifactsAndTargets
            .sorted { $0.name < $1.name }

        dependencies = manifest?.dependencies ?? []

        products = sortedArtifacts
            .map { Product(name: $0.name, targets: [$0.name]) }

        targets = try sortedArtifacts
            .map { name, artifact, target in
                if let artifact = artifact {
                    if let checksum = artifact.checksum {
                        return Target(
                            name: name,
                            url: artifact.url,
                            checksum: checksum
                        )
                    } else if let checksum = manifest?.targets.first(where: { $0.name == name })?.checksum {
                        return Target(
                            name: name,
                            url: artifact.url,
                            checksum: checksum
                        )
                    } else if artifact.url.isFileURL {
                        return Target(
                            name: name,
                            url: artifact.url,
                            checksum: nil
                        )
                    } else {
                        let existingPath = Config.current.buildPath + "Archives" + name + "\(name).xcframework.zip"

                        if existingPath.exists {
                            return Target(name: name, url: artifact.url, checksum: try existingPath.checksum(.sha256))
                        }

                        fatalError("Missing checksum for \(artifact.name)")
                    }
                } else if let target = target {
                    return target
                } else {
                    fatalError("missing target and artifact")
                }
            }
    }

    public func write(relativeTo: Path) throws {
        try path.write(asString(relativeTo: relativeTo))
    }

    private func readManifest() throws -> Manifest? {
        guard path.exists else { return nil }

        let parentPath = try AbsolutePath(validating: path.parent().string)
        let toolchain = try UserToolchain(destination: try .hostDestination())
        let loader = ManifestLoader(toolchain: toolchain)
        let workspace = try Workspace(forRootPackage: parentPath, customManifestLoader: loader)
        return try tsc_await {
            workspace.loadRootManifest(
                at: parentPath,
                observabilityScope: observabilityScope,
                completion: $0
            )
        }
    }

    func asString(relativeTo: Path) -> String {
        #if swift(>=5.9)
        let swiftToolsVersion = "5.9"
        #else
        let swiftToolsVersion = "5.7"
        #endif
        return """
// swift-tools-version: \(swiftToolsVersion)
import PackageDescription

let package = Package(
    name: "\(name)",
    platforms: [
        \(platforms
            .map { $0.key.asPackagePlatformString(version: $0.value) }
            .joined(separator: ",\n\(8.spaces)"))
    ],
    products: [
\(products
    .map { $0.asString(indenting: 8.spaces) }
    .joined(separator: ",\n"))
    ],
    dependencies: [
\(dependencies
    .map { $0.asString(indenting: 8.spaces) }
    .joined(separator: ",\n"))
    ],
    targets: [
\(targets
    .map { $0.asString(indenting: 8.spaces, relativeTo: relativeTo) }
    .joined(separator: ",\n"))
    ]
)
"""
    }
}

extension SwiftPackageFile {
    public struct Product {
        public var name: String
        public var targets: [String]

        func asString(indenting: String) -> String {
            let targetsString = targets
                .map { "\"\($0)\"" }
                .joined(separator: ", ")

            return #"\#(indenting).library(name: "\#(name)", targets: [\#(targetsString)])"#
        }
    }

    public struct Target {
        public var name: String
        public var dependencies: [Dependency]
        public var url: URL?
        public var checksum: String?

        public struct Dependency {
            public var name: String
            public var package: String

            func asString(indenting: String) -> String {
                return #"\#(indenting).product(name: "\#(name)", package: "\#(package)")"#
            }
        }

        public init(_ target: TargetDescription) {
            name = target.name
            checksum = target.checksum
            dependencies = target.dependencies
                .map { dependency in
                    return .init(
                        name: dependency.name,
                        package: dependency.package ?? dependency.name
                    )
                }

            if let urlString = target.url, let url = URL(string: urlString) {
                self.url = url
            } else if let path = target.path {
                self.url = URL(fileURLWithPath: path)
            } else {
                self.url = nil
            }
        }

        public init(name: String, url: URL, checksum: String?) {
            self.name = name
            self.url = url
            self.checksum = checksum
            self.dependencies = []
        }

        public init(name: String, dependencies: [Dependency]) {
            self.name = name
            self.url = nil
            self.checksum = nil
            self.dependencies = dependencies
        }

        func asString(indenting: String, relativeTo: Path) -> String {
            if let url, url.isFileURL {
                return """
\(indenting).binaryTarget(
\(indenting)    name: "\(name)",
\(indenting)    path: "\(url.path.replacingOccurrences(of: relativeTo.string, with: "").trimmingCharacters(in: .init(charactersIn: "/")))"
\(indenting))
"""
            } else if let url {
                return """
\(indenting).binaryTarget(
\(indenting)    name: "\(name)",
\(indenting)    url: "\(url.absoluteString)",
\(indenting)    checksum: "\(checksum!)"
\(indenting))
"""
            } else {
                return """
\(indenting).target(
\(indenting)    name: "\(name)",
\(indenting)    dependencies: [
\(dependencies
    .map { $0.asString(indenting: indenting + 8.spaces) }
    .joined(separator: ",\n"))
\(indenting)    ]
\(indenting))
"""
            }
        }
    }
}

extension PackageModel.PackageDependency {

    func asString(indenting: String) -> String {
        guard 
            case .sourceControl(let sourceControl) = self,
            case .remote(let url) = sourceControl.location
        else { return "" }

        return #"\#(indenting).package(url: "\#(url.absoluteString)", \#(sourceControl.requirement.asString()))"#
    }
}

extension PackageModel.PackageDependency.SourceControl.Requirement {

    func asString() -> String {
        switch self {
        case .exact(let version):
            return "exact: \"\(version.description)\""
        case .range(let range):
            return "from: \"\(range.lowerBound.description)\""
        case .revision(let string):
            return "revision: \"\(string)\""
        case .branch(let string):
            return "branch: \"\(string)\""
        }
    }
}

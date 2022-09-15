import Foundation
import PathKit

public struct SwiftPackageFile {
    public var name: String
    public var path: Path
    public var platforms: [Platform: String]
    public var products: [Product] = []
    public var targets: [Target] = []

    public var artifacts: [CachedArtifact]
    public var removeMissing: Bool

    public init(name: String, path: Path, platforms: [Platform: String], artifacts: [CachedArtifact], removeMissing: Bool) throws {
        self.name = name
        self.path = path.lastComponent == "Package.swift" ? path : path + "Package.swift"
        self.platforms = platforms
        self.artifacts = artifacts
        self.removeMissing = removeMissing

        try read()
    }

    public func needsWrite(relativeTo: Path) -> Bool {
        let existing: String? = try? path.read()

        return existing != asString(relativeTo: relativeTo)
    }

    public mutating func read() throws {
        let manifest = path.exists ? try PackageManifest.load(from: path.parent()) : nil
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
                        let existingPath = Config.current.buildPath + "\(name).xcframework.zip"

                        if existingPath.exists {
                            return Target(name: name, url: artifact.url, checksum: try existingPath.checksum(.sha256))
                        }

                        fatalError("Missing checksum for \(artifact.name)")
                    }
                } else if let target = target {
                    return target
                } else {
                    fatalError()
                }
            }
    }

    public func write(relativeTo: Path) throws {
        try path.write(asString(relativeTo: relativeTo))
    }

    func asString(relativeTo: Path) -> String {
        return """
// swift-tools-version: 5.6
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
        public var url: URL
        public var checksum: String?

        public init(_ target: PackageManifest.Target) {
            name = target.name
            checksum = target.checksum

            if let urlString = target.url, let url = URL(string: urlString) {
                self.url = url
            } else if let path = target.path {
                self.url = URL(fileURLWithPath: path)
            } else {
                fatalError()
            }
        }

        public init(name: String, url: URL, checksum: String?) {
            self.name = name
            self.url = url
            self.checksum = checksum
        }

        func asString(indenting: String, relativeTo: Path) -> String {
            if url.isFileURL {
                return """
\(indenting).binaryTarget(
\(indenting)    name: "\(name)",
\(indenting)    path: "\(url.path.replacingOccurrences(of: relativeTo.string, with: "").trimmingCharacters(in: .init(charactersIn: "/")))"
\(indenting))
"""
            } else {
                return """
\(indenting).binaryTarget(
\(indenting)    name: "\(name)",
\(indenting)    url: "\(url.absoluteString)",
\(indenting)    checksum: "\(checksum!)"
\(indenting))
"""
            }
        }
    }
}

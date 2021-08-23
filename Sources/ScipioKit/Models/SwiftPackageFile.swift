import Foundation
import PathKit

public struct SwiftPackageFile {
    var name: String
    var path: Path
    var platforms: [Platform: String]
    var products: [Product]
    var targets: [Target]

    public init(name: String, path: Path, platforms: [Platform: String], artifacts: [CachedArtifact]) throws {
        self.name = name
        self.path = path + "Package.swift"
        self.platforms = platforms

        let manifest = path.exists ? try? PackageManifest.load(from: path) : nil
        let sortedArtifacts = artifacts
            .sorted { $0.name < $1.name }

        products = sortedArtifacts
            .map { Product(name: $0.name, targets: [$0.name]) }

        targets = sortedArtifacts
            .map { artifact in
                if let checksum = artifact.checksum {
                    return Target(
                        name: artifact.name,
                        url: artifact.url,
                        checksum: checksum
                    )
                } else if let checksum = manifest?.targets.first(where: { $0.name == artifact.name })?.checksum {
                    return Target(
                        name: artifact.name,
                        url: artifact.url,
                        checksum: checksum
                    )
                } else if artifact.url.isFileURL {
                    return Target(
                        name: artifact.name,
                        url: artifact.url,
                        checksum: nil
                    )
                } else {
                    fatalError("Missing checksum for \(artifact.name)")
                }
            }
    }

    public func write() throws {
        try path.write(asString())
    }

    func asString() -> String {
        return """
// swift-tools-version:5.3
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
    .map { $0.asString(indenting: 8.spaces) }
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

        func asString(indenting: String) -> String {
            if url.isFileURL {
                return """
\(indenting).binaryTarget(
\(indenting)    name: "\(name)",
\(indenting)    path: "\(url.path)"
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

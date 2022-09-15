import Foundation
import PathKit
import ProjectSpec

public protocol Dependency: Decodable, Equatable {
    var name: String { get }
}

public struct BinaryDependency: Dependency, DependencyProducts {
    public let name: String
    public let url: URL
    public let version: String
    public let excludes: [String]?

    public var productNames: [String]? {
        let names = try? productNamesCachePath.read()
            .components(separatedBy: ",")
            .filter { !$0.isEmpty }
            .nilIfEmpty

        if let excludes = excludes {
            return names?
                .filter { !excludes.contains($0) }
        }

        return names
    }

    public var productNamesCachePath: Path {
        return Config.current.cachePath + ".binary-products-\(name)-\(version)"
    }

    public func version(for productName: String) -> String {
        return version
    }

    public func cache(_ productNames: [String]) throws {
        if productNames.filter(\.isEmpty).isEmpty {
            try productNamesCachePath.write(productNames.joined(separator: ","))
        }
    }
}

public struct CocoaPodDependency: Dependency {
    public let name: String
    public let version: String?
    public let from: String?
    public let git: URL?
    public let branch: String?
    public let commit: String?
    public let podspec: URL?
    public let excludes: [String]?
    public let additionalBuildSettings: [String: String]?
}

public struct PackageDependency: Dependency {
    public let name: String
    public let url: URL
    public let from: String?
    public let revision: String?
    public let branch: String?
    public let exactVersion: String?
    public let version: String?
    public let additionalBuildSettings: [String: String]?

    public var versionRequirement: SwiftPackage.VersionRequirement {
        if let from = from {
            return .upToNextMajorVersion(from)
        } else if let revision = revision {
            return .revision(revision)
        } else if let branch = branch {
            return .branch(branch)
        } else if let exactVersion = exactVersion ?? version {
            return .exact(exactVersion)
        } else {
            fatalError("Unsupported package version requirement")
        }
    }
}

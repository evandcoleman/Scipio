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
        return try? productNamesCachePath.read()
            .components(separatedBy: ",")
    }

    public var productNamesCachePath: Path {
        return Config.current.cachePath + ".binary-products-\(name)-\(version)"
    }

    public func version(for productName: String) -> String {
        return version
    }

    public func cache(_ productNames: [String]) throws {
        try productNamesCachePath.write(productNames.joined(separator: ","))
    }
}

public struct CocoaPodDependency: Dependency {
    public let name: String
    public let version: String?
    public let from: String?
    public let git: URL?
}

public struct PackageDependency: Dependency {
    public let name: String
    public let url: URL
    public let from: String?
    public let revision: String?
    public let branch: String?
    public let exactVersion: String?

    public var versionRequirement: SwiftPackage.VersionRequirement {
        if let from = from {
            return .upToNextMajorVersion(from)
        } else if let revision = revision {
            return .revision(revision)
        } else if let branch = branch {
            return .branch(branch)
        } else if let exactVersion = exactVersion {
            return .exact(exactVersion)
        } else {
            fatalError("Unsupported package version requirement")
        }
    }
}

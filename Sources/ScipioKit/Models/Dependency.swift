import Foundation
import ProjectSpec

public protocol Dependency: Decodable, Equatable {
    var name: String { get }
}

public struct BinaryDependency: Dependency, DependencyProducts {
    public let name: String
    public let url: URL
    public let version: String
    public let excludes: [String]?

    public var productNames: [String]? { nil }
}

public struct CocoaPodDependency: Dependency {
    public let name: String
    public let version: String?

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            version = try? container.decode(String.self, forKey: .version)
        } catch {
            let container = try decoder.singleValueContainer()
            name = try container.decode(String.self)
            version = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case version
    }
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

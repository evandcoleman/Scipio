import Foundation
import PackageModel
import PathKit

public protocol Dependency: NamedDependency, Codable, Equatable {}

public struct BinaryDependency: DownloadDependency, Hashable {
    public let name: String
    public let url: URL
    public let version: String?
    public let excludes: [String]?
    public let products: [String]?
}

public struct GithubReleaseDependency: DownloadDependency, Hashable {
    public let repo: String
    public let version: String?
    public let filename: String
    public let excludes: [String]?
    public let products: [String]?

    public var name: String {
        return repo.components(separatedBy: "/").last ?? repo
    }
}

public struct PackageDependency: Dependency {
    public let name: String
    public let url: URL
    public let from: String?
    public let revision: String?
    public let branch: String?
    public let exactVersion: String?
    public let version: String?
    public let excludes: [String]?
    public let additionalBuildSettings: [String: String]?
    public let useLibraryEvolution: Bool?
    public let products: [String]?

    public var versionRequirement: PackageModel.PackageDependency.SourceControl.Requirement {
        if let from {
            return .range(.upToNextMajor(from: .init(stringLiteral: from)))
        } else if let revision {
            return .revision(revision)
        } else if let branch {
            return .branch(branch)
        } else if let exactVersion = exactVersion ?? version {
            return .exact(.init(stringLiteral: exactVersion))
        } else {
            fatalError("Unsupported package version requirement")
        }
    }
}

import Workspace

extension PackageDependency {

    var checkoutState: CheckoutState {
        if let from {
            return .version(.init(stringLiteral: from), revision: .init(identifier: from))
        } else if let revision {
            return .revision(.init(identifier: revision))
        } else if let branch {
            return .branch(name: branch, revision: .init(identifier: branch))
        } else if let exactVersion = exactVersion ?? version {
            return .version(.init(stringLiteral: exactVersion), revision: .init(identifier: exactVersion))
        } else {
            fatalError("Unsupported package version requirement")
        }
    }

    var resolvedRevision: String {
        if let from {
            return from
        } else if let revision {
            return revision
        } else if let branch {
            return branch
        } else if let exactVersion = exactVersion ?? version {
            return exactVersion
        } else {
            fatalError("Unsupported package version requirement")
        }
    }
}

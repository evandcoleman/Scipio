import Foundation
import PackageModel
import PathKit
import XcodeProj

import struct TSCUtility.Version

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
    public let versionRequirement: VersionRequirement
    public let excludes: [String]?
    public let additionalBuildSettings: [String: String]?
    public let useLibraryEvolution: Bool?
    public let products: [String]?

    public enum VersionRequirement: Codable, Equatable {
        case upToNextMajorVersion(String)
        case upToNextMinorVersion(String)
        case range(from: String, to: String)
        case exact(String)
        case branch(String)
        case revision(String)

        enum CodingKeys: String, CodingKey {
            case revision
            case branch
            case minimumVersion
            case maximumVersion
            case version
            case exactVersion
            case from
        }

        internal init(_ versionRequirement: XCRemoteSwiftPackageReference.VersionRequirement) {
            switch versionRequirement {
            case let .revision(revision):
                self = .revision(revision)
            case let .branch(branch):
                self = .branch(branch)
            case let .exact(version):
                self = .exact(version)
            case let .range(from, to):
                self = .range(from: from, to: to)
            case let .upToNextMinorVersion(version):
                self = .upToNextMinorVersion(version)
            case let .upToNextMajorVersion(version):
                self = .upToNextMajorVersion(version)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if container.contains(.revision) {
                let revision = try container.decode(String.self, forKey: .revision)
                self = .revision(revision)
            } else if container.contains(.branch) {
                let branch = try container.decode(String.self, forKey: .branch)
                self = .branch(branch)
            } else if container.contains(.exactVersion) {
                let version = try container.decode(String.self, forKey: .exactVersion)
                self = .exact(version)
            } else if container.contains(.version) {
                let version = try container.decode(String.self, forKey: .version)
                self = .exact(version)
            } else if container.contains(.minimumVersion), container.contains(.maximumVersion) {
                let minimumVersion = try container.decode(String.self, forKey: .minimumVersion)
                let maximumVersion = try container.decode(String.self, forKey: .maximumVersion)
                self = .range(from: minimumVersion, to: maximumVersion)
            } else if container.contains(.minimumVersion) {
                let version = try container.decode(String.self, forKey: .minimumVersion)
                self = .upToNextMinorVersion(version)
            } else if container.contains(.from) {
                let version = try container.decode(String.self, forKey: .from)
                self = .upToNextMajorVersion(version)
            } else {
                fatalError("VersionRequirement not supported")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case .upToNextMajorVersion(let version):
                try container.encode(version, forKey: .from)
            case .upToNextMinorVersion(let version):
                try container.encode(version, forKey: .minimumVersion)
            case .range(let fromVersion, let toVersion):
                try container.encode(fromVersion, forKey: .minimumVersion)
                try container.encode(toVersion, forKey: .maximumVersion)
            case .exact(let version):
                try container.encode(version, forKey: .exactVersion)
            case .branch(let branch):
                try container.encode(branch, forKey: .branch)
            case .revision(let revision):
                try container.encode(revision, forKey: .revision)
            }
        }
    }

    public var packageVersionRequirement: PackageModel.PackageDependency.SourceControl.Requirement {
        switch versionRequirement {
        case .upToNextMajorVersion(let string):
            return .range(.upToNextMajor(from: .init(stringLiteral: string)))
        case .upToNextMinorVersion(let string):
            return .range(.upToNextMinor(from: .init(stringLiteral: string)))
        case .range(let from, let to):
            return .range(Version(stringLiteral: from)..<Version(stringLiteral: to))
        case .exact(let string):
            return .exact(.init(stringLiteral: string))
        case .branch(let string):
            return .branch(string)
        case .revision(let string):
            return .revision(string)
        }
    }

    internal init(
        name: String,
        url: URL,
        versionRequirement: XCRemoteSwiftPackageReference.VersionRequirement,
        products: [String]? = nil
    ) {
        self.init(
            name: name,
            url: url,
            versionRequirement: .init(versionRequirement),
            products: products
        )
    }

    public init(
        name: String,
        url: URL,
        versionRequirement: VersionRequirement,
        excludes: [String]? = nil,
        additionalBuildSettings: [String : String]? = nil,
        useLibraryEvolution: Bool? = nil,
        products: [String]? = nil
    ) {
        self.name = name
        self.url = url
        self.versionRequirement = versionRequirement
        self.excludes = excludes
        self.additionalBuildSettings = additionalBuildSettings
        self.useLibraryEvolution = useLibraryEvolution
        self.products = products
    }

    public enum CodingKeys: String, CodingKey {
        case name
        case url
        case excludes
        case additionalBuildSettings
        case useLibraryEvolution
        case products
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.name = try container.decode(String.self, forKey: .name)
        self.url = try container.decode(URL.self, forKey: .url)
        self.versionRequirement = try .init(from: decoder)

        self.excludes = try container.decodeIfPresent([String].self, forKey: .excludes)
        self.additionalBuildSettings = try container.decodeIfPresent([String : String].self, forKey: .additionalBuildSettings)
        self.useLibraryEvolution = try container.decodeIfPresent(Bool.self, forKey: .useLibraryEvolution)
        self.products = try container.decodeIfPresent([String].self, forKey: .products)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try versionRequirement.encode(to: encoder)

        try container.encodeIfPresent(excludes, forKey: .excludes)
        try container.encodeIfPresent(additionalBuildSettings, forKey: .additionalBuildSettings)
        try container.encodeIfPresent(useLibraryEvolution, forKey: .useLibraryEvolution)
        try container.encodeIfPresent(products, forKey: .products)
    }
}

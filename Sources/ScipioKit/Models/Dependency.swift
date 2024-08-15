import Foundation
import PackageModel
import PathKit

public protocol Dependency: NamedDependency, Decodable, Equatable {}

public struct BinaryDependency: Dependency {
    public let name: String
    public let url: URL
    public let version: String
    public let excludes: [String]?

    public var products: [ProductVersion] {
        var names = ((try? productNamesCachePath.read()) ?? "")
            .components(separatedBy: ",")
            .filter { !$0.isEmpty }

        if let excludes = excludes {
            names = names
                .filter { !excludes.contains($0) }
        }

        return names
            .map { name in
                return ProductVersion(
                    productName: name,
                    version: version,
                    parentNames: [self.name]
                )
            }
    }

    public var productNamesCachePath: Path {
        return Config.current.buildPath + ".binary-products-\(name)-\(version)"
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
    // Currently, Swift does not support packages that contain a type that is named
    // the same as the package product when built as an .xcframework. The build will
    // succeed but the resulting .swiftinterface file will produce a build error.
    // To get around this, we can allow dynamically renaming products and targets
    // to circumvent the issue.
//    public let productRenameMapping: [String: String]?
//    public let targetRenameMapping: [String: String]?
    // A shortcut to rename a product with the same name as the package
//    public let renamePackageProduct: String?

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

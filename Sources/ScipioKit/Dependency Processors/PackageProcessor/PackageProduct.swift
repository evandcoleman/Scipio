//
//  PackageProduct.swift
//  
//
//  Created by Evan Coleman on 8/23/24.
//

import Foundation
import PackageGraph
import PackageLoading
import PackageModel

public struct PackageProduct: Product {

    public var productName: String
    public var version: String
    public var parentNames: [String]
    public var packageName: String
    public var packageUrl: String

    public var buildable: Buildable

    public var isBinary: Bool {
        switch buildable {
        case .binary:
            return true
        default:
            return false
        }
    }
}

extension PackageProduct {

    public enum Buildable: Equatable, Hashable {
        case target(ResolvedTarget)
        case binary(BinaryArtifact)

        public static func == (lhs: Buildable, rhs: Buildable) -> Bool {
            switch (lhs, rhs) {
            case (.target(let lhs), .target(let rhs)):
                return lhs == rhs
            case (.binary(let lhs), .binary(let rhs)):
                return lhs.kind == rhs.kind
                && lhs.originURL == rhs.originURL
                && lhs.path == rhs.path
            default:
                return false
            }
        }

        public func hash(into hasher: inout Hasher) {
            switch self {
            case .target(let target):
                hasher.combine(target)
            case .binary(let binary):
                hasher.combine(binary.kind)
                hasher.combine(binary.originURL)
                hasher.combine(binary.path)
            }
        }
    }

    init(
        target: ResolvedTarget,
        package: ResolvedPackage,
        version: String?
    ) {
        self.productName = target.name
        self.version = version ?? package.manifest.version?.description ?? "unknown"
        self.parentNames = [package.manifest.displayName]
        self.packageName = package.identity.description
        self.packageUrl = package.manifest.packageLocation
        self.buildable = .target(target)
    }

        init(
            name: String,
            packageUrl: String,
            binary: BinaryArtifact,
            package: PackageIdentity,
            version: String?
        ) {
            self.productName = name
            self.version = version ?? "unknown"
            self.parentNames = [package.description]
            self.packageName = package.description
            self.packageUrl = packageUrl
            self.buildable = .binary(binary)
        }
}

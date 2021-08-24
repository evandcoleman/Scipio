import Foundation
import PathKit

public struct SwiftPackageDescriptor: DependencyProducts {

    public let name: String
    public let version: String
    public let path: Path
    public let manifest: PackageManifest
    public let buildables: [SwiftPackageBuildable]

    public var productNames: [String]? {
        return buildables.map(\.name)
    }

    public init(path: Path, name: String) throws {
        self.name = name
        self.path = path

        var gitPath = path + ".git"

        guard gitPath.exists else {
            log.fatal("Missing git directory for package: \(name)")
        }

        if gitPath.isFile {
            guard let actualPath = (try gitPath.read()).components(separatedBy: "gitdir: ").last?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                log.fatal("Couldn't parse .git file in \(path)")
            }

            gitPath = (gitPath.parent() + Path(actualPath)).normalize()
        }

        let headPath = gitPath + "HEAD"

        guard headPath.exists else {
            log.fatal("Missing HEAD file in \(gitPath)")
        }

        self.version = (try headPath.read())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest: PackageManifest = try .load(from: path)
        self.manifest = manifest
        self.buildables = manifest.getBuildables()
    }

    public func version(for productName: String) -> String {
        return version
    }
}

// MARK: - PackageManifest
public struct PackageManifest: Codable, Equatable {
    public let name: String
    public let products: [Product]
    public let targets: [Target]

    public static func load(from path: Path) throws -> PackageManifest {
        let cachedManifestPath = Config.current.cachePath + "\(path.lastComponent)-\(try (path + "Package.swift").checksum(.sha256)).json"
        let data: Data
        if cachedManifestPath.exists {
            log.verbose("Loading cached Package.swift for \(path.lastComponent)")
            data = try cachedManifestPath.read()
        } else {
            log.verbose("Reading Package.swift for \(path.lastComponent)")
            data = try sh("swift package dump-package --package-path \(path.string)")
                .waitForOutput()
            try cachedManifestPath.write(data)
        }
        let decoder = JSONDecoder()

        return try decoder.decode(PackageManifest.self, from: data)
    }

    public func getBuildables() -> [SwiftPackageBuildable] {
        return products
            .flatMap { getBuildables(in: $0) }
            .uniqued()
    }

    private func getBuildables(in product: Product) -> [SwiftPackageBuildable] {
        let targets = recursiveTargets(in: product)

        if let binaryTarget = targets.first(where: { $0.name == product.name && $0.type == .binary }) {
            return [.binaryTarget(binaryTarget)]
        }

        return targets
            .map { $0.name == product.name && $0.type != .binary ? .scheme($0.name) : .target($0.name) }
    }

    private func recursiveTargets(in product: Product) -> [PackageManifest.Target] {
        return product
            .targets
            .compactMap { target in targets.first { $0.name == target } }
            .flatMap { recursiveTargets(in: $0) }
    }

    private func recursiveTargets(in target: Target) -> [PackageManifest.Target] {
        return [target] + target
            .dependencies
            .flatMap { recursiveTargets(in: $0) }
    }

    private func recursiveTargets(in dependency: TargetDependency) -> [PackageManifest.Target] {
        let byName = dependency.byName?.compactMap { $0?.name }

        return (dependency.target?.compactMap({ $0?.name }) + byName)
            .compactMap { target in targets.first { $0.name == target } }
            .flatMap { recursiveTargets(in: $0) }
    }
}

extension PackageManifest {

    public struct Product: Codable, Equatable, Hashable {
        public let name: String
        public let targets: [String]
    }

    public struct Target: Codable, Equatable, Hashable {
        public let dependencies: [TargetDependency]
        public let name: String
        public let path: String?
        public let publicHeadersPath: String?
        public let type: TargetType
        public let checksum: String?
        public let url: String?
        public let settings: [Setting]?

        public struct Setting: Codable, Equatable, Hashable {
            public let name: Name
            public let value: [String]

            public enum Name: String, Codable, Equatable {
                case define
                case headerSearchPath
                case linkedFramework
                case linkedLibrary
            }
        }
    }

    public struct TargetDependency: Codable, Equatable, Hashable {
        public let byName: [Dependency?]?
        public let product: [Dependency?]?
        public let target: [Dependency?]?

        public var names: [String] {
            return [byName, product, target]
                .compactMap { $0 }
                .flatMap { $0 }
                .compactMap(\.?.name)
        }

        public enum Dependency: Codable, Equatable, Hashable {
            case name(String)
            case constraint(platforms: [String])

            public var name: String? {
                switch self {
                case .name(let name):
                    return name
                case .constraint:
                    return nil
                }
            }

            enum CodingKeys: String, CodingKey {
                case platformNames
            }

            public init(from decoder: Decoder) throws {
                if let container = try? decoder.singleValueContainer(),
                   let stringValue = try? container.decode(String.self) {

                    self = .name(stringValue)
                } else {
                    let container = try decoder.container(keyedBy: CodingKeys.self)

                    self = .constraint(platforms: try container.decode([String].self, forKey: .platformNames))
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .name(let name):
                    var container = encoder.singleValueContainer()
                    try container.encode(name)
                case .constraint(let platforms):
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(platforms, forKey: .platformNames)
                }
            }
        }
    }

    public enum TargetType: String, Codable {
        case binary = "binary"
        case regular = "regular"
        case test = "test"
    }
}

public enum SwiftPackageBuildable: Equatable, Hashable {
    case scheme(String)
    case target(String)
    case binaryTarget(PackageManifest.Target)

    public var name: String {
        switch self {
        case .scheme(let name):
            return name
        case .target(let name):
            return name
        case .binaryTarget(let target):
            if let urlString = target.url, let url = URL(string: urlString) {
                return url.lastPathComponent
                    .components(separatedBy: ".")[0]
            } else if let path = target.path {
                return path.components(separatedBy: ".")[0]
            } else {
                return target.name
            }
        }
    }
}

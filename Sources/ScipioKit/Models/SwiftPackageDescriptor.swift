import Foundation
import PathKit

public struct SwiftPackageDescriptor: DependencyProducts {

    public let name: String
    public let version: String
    public let path: Path
    public let manifest: PackageManifest

    public var productNames: [String]? {
        return manifest.products.map(\.name)
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
        self.manifest = try .load(from: path)
    }
}

// MARK: - PackageManifest
public struct PackageManifest: Codable {
    public let name: String
    public let products: [Product]
    public let targets: [Target]

    public static func load(from path: Path) throws -> PackageManifest {
        let cachedManifestPath = Config.current.cachePath + "\(path.lastComponent)-\(try path.glob("Package.swift")[0].checksum(.sha256)).json"
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
}

extension PackageManifest {

    public struct Product: Codable {
        public let name: String
        public let targets: [String]
    }

    public struct Target: Codable {
        public let dependencies: [TargetDependency]
        public let name: String
        public let path: String?
        public let publicHeadersPath: String?
        public let type: TargetType
        public let checksum: String?
        public let url: String?
        public let settings: [Setting]?

        public struct Setting: Codable {
            public let name: Name
            public let value: [String]

            public enum Name: String, Codable {
                case define
                case headerSearchPath
                case linkedFramework
                case linkedLibrary
            }
        }
    }

    public struct TargetDependency: Codable {
        public let byName: [Dependency?]?
        public let product: [Dependency?]?
        public let target: [Dependency?]?

        public var names: [String] {
            return [byName, product, target]
                .compactMap { $0 }
                .flatMap { $0 }
                .compactMap { dependency in
                    switch dependency {
                    case .name(let name):
                        return name
                    default:
                        return nil
                    }
                }
        }

        public enum Dependency: Codable {
            case name(String)
            case constraint(platforms: [String])

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


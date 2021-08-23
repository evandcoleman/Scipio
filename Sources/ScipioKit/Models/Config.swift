import Foundation
import PathKit
import Yams

public struct Config: Decodable, Equatable {

    public private(set) static var current: Config!

    public let name: String
    public let cacheDelegator: CacheEngineDelegator
    public let binaries: [BinaryDependency]?
    public let packages: [PackageDependency]?
    public let pods: [CocoaPodDependency]?

    public var buildDirectory: String?
    public let deploymentTarget: [String: String]

    public var path: Path { _path }
    public var directory: Path { _path.parent() }

    public var buildPath: Path {
        if let buildDirectory = buildDirectory {
            return Path(buildDirectory)
        } else {
            return Path.current + "build"
        }
    }

    public var platformVersions: [Platform: String] {
        return deploymentTarget
            .reduce(into: [:]) { acc, next in
                if let platform = Platform(rawValue: next.key) {
                    acc[platform] = next.value
                } else {
                    log.fatal("Invalid platform \"\(next.key)\"")
                }
            }
    }

    public let cachePath: Path = {
        let path = Path(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path) + "Scipio"

        if !path.exists {
            try! path.mkdir()
        }

        return path
    }()

    private var _path: Path!

    enum CodingKeys: String, CodingKey {
        case name
        case cacheDelegator = "cache"
        case binaries
        case packages
        case pods
        case buildDirectory
        case deploymentTarget
    }

    public static func setPath(_ path: Path, buildDirectory: String?) {
        let correctedPath = path.isFile ? path : path + "scipio.yml"
        current = readConfig(from: correctedPath)
        current._path = correctedPath
        current.buildDirectory = buildDirectory
    }

    @discardableResult
    public static func readConfig(from path: Path = Path.current + "scipio.yml") -> Config {
        guard path.exists else { log.fatal("Couldn't find config file at path: \(path.string)") }

        do {
            let data = try Data(contentsOf: path.url)
            let decoder = YAMLDecoder()
            var config = try decoder.decode(Config.self, from: data)
            config._path = path
            Config.current = config

            return config
        } catch {
            log.fatal("Error read config file at path \(path): \(error)")
        }
    }
}

extension Config {
    public enum Dependency {}

//    enum Product: Decodable, Equatable {
//        case scheme(String)
//        case target(String)
//
//        var name: String {
//            switch self {
//            case .scheme(let name): return name
//            case .target(let name): return name
//            }
//        }
//
//        init(from decoder: Decoder) throws {
//            do {
//                let container = try decoder.container(keyedBy: CodingKeys.self)
//                self = .target(try container.decode(String.self, forKey: .target))
//            } catch {
//                let container = try decoder.singleValueContainer()
//                self = .scheme(try container.decode(String.self))
//            }
//        }
//
//        enum CodingKeys: String, CodingKey {
//            case target
//        }
//    }
}

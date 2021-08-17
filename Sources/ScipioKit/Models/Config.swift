import Foundation
import PathKit
import Yams

public struct Config: Decodable, Equatable {

    public private(set) static var current: Config!

    let cache: CacheEngineDescriptor
    let packages: [String: Package]?
    let exclude: [String]?

    public var buildDirectory: String?

    public var path: Path { _path }
    public var directory: Path { _path.parent() }

    public var buildPath: Path {
        if let buildDirectory = buildDirectory {
            return Path(buildDirectory)
        } else {
            return Path.current + "build"
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
        case cache
        case packages
        case exclude
        case buildDirectory
    }

    public static func setPath(_ path: Path, buildDirectory: String?) {
        let correctedPath = path.isFile ? path : path + "scipio.yml"
        current = readConfig(from: correctedPath)
        current._path = correctedPath
        current.buildDirectory = buildDirectory
    }

    static func readConfig(from path: Path = Path.current + "scipio.yml") -> Config {
        guard path.exists else { log.fatal("Couldn't find config file at path: \(path.string)") }

        do {
            let data = try Data(contentsOf: path.url)
            let decoder = YAMLDecoder()
            var config = try decoder.decode(Config.self, from: data)
            config._path = path

            return config
        } catch {
            log.fatal("Error read config file at path \(path): \(error)")
        }
    }
}

extension Config {
    struct Package: Decodable, Equatable {
        let products: [Product]
    }

    enum Product: Decodable, Equatable {
        case scheme(String)
        case target(String)

        var name: String {
            switch self {
            case .scheme(let name): return name
            case .target(let name): return name
            }
        }

        init(from decoder: Decoder) throws {
            do {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self = .target(try container.decode(String.self, forKey: .target))
            } catch {
                let container = try decoder.singleValueContainer()
                self = .scheme(try container.decode(String.self))
            }
        }

        enum CodingKeys: String, CodingKey {
            case target
        }
    }
}

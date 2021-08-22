import Foundation
import PathKit
import Yams

public struct Config: Decodable, Equatable {

    public private(set) static var current: Config!

    let name: String
    let cache: CacheEngineDescriptor
    let binaries: [BinaryDependency]?
    let packages: [PackageDependency]?
    let pods: [CocoaPodDependency]?

    public var buildDirectory: String?
    public let deploymentTarget: [String: String]?

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
        case name
        case cache
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

    private struct DynamicCodingKeys: CodingKey {

        let stringValue: String

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        let intValue: Int?

        init?(intValue: Int) {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let mainContainer = try decoder.container(keyedBy: CodingKeys.self)
        let packagesContainer = try? mainContainer.nestedContainer(keyedBy: DynamicCodingKeys.self, forKey: .packages)
        let binariesContainer = try? mainContainer.nestedContainer(keyedBy: DynamicCodingKeys.self, forKey: .packages)
        let podsContainer = try? mainContainer.nestedContainer(keyedBy: DynamicCodingKeys.self, forKey: .packages)

        name = try mainContainer.decode(String.self, forKey: .name)
        cache = try mainContainer.decode(CacheEngineDescriptor.self, forKey: .cache)
        buildDirectory = try? mainContainer.decode(String.self, forKey: .buildDirectory)
        deploymentTarget = try? mainContainer.decode([String: String].self, forKey: .deploymentTarget)

        if let container = packagesContainer {
            packages = try container
                .allKeys
                .map { try container.decode(PackageDependency.self, forKey: DynamicCodingKeys(stringValue: $0.stringValue)!) }
        } else {
            packages = nil
        }
        if let container = binariesContainer {
            binaries = try container
                .allKeys
                .map { try container.decode(BinaryDependency.self, forKey: DynamicCodingKeys(stringValue: $0.stringValue)!) }
        } else {
            binaries = nil
        }
        if let container = podsContainer {
            pods = try container
                .allKeys
                .map { try container.decode(CocoaPodDependency.self, forKey: DynamicCodingKeys(stringValue: $0.stringValue)!) }
        } else {
            pods = nil
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

import Foundation
import PathKit
import Yams

struct Config: Decodable, Equatable {

    static let current: Config = Config.readConfig()

    let packages: [String: Package]

    private let buildDirectory: String?

    var buildPath: Path {
        if let buildDirectory = buildDirectory {
            return Path(buildDirectory)
        } else {
            return Path.current + "build"
        }
    }

    static func readConfig(from path: Path = Path.current + "scipio.yml") -> Config {
        do {
            let data = try Data(contentsOf: path.url)
            let decoder = YAMLDecoder()
            return try decoder.decode(Config.self, from: data)
        } catch {
            print("Error read config file at \(path): \(error)")
            exit(0)
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

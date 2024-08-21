import Foundation
import PathKit
import Yams

public struct Config: Decodable, Equatable {

    public internal(set) static var current: Config!

    public let name: String
    public let cacheDelegator: CacheEngineDelegator
    public let binaries: [BinaryDependency]?
    public let packages: [PackageDependency]?
    public let githubReleases: [GithubReleaseDependency]?

    public var buildDirectory: String?
    public let deploymentTarget: [String: String]

    public var path: Path { _path }
    public var directory: Path { _path.parent() }

    public var buildPath: Path {
        if let buildDirectory = buildDirectory {
            return Path(buildDirectory)
        } else {
            return directory + ".scipio"
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

    public var platforms: [Platform] {
        return Array(platformVersions.keys)
    }

    public var packageRoot: Path {
        if let localCache = cacheDelegator.local {
            return localCache.normalizedPath
        } else {
            return directory
        }
    }

    private var _path: Path!

    public init<Cache: CacheEngine>(
        name: String,
        cache: Cache,
        deploymentTarget: [String: String],
        binaries: [BinaryDependency]? = nil,
        packages: [PackageDependency]? = nil,
        githubReleases: [GithubReleaseDependency]? = nil
    ) {
        self.name = name
        self.cacheDelegator = CacheEngineDelegator(cache: cache)
        self.deploymentTarget = deploymentTarget
        self.binaries = binaries
        self.packages = packages
        self.githubReleases = githubReleases
    }

    enum CodingKeys: String, CodingKey {
        case name
        case cacheDelegator = "cache"
        case binaries
        case packages
        case githubReleases
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

            if !config.buildPath.exists {
                try config.buildPath.mkpath()
            }

            return config
        } catch {
            log.fatal("Error read config file at path \(path): \(error)")
        }
    }

    func getArchivePath() throws -> Path {
        let path = buildPath + "Archives"

        if !path.exists {
            try path.mkpath()
        }

        return path
    }

    func getFrameworkPath(productName: String) throws -> Path {
        return try getArchivePath() + "\(productName).xcframework"
    }

    func getCompressedFrameworkPath(productName: String) throws -> Path {
        return try getArchivePath() + "\(productName).xcframework.zip"
    }

    func getPackagesPath() throws -> Path {
        let path = buildPath + "Packages"

        if !path.exists {
            try path.mkpath()
        }

        return path
    }

    func getPackageCheckoutPath(packageName: String) throws -> Path {
        let path = buildPath + "PackageCheckouts" + packageName

        if !path.exists {
            try path.mkpath()
        }

        return path
    }

//    func getPackageRepositoryPath(for dependency: any NamedDependency) -> Path {
//        return buildPath + "PackageRepositories" + dependency.name
//    }
}

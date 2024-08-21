import Foundation
import PathKit
import Yams

public struct Config: Codable, Equatable {

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

    public init(
        name: String,
        xcodegenConfig: Path
    ) throws {
        let data = try xcodegenConfig.read()
        let decoder = YAMLDecoder()
        let xcodegen = try decoder.decode(XcodeGenConfig.self, from: data)
        let packages = xcodegen
            .packages
            .compactMap { $0.value.makePackage(name: $0.key) }

        self.init(
            name: name,
            cache: LocalCacheEngine(path: .current),
            deploymentTarget: [
                "iOS": "16.0",
            ],
            packages: packages
        )
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

    public func write(to path: Path = Path.current + "scipio.yml") throws {
        let encoder = YAMLEncoder()
        let data = try encoder.encode(self)

        try path.write(data)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(cacheDelegator, forKey: .cacheDelegator)
        try container.encode(binaries, forKey: .binaries)
        try container.encode(packages, forKey: .packages)
        try container.encode(githubReleases, forKey: .githubReleases)
        try container.encode(buildDirectory, forKey: .buildDirectory)
        try container.encode(deploymentTarget, forKey: .deploymentTarget)
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
}

private struct XcodeGenConfig: Decodable {

    var packages: [String: Package]

    struct Package: Decodable {
        var url: String?
        var github: String?
        var majorVersion: String?
        var from: String?
        var minorVersion: String?
        var exactVersion: String?
        var minVersion: String?
        var version: String?
        var maxVersion: String?
        var branch: String?
        var revision: String?

        func makePackage(name: String) -> PackageDependency? {
            guard let resolvedUrl = {
                if let url {
                    return URL(string: url)!
                } else if let github {
                    return URL(string: "https://github.com/\(github)")!
                } else {
                    return nil
                }
            }() else { return nil }

            return PackageDependency(
                name: name,
                url: resolvedUrl,
                from: from ?? minVersion,
                revision: revision,
                branch: branch,
                exactVersion: exactVersion ?? maxVersion,
                version: version,
                excludes: nil,
                additionalBuildSettings: nil,
                useLibraryEvolution: nil,
                products: nil
            )
        }
    }
}

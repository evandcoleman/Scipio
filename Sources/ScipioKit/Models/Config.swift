import Foundation
import PathKit
import XcodeProj
import Yams

public struct Config: Codable, Equatable {

    public internal(set) static var current: Config!

    public static var paths: Paths {
        return current.paths
    }

    public let name: String
    public let cacheDelegator: CacheEngineDelegator
    public let binaries: [BinaryDependency]?
    public let packages: [PackageDependency]?
    public let githubReleases: [GithubReleaseDependency]?

    public var buildDirectory: String?
    public let deploymentTarget: [String: String]

    public var path: Path { _path }
    public var directory: Path { _path.parent() }

    public var paths: Paths {
        return Paths(rootPath: buildPath)
    }

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

    public var allDependencies: [any Dependency] {
        return (binaries ?? [])
            + (packages ?? [])
            + (githubReleases ?? [])
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
        projectPath: Path,
        cache: any CacheEngine
    ) async throws {
        let parentPath = projectPath.parent()
        let project = try XcodeProj(path: projectPath)

        self.init(
            name: name,
            cache: cache,
            deploymentTarget: [
                "iOS": "16.0",
            ],
            binaries: try await BinaryProcessor.readDependencies(from: parentPath, project: project),
            packages: try await PackageProcessor.readDependencies(from: parentPath, project: project), 
            githubReleases: try await GithubReleaseProcessor.readDependencies(from: parentPath, project: project)
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

    @discardableResult
    public mutating func write(to path: Path = Path.current + "scipio.yml") throws -> Path {
        _path = path
        let encoder = YAMLEncoder()
        encoder.options = .init(
            indent: 2,
            width: -1,
            sortKeys: false
        )
        let data = try encoder.encode(self)

        try path.write(data)

        return path
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(deploymentTarget, forKey: .deploymentTarget)
        try container.encodeIfPresent(buildDirectory, forKey: .buildDirectory)
        try container.encode(cacheDelegator, forKey: .cacheDelegator)
        try container.encodeIfPresent(binaries, forKey: .binaries)
        try container.encodeIfPresent(githubReleases, forKey: .githubReleases)
        try container.encodeIfPresent(packages, forKey: .packages)
    }
}

extension Config {

    public struct Paths {

        let rootPath: Path

        func archives() throws -> Path {
            let path = rootPath + "Archives"

            if !path.exists {
                try path.mkpath()
            }

            return path
        }

        func framework(productName: String) throws -> Path {
            return try archives() + "\(productName).xcframework"
        }

        func compressedFramework(productName: String) throws -> Path {
            return try archives() + "\(productName).xcframework.zip"
        }

        func packagesRoot() throws -> Path {
            let path = rootPath + "Packages"

            if !path.exists {
                try path.mkpath()
            }

            return path
        }

        func packageCheckout(packageName: String) throws -> Path {
            let path = rootPath + "PackageCheckouts" + packageName

            if !path.exists {
                try path.mkpath()
            }

            return path
        }
    }
}

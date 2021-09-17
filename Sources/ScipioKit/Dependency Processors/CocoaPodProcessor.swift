import Combine
import Foundation
import PathKit
import ProjectSpec
import Regex
import XcodeGenKit
import XcodeProj

public enum CocoaPodProcessorError: LocalizedError {
    case cocoaPodsNotInstalled
    case missingVersion(CocoaPodDependency)

    public var errorDescription: String? {
        switch self {
        case .cocoaPodsNotInstalled:
            return "CocoaPods must be installed to use CocoaPod dependencies. Please refer to https://cocoapods.org and ensure that the \"pod\" command is available in your PATH."
        case .missingVersion(let dependency):
            return "\(dependency.name) is missing version information from the CocoaPods manifest."
        }
    }
}

public final class CocoaPodProcessor: DependencyProcessor {

    public let dependencies: [CocoaPodDependency]
    public let options: ProcessorOptions

    private var projectPath: Path!

    public init(dependencies: [CocoaPodDependency], options: ProcessorOptions) {
        self.dependencies = dependencies
        self.options = options
    }

    public func preProcess() -> AnyPublisher<[CocoaPodDescriptor], Error> {
        return Future.try {
            let path = Config.current.cachePath + Config.current.name

            _ = try self.writePodfile(in: path)

            return try self.installPods(in: path)
        }
        .eraseToAnyPublisher()
    }

    public func process(_ dependency: CocoaPodDependency?, resolvedTo resolvedDependency: CocoaPodDescriptor) -> AnyPublisher<[AnyArtifact], Error> {
        return Future.try {
            let derivedDataPath = Config.current.cachePath + "DerivedData" + Config.current.name

            var paths = try self.options.platforms.flatMap { platform -> [Path] in
                let archivePaths = try platform.sdks.map { sdk -> Path in
                    let scheme = "\(resolvedDependency.name)-\(platform.rawValue)"

                    if self.options.skipClean, Xcode.getArchivePath(for: scheme, sdk: sdk).exists {
                        return Xcode.getArchivePath(for: scheme, sdk: sdk)
                    }

                    return try Xcode.archive(
                        scheme: scheme,
                        in: self.projectPath.parent() + "\(self.projectPath.lastComponentWithoutExtension).xcworkspace",
                        for: sdk,
                        derivedDataPath: derivedDataPath,
                        additionalBuildSettings: dependency?.additionalBuildSettings
                    )
                }

                return try Xcode.createXCFramework(
                    archivePaths: archivePaths,
                    skipIfExists: self.options.skipClean,
                    filter: { !$0.hasPrefix("Pods_") && $0 != "\(resolvedDependency.name)-\(platform.rawValue)" && resolvedDependency.productNames?.contains($0) == true }
                )
            }

            let vendoredFrameworks = try resolvedDependency
                .vendoredFrameworks
                .map { path -> Path in
                    let targetPath = Config.current.buildPath + path.lastComponent
                    try path.copy(targetPath)

                    return targetPath
                }

            paths <<< vendoredFrameworks

            return paths.compactMap { path in
                return AnyArtifact(Artifact(
                    name: path.lastComponentWithoutExtension,
                    parentName: resolvedDependency.name,
                    version: resolvedDependency.version(for: path.lastComponentWithoutExtension),
                    path: path
                ))
            }
        }
        .eraseToAnyPublisher()
    }

    public func postProcess() -> AnyPublisher<(), Error> {
        return Just(())
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    private func writePodfile(in path: Path) throws -> (podfilePath: Path, projectPath: Path) {
        let podfilePath = path + "Podfile"
        projectPath = path + "\(Config.current.name)-Pods.xcodeproj"

        if projectPath.exists {
            try projectPath.delete()
        }

        let projectGenerator = ProjectGenerator(project: .init(
            basePath: path,
            name: projectPath.lastComponentWithoutExtension,
            targets: dependencies
                .flatMap { dependency in
                    return Config.current.platformVersions
                        .map { Target(name: "\(dependency.name)-\($0.key.rawValue)", type: .framework, platform: .iOS) }
                },
            schemes: dependencies
                .flatMap { dependency in
                    return Config.current.platformVersions
                        .map { Scheme(
                            name: "\(dependency.name)-\($0.key.rawValue)",
                            build: Scheme.Build(targets: [.init(target: .init(name: "\(dependency.name)-\($0.key.rawValue)", location: .local))]),
                            archive: Scheme.Archive(config: "Release")
                        ) }
                }
        ))
        let project = try projectGenerator.generateXcodeProject(in: path)
        try project.write(path: projectPath)

        try podfilePath.write("""
use_frameworks!
project '\(projectPath.string)'

\(dependencies
    .map { dep in Config.current.platformVersions.map { "target '\(dep.name)-\($0.key.rawValue)' do\n\(4.spaces)platform :\($0.key.rawValue), '\($0.value)'\n\(4.spaces)\(dep.asString())\nend" }.joined(separator: "\n\n") }
    .joined(separator: "\n\n"))
""")

        return (podfilePath, projectPath)
    }

    private func installPods(in path: Path) throws -> [CocoaPodDescriptor] {
        let podCommandPath = try which("pod")

        do {
            log.info("🍫  Installing Pods...")

            try sh(podCommandPath, "install", in: path)
                .logOutput()
                .waitUntilExit()
        } catch ShellError.commandNotFound {
            throw CocoaPodProcessorError.cocoaPodsNotInstalled
        } catch ScipioError.commandFailed(_, _, let output, _) where output?.contains("could not find compatible versions") == true {
            try sh(podCommandPath, "install", "--repo-update", in: path)
                .logOutput()
                .waitUntilExit()
        }

        let sandboxPath = path + "Pods"
        let manifestPath = path + "Pods/Manifest.lock"
        let podsProjectPath = sandboxPath + "Pods.xcodeproj"
        let project = try XcodeProj(path: podsProjectPath)
        let lockFile: String = try manifestPath.read()

        return try dependencies.map { dependency in
            let projectProducts = project.productNames(for: dependency.name, podsRoot: sandboxPath)
            let versionRegex = try Regex(string: "- \(dependency.name)\\s\\((.*)\\)")
            let match = versionRegex.firstMatch(in: lockFile)

            guard let version = match?.captures.last??.components(separatedBy: " ").last else {
                throw CocoaPodProcessorError.missingVersion(dependency)
            }

            let versions: [String: String] = try projectProducts
                .map { (product: $0.name, regex: try Regex(string: "- \($0.name)\\s\\((.*)\\)")) }
                .reduce(into: [:]) { $0[$1.product] = $1.regex.firstMatch(in: lockFile)?.captures.last??.components(separatedBy: " ").last ?? version }
            let filteredProductNames = projectProducts
                .map(\.name)
                .filter { dependency.excludes?.contains($0) != true }
            let vendoredFrameworks = projectProducts
                .compactMap { projectProduct -> Path? in
                    switch projectProduct {
                    case .product:
                        return nil
                    case .path(let path):
                        return path
                    }
                }

            return CocoaPodDescriptor(
                name: dependency.name,
                resolvedVersions: versions,
                productNames: filteredProductNames,
                vendoredFrameworks: vendoredFrameworks
            )
        }
    }
}

public struct CocoaPodDescriptor: DependencyProducts {
    public let name: String
    public let resolvedVersions: [String: String]
    public let productNames: [String]?
    public let vendoredFrameworks: [Path]

    public func version(for productName: String) -> String {
        return resolvedVersions[productName]!
    }
}

private extension CocoaPodDependency {
    func asString() -> String {
        var result = "pod '\(name)'"

        if let git = git {
            result += ", :git => '\(git.absoluteString)'"

            if let commit = commit {
                result += ", :commit => '\(commit)'"
            } else if let branch = branch {
                result += ", :branch => '\(branch)'"
            }
        } else if let podspec = podspec {
            result += ", :podspec => '\(podspec.absoluteString)'"
        } else if let version = version {
            result += ", '\(version)'"
        } else if let from = from {
            result += ", '~> \(from)'"
        }

        return result
    }
}

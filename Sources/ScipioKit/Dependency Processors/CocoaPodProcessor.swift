import Combine
import Foundation
import PathKit
import ProjectSpec
import Regex
import XcodeGenKit
import XcodeProj

public enum CocoaPodProcessorError: Error {
    case missingVersion(CocoaPodDependency)
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

            let paths = try self.options.platforms.flatMap { platform -> [Path] in
                let archivePaths = try platform.sdks.map { sdk -> Path in
                    let scheme = "\(resolvedDependency.name)-\(platform.rawValue)"

                    if self.options.skipClean, Xcode.getArchivePath(for: scheme, sdk: sdk).exists {
                        return Xcode.getArchivePath(for: scheme, sdk: sdk)
                    }

                    return try Xcode.archive(
                        scheme: scheme,
                        in: self.projectPath.parent() + "\(self.projectPath.lastComponentWithoutExtension).xcworkspace",
                        for: sdk,
                        derivedDataPath: derivedDataPath
                    )
                }

                return try Xcode.createXCFramework(
                    archivePaths: archivePaths,
                    skipIfExists: self.options.skipClean,
                    filter: { !$0.hasPrefix("Pods_") && $0 != "\(resolvedDependency.name)-\(platform.rawValue)" && resolvedDependency.productNames?.contains($0) == true }
                )
            }

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
        let ruby = try Ruby()
        var podCommandPath = try? which("pod")

        if podCommandPath == nil {
            log.info("🍫  Installing CocoaPods...")

            try ruby.installGem("cocoapods")

            podCommandPath = try which("pod")
        }

        log.info("🍫  Installing Pods...")

        let sandboxPath = path + "Pods"
        let manifestPath = path + "Pods/Manifest.lock"

        try path.chdir {
            try sh(podCommandPath!, "install")
                .logOutput()
                .waitUntilExit()
        }

        let podsProjectPath = sandboxPath + "Pods.xcodeproj"
        let project = try XcodeProj(path: podsProjectPath)
        let lockFile: String = try manifestPath.read()

        return try dependencies.map { dependency in
            let productNames = project.productNames(for: dependency.name)
            let versionRegex = try Regex(string: "- \(dependency.name)\\s\\((.*)\\)")
            let match = versionRegex.firstMatch(in: lockFile)

            guard let version = match?.captures.last??.components(separatedBy: " ").last else {
                throw CocoaPodProcessorError.missingVersion(dependency)
            }

            let versions: [String: String] = try productNames
                .map { (product: $0, regex: try Regex(string: "- \($0)\\s\\((.*)\\)")) }
                .reduce(into: [:]) { $0[$1.product] = $1.regex.firstMatch(in: lockFile)?.captures.last??.components(separatedBy: " ").last ?? version }

            return CocoaPodDescriptor(
                name: dependency.name,
                resolvedVersions: versions,
                productNames: productNames
                    .filter { dependency.excludes?.contains($0) != true }
            )
        }
    }
}

public struct CocoaPodDescriptor: DependencyProducts {
    public let name: String
    public let resolvedVersions: [String: String]
    public let productNames: [String]?

    public func version(for productName: String) -> String {
        return resolvedVersions[productName]!
    }
}

private extension CocoaPodDependency {
    func asString() -> String {
        var result = "pod '\(name)'"

        if let git = git {
            result += ", :git => '\(git)'"
        } else if let version = version {
            result += ", '\(version)'"
        } else if let from = from {
            result += ", '~> \(from)'"
        }

        return result
    }
}

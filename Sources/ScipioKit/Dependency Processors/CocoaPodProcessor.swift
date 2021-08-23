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
        return Future.try { promise in
            let path = Config.current.cachePath + Config.current.name

            _ = try self.writePodfile(in: path)
            let pods = try self.installPods(in: path)

            promise(.success(pods))
        }
        .eraseToAnyPublisher()
    }

    public func process(_ dependency: CocoaPodDependency, resolvedTo resolvedDependency: CocoaPodDescriptor) -> AnyPublisher<[Artifact], Error> {
        return Future.try { promise in
            let derivedDataPath = Config.current.cachePath + "DerivedData" + Config.current.name

            let paths = try self.options.platforms.flatMap { platform -> [Path] in
                let archivePaths = try platform.sdks.map { sdk -> Path in
                    return try Xcode.archive(
                        scheme: "\(resolvedDependency.name)-\(platform.rawValue)",
                        in: self.projectPath.parent() + "\(self.projectPath.lastComponentWithoutExtension).xcworkspace",
                        for: sdk,
                        derivedDataPath: derivedDataPath
                    )
                }

                return try Xcode.createXCFramework(
                    archivePaths: archivePaths,
                    filter: { !$0.hasPrefix("Pods_") && $0 != "\(resolvedDependency.name)-\(platform.rawValue)" }
                )
            }

            promise(.success(paths.compactMap { path in
                return Artifact(
                    name: path.lastComponentWithoutExtension,
                    version: resolvedDependency.resolvedVersion,
                    path: path
                )
            }))
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
    .map { dep in Config.current.platformVersions.map { "target '\(dep.name)-\($0.key.rawValue)' do\n\(4.spaces)platform :\($0.key.rawValue), '\($0.value)'\n\(4.spaces)pod '\(dep.name)'\nend" }.joined(separator: "\n\n") }
    .joined(separator: "\n\n"))
""")

        return (podfilePath, projectPath)
    }

    private func installPods(in path: Path) throws -> [CocoaPodDescriptor] {
        try path.chdir {
            try sh("LANG=en_US.UTF-8 /Users/ecoleman/.rbenv/shims/pod install")
                .logOutput()
                .waitUntilExit()
        }

        let podsProjectPath = path + "Pods/Pods.xcodeproj"
        let project = try XcodeProj(path: podsProjectPath)

        return try dependencies.map { dependency in
            let versionRegex = try Regex(string: "- \(dependency.name)\\s\\((.*)\\)")
            let match = versionRegex.firstMatch(in: try (path + "Podfile.lock").read())

            guard let version = match?.captures.last??.components(separatedBy: " ").last else {
                throw CocoaPodProcessorError.missingVersion(dependency)
            }

            return CocoaPodDescriptor(
                name: dependency.name,
                resolvedVersion: version,
                productNames: project.productNames(for: dependency.name)
            )
        }
    }
}

public struct CocoaPodDescriptor: DependencyProducts {
    public let name: String
    public let resolvedVersion: String
    public let productNames: [String]?

    public var version: String { resolvedVersion }
}

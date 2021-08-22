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

public struct CocoaPodProcessor: DependencyProcessor {

    let dependencies: [CocoaPodDependency]
    let options: ProcessorOptions

    public init(dependencies: [CocoaPodDependency], options: ProcessorOptions) {
        self.dependencies = dependencies
        self.options = options
    }

    public func process() -> AnyPublisher<[Path], Error> {
        return Future.try { promise in
            let path = Config.current.cachePath + Config.current.name
            let derivedDataPath = Config.current.cachePath + "DerivedData" + Config.current.name

            let (podfilePath, projectPath) = try writePodfile(in: path)
            let pods = try installPods(in: path)
            let podsProjectPath = podfilePath.parent() + "Pods/Pods.xcodeproj"
            let project = try XcodeProj(path: podsProjectPath)
            let productNames = project
                .productNames
                .filter { !$0.hasPrefix("Pods_") }

            for sdk in options.platform.sdks {
                try Xcode.archive(
                    scheme: projectPath.lastComponentWithoutExtension,
                    in: projectPath,
                    for: sdk,
                    derivedDataPath: derivedDataPath
                )
            }

            let paths = try Xcode.createXCFramework(
                scheme: projectPath.lastComponentWithoutExtension,
                path: projectPath,
                sdks: options.platform.sdks,
                force: options.forceBuild,
                skipClean: options.skipClean
            )

            promise(.success(paths))
        }
        .eraseToAnyPublisher()
    }

    private func writePodfile(in path: Path) throws -> (podfilePath: Path, projectPath: Path) {
        let podfilePath = path + "Podfile"
        let projectPath = path + "\(Config.current.name)-Pods.xcodeproj"

        if !projectPath.exists {
            let projectGenerator = ProjectGenerator(project: .init(
                basePath: path,
                name: projectPath.lastComponentWithoutExtension,
                targets: [.init(name: projectPath.lastComponentWithoutExtension, type: .framework, platform: .iOS)],
                schemes: [.init(
                    name: projectPath.lastComponentWithoutExtension,
                    build: Scheme.Build(targets: [.init(target: .init(name: projectPath.lastComponentWithoutExtension, location: .local))]),
                    archive: Scheme.Archive(config: "Release")
                )]
            ))
            let project = try projectGenerator.generateXcodeProject(in: path)
            try project.write(path: projectPath)
        }

        try podfilePath.write("""
platform :ios, '12.0'
use_frameworks!
target '\(projectPath.lastComponentWithoutExtension)' do
    \(dependencies.map { "pod '\($0.name)'" })
end
""")

        return (podfilePath, projectPath)
    }

    private func installPods(in path: Path) throws -> [CocoaPodDescriptor] {
        path.chdir {
            sh("LANG=en_US.UTF-8 /Users/ecoleman/.rbenv/shims/pod install")
                .logOutput()
                .waitUntilExit()
        }

        return try dependencies.map { dependency in
            let versionRegex = try Regex(string: "- \(dependency.name)\\s\\((.*)\\)")
            let match = versionRegex.firstMatch(in: try (path + "Podfile.lock").read())

            guard let version = match?.captures.last??.components(separatedBy: " ").last else {
                throw CocoaPodProcessorError.missingVersion(dependency)
            }

            return CocoaPodDescriptor(name: dependency.name, resolvedVersion: version)
        }
    }
}

private struct CocoaPodDescriptor {
    let name: String
    let resolvedVersion: String
}

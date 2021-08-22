import Combine
import Foundation
import PathKit

struct Xcode {
    static func archive(scheme: String, in path: Path, for sdk: Xcodebuild.SDK, derivedDataPath: Path) throws -> Path {
        log.info("🏗  Building \(scheme)-\(sdk.rawValue)...")

        let buildSettings: [String: String] = [
            "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
            "SKIP_INSTALL": "NO",
            "ENABLE_BITCODE": "NO",
            "INSTALL_PATH": "/Library/Frameworks"
        ]

        let archivePath = Config.current.buildPath + "\(scheme)-\(sdk.rawValue).xcarchive"
        let command = Xcodebuild(
            command: .archive,
            workspace: path.extension == "xcworkspace" ? path.string : nil,
            project: path.extension == "xcodeproj" ? path.string : nil,
            scheme: scheme,
            archivePath: archivePath.string,
            derivedDataPath: derivedDataPath.string,
            sdk: sdk,
            additionalBuildSettings: buildSettings
        )

        path.chdir {
            command.run()
        }

        return archivePath
    }

    static func createXCFramework(scheme: String, path: Path, sdks: [Xcodebuild.SDK], force: Bool, skipClean: Bool) throws -> [Path] {
        let buildDirectory = Config.current.buildPath
        let firstArchivePath = buildDirectory + "\(scheme)-\(sdks[0].rawValue).xcarchive"
        let frameworkPaths = (firstArchivePath + "Products/Library/Frameworks")
            .glob("*.framework")

        return try frameworkPaths.compactMap { frameworkPath in
            let productName = frameworkPath.lastComponentWithoutExtension
            let frameworks = sdks
                .map { buildDirectory + "\(scheme)-\($0.rawValue).xcarchive/Products/Library/Frameworks/\(productName).framework" }
            let output = buildDirectory + "\(productName).xcframework"

            if !force, skipClean, output.exists {
                log.info("⏭  Skipping creating XCFramework for \(productName)...")
                return nil
            }

            log.info("📦  Creating \(productName).xcframework...")

            if output.exists {
                try output.delete()
            }

            let command = Xcodebuild(
                command: .createXCFramework,
                additionalArguments: frameworks
                    .map { "-framework \($0)" } + ["-output \(output)"]
            )
            path.chdir {
                command.run()
            }

            return output
        }
    }
}

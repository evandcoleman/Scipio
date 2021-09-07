import Combine
import Foundation
import PathKit

struct Xcode {
    static func getArchivePath(for scheme: String, sdk: Xcodebuild.SDK) -> Path {
        return Config.current.buildPath + "\(scheme)-\(sdk.rawValue).xcarchive"
    }

    static func archive(scheme: String, in path: Path, for sdk: Xcodebuild.SDK, derivedDataPath: Path, sourcePackagesPath: Path? = nil, additionalBuildSettings: [String: String]?) throws -> Path {

        var buildSettings: [String: String] = [
            "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
            "SKIP_INSTALL": "NO",
            "INSTALL_PATH": "/Library/Frameworks"
        ]

        if let additionalBuildSettings = additionalBuildSettings {
            buildSettings.merge(additionalBuildSettings) { l, r in r }
        }

        let archivePath = getArchivePath(for: scheme, sdk: sdk)

        log.info("🏗  Building \(scheme)-\(sdk.rawValue)...")

        let command = Xcodebuild(
            command: .archive,
            workspace: path.extension == "xcworkspace" ? path.string : nil,
            project: path.extension == "xcodeproj" ? path.string : nil,
            scheme: scheme,
            archivePath: archivePath.string,
            derivedDataPath: derivedDataPath.string,
            clonedSourcePackageDirectory: sourcePackagesPath?.string,
            sdk: sdk,
            additionalBuildSettings: buildSettings
        )

        try path.chdir {
            try command.run()
        }

        return archivePath
    }

    static func createXCFramework(archivePaths: [Path], skipIfExists: Bool, filter isIncluded: ((String) -> Bool)? = nil) throws -> [Path] {
        precondition(!archivePaths.isEmpty, "Cannot create XCFramework from zero archives")

        let firstArchivePath = archivePaths[0]
        let buildDirectory = firstArchivePath.parent()
        let frameworkPaths = (firstArchivePath + "Products/Library/Frameworks")
            .glob("*.framework")
            .filter { isIncluded?($0.lastComponentWithoutExtension) ?? true }

        return try frameworkPaths.compactMap { frameworkPath in
            let productName = frameworkPath.lastComponentWithoutExtension
            let frameworks = archivePaths
                .map { $0 + "Products/Library/Frameworks/\(productName).framework" }
            let output = buildDirectory + "\(productName).xcframework"

            if skipIfExists, output.exists {
                return output
            }

            log.info("📦  Creating \(productName).xcframework...")

            if output.exists {
                try output.delete()
            }

            let command = Xcodebuild(
                command: .createXCFramework,
                additionalArguments: frameworks
                    .flatMap { ["-framework", $0.string] } + ["-output", output.string]
            )
            try buildDirectory.chdir {
                try command.run()
            }

            return output
        }
    }
}

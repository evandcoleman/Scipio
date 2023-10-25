import Combine
import Foundation
import PathKit

@discardableResult
func xcrun(_ command: String, _ arguments: String..., in path: Path? = nil, passEnvironment: Bool = false, file: StaticString = #file, line: UInt = #line, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
    return try xcrun(command, arguments, passEnvironment: passEnvironment, file: file, line: line, lineReader: lineReader)
}

@discardableResult
func xcrun(_ command: String, _ arguments: [String], in path: Path? = nil, passEnvironment: Bool = false, file: StaticString = #file, line: UInt = #line, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
//    let developerDirectory = Path((try sh("/usr/bin/xcode-select", "--print-path").outputString())
//        .trimmingCharacters(in: .whitespacesAndNewlines))
//    let commandPath = developerDirectory + "Toolchains/XcodeDefault.xctoolchain/usr/bin/\(command)"

    return try sh("/usr/bin/xcrun", [command] + arguments, in: path, passEnvironment: passEnvironment, file: file, line: line, lineReader: lineReader)
}

struct Xcode {
    static func getArchivePath(for scheme: String, sdk: Xcodebuild.SDK) -> Path {
        return Config.current.buildPath + "\(scheme)-\(sdk.rawValue).xcarchive"
    }

    static func archive(scheme: String, in path: Path, for sdk: Xcodebuild.SDK, derivedDataPath: Path? = nil, sourcePackagesPath: Path? = nil, additionalBuildSettings: [String: String]?) throws -> Path {

        var buildSettings: [String: String] = [
            "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "ENABLE_TESTABILITY": "YES",
            "INSTALL_PATH": "/Library/Frameworks",
            "OTHER_SWIFT_FLAGS": "-no-verify-emitted-module-interface",
            "SKIP_INSTALL": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
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
            derivedDataPath: derivedDataPath?.string,
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
            let output = buildDirectory + "\(productName).xcframework"

            if skipIfExists, output.exists {
                return output
            }

            log.info("📦  Creating \(productName).xcframework...")

            if output.exists {
                try output.delete()
            }

            let inputs = try archivePaths
                .map { try CreateXCFrameworkInput(productName: productName, archivePath: $0) }
            let command = Xcodebuild(
                command: .createXCFramework,
                additionalArguments: try inputs.flatMap { try $0.arguments } + ["-output", output.string]
            )
            try buildDirectory.chdir {
                try command.run()
            }

            return output
        }
    }

    struct CreateXCFrameworkInput {
        let productName: String
        let archivePath: Path

        var arguments: [String] {
            get throws {
                var args: [String] = [
                    "-framework",
                    frameworkPath.string,
                ]

                for path in try debugSymbolFiles {
                    args.append(contentsOf: ["-debug-symbols", path.string])
                }

                return args
            }
        }

        init(productName: String, archivePath: Path) throws {
            self.productName = productName
            self.archivePath = archivePath
        }

        private var frameworkPath: Path {
            return archivePath + "Products/Library/Frameworks/\(productName).framework"
        }

        private var debugSymbolFiles: [Path] {
            get throws {
                let dsymPath = archivePath + "dSYMs/\(productName).framework.dSYM"

                guard dsymPath.exists else {
                    return []
                }

                let dwarfPath = dsymPath + "Contents/Resources/DWARF/\(productName)"

                guard dwarfPath.exists else {
                    return [dsymPath]
                }

                let symbolMaps = try readUUIDs(dwarfPath: dwarfPath)
                    .map { archivePath + "dSYMs/\($0.uuidString.uppercased()).bcsymbolmap" }
                    .filter { $0.exists }

                return [dsymPath, dwarfPath] + symbolMaps
            }
        }

        private func readUUIDs(dwarfPath: Path) throws -> [UUID] {
            let command = try xcrun("dwarfdump", ["--uuid", dwarfPath.string])
            let output = try command.outputString()
            let regex = try NSRegularExpression(pattern: #"^UUID: ([a-zA-Z0-9\-]+)"#, options: .anchorsMatchLines)
            let matches = regex.matches(in: output, options: [], range: NSRange(location: 0, length: output.count))

            return matches
                .compactMap { match in
                    guard let range = Range(match.range(at: 1), in: output) else { return nil }

                    return UUID(uuidString: String(output[range]))
                }
        }
    }
}

import Foundation
import PathKit
import XcbeautifyLib

public struct Xcodebuild {
    var command: Command
    var project: String?
    var scheme: String?
    var archivePath: String?
    var derivedDataPath: String?
    var clonedSourcePackageDirectory: String?
    var sdk: SDK?
    var useSystemSourceControlManagement: Bool = true
    var disableAutomaticPackageResolution: Bool = false
    var additionalArguments: [String] = []
    var additionalBuildSettings: [String: String] = [:]

    init(
        command: Command,
        project: String? = nil,
        scheme: String? = nil,
        archivePath: String? = nil,
        derivedDataPath: String? = nil,
        clonedSourcePackageDirectory: String? = nil,
        sdk: SDK? = nil,
        useSystemSourceControlManagement: Bool = true,
        disableAutomaticPackageResolution: Bool = false,
        additionalArguments: [String] = [],
        additionalBuildSettings: [String: String] = [:]
    ) {
        self.command = command
        self.project = project
        self.scheme = scheme
        self.archivePath = archivePath
        self.derivedDataPath = derivedDataPath
        self.clonedSourcePackageDirectory = clonedSourcePackageDirectory
        self.sdk = sdk
        self.useSystemSourceControlManagement = useSystemSourceControlManagement
        self.disableAutomaticPackageResolution = disableAutomaticPackageResolution
        self.additionalArguments = additionalArguments
        self.additionalBuildSettings = additionalBuildSettings
    }

    func run() {
        let parser = Parser()
        let output = OutputHandler(quiet: false, quieter: false, isCI: false, { log.passthrough($0) })

        let command = buildCommand()
        log.verbose(command)
        sh(command)
            .onReadLine { line in
                if log.level.levelValue <= Log.Level.verbose.levelValue {
                    log.verbose(line)
                } else {
                    guard let formatted = parser.parse(line: line, colored: Log.useColors) else { return }
                    output.write(parser.outputType, formatted)
                }
            }
            .waitUntilExit()

        if let summary = parser.summary {
            print(summary.format())
        }
    }

    private func buildCommand() -> String {
        var args = ["xcodebuild"]

        switch command {
        case .archive:
            args.append("archive")
        case .resolvePackageDependencies:
            args.append("-resolvePackageDependencies")
        case .createXCFramework:
            args.append("-create-xcframework")
        }

        if let project = project {
            args.append(contentsOf: ["-project", project])
        }
        if let scheme = scheme {
            args.append(contentsOf: ["-scheme", scheme])
        }
        if let archivePath = archivePath {
            args.append(contentsOf: ["-archivePath", archivePath])
        }
        if let derivedDataPath = derivedDataPath {
            args.append(contentsOf: ["-derivedDataPath", derivedDataPath])
        }
        if let clonedSourcePackageDirectory = clonedSourcePackageDirectory {
            args.append(contentsOf: ["-clonedSourcePackagesDirPath", clonedSourcePackageDirectory])
        }
        if let sdk = sdk {
            args.append(contentsOf: ["-sdk", sdk.rawValue])
        }
        if useSystemSourceControlManagement, command != .createXCFramework {
            args.append(contentsOf: ["-scmProvider", "system"])
        }
        if disableAutomaticPackageResolution {
            args.append("-disableAutomaticPackageResolution")
        }

        args.append(contentsOf: additionalArguments)
        args.append(contentsOf: additionalBuildSettings.map { "\($0)=\($1)" })

        return args.joined(separator: " ")
    }
}

public extension Xcodebuild {
    enum Command: String {
        case archive
        case resolvePackageDependencies
        case createXCFramework
    }

    enum SDK: String {
        case iphoneos
        case iphonesimulator
    }
}
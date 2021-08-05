import Foundation
import PathKit
import XcodeProj

public struct Project {

    public let path: Path

    public var name: String {
        path.lastComponentWithoutExtension
    }

    private var directory: Path { path.parent() }
    private var derivedDataPath: Path { directory + "DerivedData" }
    private var clonedSourcePackageDirectory: Path { directory + "SourcePackages" }

    private let xcodeproj: XcodeProj

    public init(path: Path) throws {
        self.path = path
        self.xcodeproj = try XcodeProj(path: path)
    }

    public func cleanBuildDirectory() throws {
        let path = Config.current.buildPath
        try path.delete()
        try path.mkdir()
    }

    public func resolvePackageDependencies() {
        let command = Xcodebuild(
            command: .resolvePackageDependencies,
            project: path.string,
            derivedDataPath: derivedDataPath.string,
            clonedSourcePackageDirectory: clonedSourcePackageDirectory.string
        )

        command.run()
    }

    public func build(package: Package, for sdks: [Xcodebuild.SDK], skipClean: Bool) throws {
        let buildSettings: [String: String] = [
            "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
            "SKIP_INSTALL": "NO",
            "ENABLE_BITCODE": "NO",
            "INSTALL_PATH": "/Library/Frameworks"
        ]

        for buildable in package.buildables {
            switch buildable {
            case .scheme(let scheme):
                package.forceDynamicFrameworkProduct(scheme: scheme)
                try package.preBuild()

                for sdk in sdks {
                    let archivePath = getArchivePath(for: scheme, sdk: sdk)
                    package.path.chdir {
                        let command = Xcodebuild(
                            command: .archive,
                            scheme: scheme,
                            archivePath: archivePath.string,
                            derivedDataPath: derivedDataPath.string,
                            clonedSourcePackageDirectory: clonedSourcePackageDirectory.string,
                            sdk: sdk,
                            additionalBuildSettings: buildSettings
                        )

                        command.run()
                    }
                    try package.copyModulesAndHeaders(
                        scheme: scheme,
                        sdk: sdk,
                        archivePath: archivePath,
                        derivedDataPath: derivedDataPath
                    )
                }

                try package.postBuild()
                try package.createXCFramework(scheme: scheme, sdks: sdks, skipIfExists: skipClean)
            case .project(let projectPath, let scheme):
                for sdk in sdks {
                    let archivePath = getArchivePath(for: scheme, sdk: sdk)
                    let command = Xcodebuild(
                        command: .archive,
                        project: projectPath.string,
                        scheme: scheme,
                        archivePath: archivePath.string,
                        derivedDataPath: derivedDataPath.string,
                        sdk: sdk,
                        additionalBuildSettings: buildSettings
                    )

                    command.run()
                }
                try package.createXCFramework(scheme: scheme, sdks: sdks, skipIfExists: skipClean)
            case .target(let target):
                fatalError()
            }
        }
    }

    public func getPackages() throws -> [Package] {
        let decoder = JSONDecoder()
        let workspacePath = clonedSourcePackageDirectory + "workspace-state.json"
        let workspaceState = try decoder.decode(WorkspaceState.self, from: try workspacePath.read())
        let swiftPackages = try workspaceState.object
            .dependencies
            .map { try Package(path: Path($0.subpath)) }
        let projectReferences = try xcodeproj
            .pbxproj
            .projects
            .map { try Package(path: Path($0.projectDirPath)) }

        return swiftPackages + projectReferences
            .sorted { $0.name < $1.name }
    }

    internal func productNames(config: Config.Package?) throws -> [String] {
        let schemeNames = config?.products.map(\.name) ?? [name]

        return try schemeNames
            .flatMap { schemeName -> [String] in
                let schemePath = path + "/xcshareddata/xcschemes/\(schemeName).xcscheme"
                let scheme = try XCScheme(path: schemePath)

                return (scheme.buildAction?.buildActionEntries ?? [])
                    .map(\.buildableReference)
                    .map(\.buildableName)
                    .map { Path($0).lastComponentWithoutExtension }
            }
    }

    private func getArchivePath(for scheme: String, sdk: Xcodebuild.SDK) -> Path {
        return Config.current.buildPath + "\(scheme)-\(sdk.rawValue).xcarchive"
    }
}

extension Project {
    struct WorkspaceState: Decodable {
        let object: Object
    }
}

extension Project.WorkspaceState {
    // MARK: - Object
    struct Object: Codable {
        let artifacts: [Artifact]
        let dependencies: [Dependency]
    }

    // MARK: - Artifact
    struct Artifact: Codable {
        let packageRef: PackageRef
        let source: Source
        let targetName: String
    }

    // MARK: - PackageRef
    struct PackageRef: Codable {
        let identity: String
        let kind: Kind
        let name: String
        let path: String
    }

    enum Kind: String, Codable {
        case local
        case remote
    }

    // MARK: - Source
    struct Source: Codable {
        let path: String?
        let type: Kind
        let checksum, subpath: String?
        let url: String?
    }

    // MARK: - Dependency
    struct Dependency: Codable {
        let packageRef: PackageRef
        let state: State
        let subpath: String
    }

    // MARK: - State
    struct State: Codable {
        let checkoutState: CheckoutState
        let name: Name
    }

    // MARK: - CheckoutState
    struct CheckoutState: Codable {
        let branch: String?
        let revision: String
        let version: String?
    }

    enum Name: String, Codable {
        case checkout
    }
}

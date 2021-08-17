import Combine
import Foundation
import PathKit
import XcodeProj
import Zip

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
        if path.exists {
            try path.delete()
        }
        try path.mkdir()
    }

    public func resolvePackageDependencies(quiet: Bool, colors: Bool) {
        let command = Xcodebuild(
            command: .resolvePackageDependencies,
            project: path.string,
            clonedSourcePackageDirectory: clonedSourcePackageDirectory.string
        )

        command.run()
    }

    public func build(package: Package, for sdks: [Xcodebuild.SDK], skipClean: Bool, quiet: Bool, colors: Bool, force: Bool) -> AnyPublisher<(), Error> {

        return package
            .missingProducts()
            .flatMap { missingProducts -> AnyPublisher<(), Error> in
                return self.performBuild(
                    package: package,
                    for: sdks,
                    productsToBuild: missingProducts,
                    skipClean: skipClean,
                    quiet: quiet,
                    colors: colors,
                    force: force
                )
            }
            .eraseToAnyPublisher()
    }

    public func getPackages() throws -> AnyPublisher<[Package], Error> {
        let packages = Future<[Project.WorkspaceState.Dependency], Error>.try { promise in
            let decoder = JSONDecoder()
            let workspacePath = clonedSourcePackageDirectory + "workspace-state.json"
            let workspaceState = try decoder.decode(WorkspaceState.self, from: try workspacePath.read())

            promise(.success(workspaceState.object.dependencies))
        }
        .flatMap { $0.publisher }
        .tryMap { try Package(path: clonedSourcePackageDirectory + "checkouts" + Path($0.subpath)) }
        .eraseToAnyPublisher()

        let projectReferences = ((try xcodeproj
            .pbxproj
            .rootProject())?
            .projects ?? [])
            .publisher
            .flatMap { $0.values.compactMap(\.path).publisher }
            .tryMap { try Package(path: Config.current.directory + $0) }
            .eraseToAnyPublisher()

        return Publishers.MergeMany(
            packages,
            projectReferences
        )
        .collect()
        .map { $0.sorted { $0.name < $1.name } }
        .eraseToAnyPublisher()
    }

    internal func productNames(config: Config.Package?) throws -> [String: [String]] {
        let schemeNames = config?.products.map(\.name) ?? [name]

        return try schemeNames
            .reduce(into: [:]) { accumulated, value in
                let schemePath = path + "xcshareddata/xcschemes/\(value).xcscheme"
                let scheme = try XCScheme(path: schemePath)

                let productNames = (scheme.buildAction?.buildActionEntries ?? [])
                    .map(\.buildableReference)
                    .map(\.buildableName)
                    .map { Path($0).lastComponentWithoutExtension }

                accumulated[value] = productNames
            }
    }

    private func performBuild(package: Package, for sdks: [Xcodebuild.SDK], productsToBuild: [String], skipClean: Bool, quiet: Bool, colors: Bool, force: Bool) -> AnyPublisher<(), Error> {

        if let excluded = Config.current.exclude, excluded.contains(package.name) {
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        return package
            .buildables
            .publisher
            .setFailureType(to: Error.self)
            .tryFlatMap { buildable -> AnyPublisher<(), Error> in
                let result = Just(())
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()

                switch buildable {
                case .scheme(let scheme):
                    let shouldBuild = force || productsToBuild.contains { package.productNames[scheme]?.contains($0) ?? false }

                    guard shouldBuild else {
                        log.info("⏭ Skipping scheme \(scheme)")
                        return result
                    }

                    try package.preBuild()
                    package.forceDynamicFrameworkProduct(scheme: scheme)

                    for sdk in sdks {
                        try package.build(
                            scheme,
                            for: sdk,
                            derivedDataPath: derivedDataPath
                        )
                    }

                    try package.postBuild()

                    try package.createXCFramework(scheme: scheme, sdks: sdks, skipIfExists: skipClean, force: force)
                case .project(let projectPath, let scheme):
                    let shouldBuild = force || productsToBuild.contains { package.productNames[scheme]?.contains($0) ?? false }

                    guard shouldBuild else {
                        log.info("⏭ Skipping scheme \(scheme)")
                        return result
                    }

                    for sdk in sdks {
                        try package.build(
                            scheme,
                            in: projectPath.string,
                            for: sdk,
                            derivedDataPath: derivedDataPath
                        )
                    }
                    try package.createXCFramework(scheme: scheme, sdks: sdks, skipIfExists: skipClean, force: force)
                case .target(let target):
                    let shouldBuild = force || productsToBuild.contains { package.productNames[target]?.contains($0) ?? false }

                    guard shouldBuild else {
                        log.info("⏭ Skipping target \(target)")
                        return result
                    }

                    let destination = Config.current.buildPath + "\(target).xcframework"

                    return package
                        .downloadOrBuildTarget(named: target, to: destination, sdks: sdks, derivedDataPath: derivedDataPath, skipClean: skipClean, force: force)
                        .tryFlatMap { downloadPath -> AnyPublisher<(), Error> in

                            if downloadPath.string.hasSuffix(".zip") {
                                try Zip.unzipFile(downloadPath.url, destination: destination.url, overwrite: true, password: nil)
                            }

                            return result
                        }
                        .eraseToAnyPublisher()
                }

                return result
            }
            .collect()
            .map { _ in () }
            .eraseToAnyPublisher()
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

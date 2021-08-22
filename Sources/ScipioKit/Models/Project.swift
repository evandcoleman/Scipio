import Combine
import Foundation
import PathKit
import XcodeProj
import Zip

public struct LegacyProject {

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
        .tryMap { try Package(path: clonedSourcePackageDirectory + "checkouts" + Path($0.subpath), name: $0.packageRef.name) }
        .eraseToAnyPublisher()

        let projectReferences = ((try xcodeproj
            .pbxproj
            .rootProject())?
            .projects ?? [])
            .publisher
            .flatMap { $0.values.compactMap(\.path).publisher }
            .tryMap { try Package(path: Config.current.directory + $0, name: $0) }
            .eraseToAnyPublisher()

        let urlPackages = Future<[Package], Error>.try { promise in
            let packages = try (Config.current.packages ?? [:])
                .filter { $0.value.url != nil }
                .map { try Package(name: $0.key, package: $0.value) }
            promise(.success(packages))
        }
        .flatMap { $0.publisher }
        .eraseToAnyPublisher()

        let cocoaPodPackages = Future<[Package], Error>.try { promise in
            let packages = try (Config.current.packages ?? [:])
                .filter { $0.value.cocoapod != nil }
                .map { try Package(path: Config.current.cachePath + "Pods" + $0.key, name: $0.key, package: $0.value) }
            promise(.success(packages))
        }
        .flatMap { $0.publisher }
        .eraseToAnyPublisher()

        return Publishers.MergeMany(
            packages,
            projectReferences,
            urlPackages,
            cocoaPodPackages
        )
        .collect()
        .map { $0.sorted { $0.name < $1.name } }
        .eraseToAnyPublisher()
    }

    internal func productNames(config: Config.Package?) throws -> [String: [String]] {
        let schemeNames = config?.products?.map(\.name) ?? [name]

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
            .combineLatest(package.productNames())
            .tryFlatMap { buildable, productNames -> AnyPublisher<(), Error> in
                let result = Just(())
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()

                switch buildable {
                case .scheme(let scheme):
                    let shouldBuild = force || productsToBuild.contains { productNames[scheme]?.contains($0) ?? false }

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
                    let shouldBuild = force || productsToBuild.contains { productNames[scheme]?.contains($0) ?? false }

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
                    let shouldBuild = force || productsToBuild.contains { productNames[target]?.contains($0) ?? false }

                    guard shouldBuild else {
                        log.info("⏭ Skipping target \(target)")
                        return result
                    }

                    let destination = Config.current.buildPath + "\(target).xcframework"

                    return package
                        .downloadOrBuildTarget(named: target, to: destination, sdks: sdks, derivedDataPath: derivedDataPath, skipClean: skipClean, force: force)
                        .map { _ in () }
                        .eraseToAnyPublisher()
                case .download(let url):
                    let downloadPath = Config.current.cachePath + url.lastPathComponent

                    if downloadPath.exists {
                        return Just(())
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    } else {
                        return package
                            .download(from: url)
                            .map { _ in () }
                            .eraseToAnyPublisher()
                    }
                case .cocoapod(let name):
//                    let shouldBuild = force || productsToBuild.contains { productNames[name]?.contains($0) ?? false }
//
//                    guard shouldBuild else {
//                        log.info("⏭ Skipping scheme \(scheme)")
//                        return result
//                    }

                    for sdk in sdks {
                        try package.build(
                            "\(name)Wrapper",
                            workspace: (package.path + "\(name).xcworkspace").string,
                            for: sdk,
                            derivedDataPath: derivedDataPath
                        )
                    }
                    try package.createXCFramework(
                        scheme: "\(name)Wrapper",
                        products: productsToBuild,
                        sdks: sdks,
                        skipIfExists: skipClean,
                        force: force
                    )
                }

                return result
            }
            .collect()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}


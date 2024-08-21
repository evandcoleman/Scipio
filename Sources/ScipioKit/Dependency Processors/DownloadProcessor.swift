//
//  DownloadProcessor.swift
//
//
//  Created by Evan Coleman on 8/21/24.
//

import Basics
import Foundation
import PathKit
import Zip

public protocol DownloadDependency: Dependency {
    var name: String { get }
    var version: String? { get }
    var excludes: [String]? { get }
    var products: [String]? { get }
}

open class DownloadProcessor<Dependency: DownloadDependency>: DependencyProcessor {

    public let dependencies: [Dependency]
    public let options: ProcessorOptions

    open var directoryName: String {
        fatalError("Subclasses must override this")
    }

    private let urlSession: URLSession = .createWithExtensionsSupport()

    required public init(
        dependencies: [Dependency],
        options: ProcessorOptions,
        observabilityScope: ObservabilityScope
    ) {
        self.dependencies = dependencies
        self.options = options
    }

    public func preProcess() async throws -> [DownloadProduct] {
        var products: [DownloadProduct] = []

        for dependency in dependencies {
            products.append(contentsOf: try await getProducts(dependency))
        }

        return products
    }

    public func process(
        dependencies: [Dependency],
        product: DownloadProduct
    ) async throws -> [any LocalArtifact] {
        let isExcluded = dependencies
            .compactMap(\.excludes)
            .contains { $0.contains(product.productName) }

        if isExcluded {
            return []
        }

        let includes = dependencies
            .compactMap(\.products)
            .flatMap { $0 }

        if !includes.isEmpty {
            let isIncluded = includes.contains(product.productName)

            if !isIncluded {
                return []
            }
        }

        return [
            Artifact(
                name: product.productName,
                parentNames: product.parentNames,
                version: product.version,
                path: product.path
            )
        ]
    }

    open func getDownloadUrl(dependency: Dependency) async throws -> (version: String, url: URL) {
        fatalError("Subclasses must override this")
    }

    private func getProducts(_ dependency: Dependency) async throws -> [DownloadProduct] {
        let (version, decompressedPath) = try await fetchDependency(dependency)
        let artifacts = try getArtifacts(
            dependency: dependency,
            version: version,
            path: decompressedPath
        )

        return artifacts
            .map { artifact in
                return DownloadProduct(
                    productName: artifact.name,
                    version: version,
                    parentName: dependency.name,
                    path: artifact.path
                )
            }
    }

    private func fetchDependency(_ dependency: Dependency) async throws -> (version: String, path: Path) {
        let (version, downloadUrl) = try await getDownloadUrl(dependency: dependency)
        let downloadPath = try getDownloadDestination(
            dependency: dependency,
            version: version,
            fileExtension: downloadUrl.pathExtension
        )
        let checksumCache = try getChecksumCachePath(
            dependency: dependency,
            version: version
        )

        if
            downloadPath.exists, checksumCache.exists,
            try downloadPath.checksum(.sha256) == (try checksumCache.read())
        {
            do {
                return (
                    version,
                    try self.decompress(
                        dependency: dependency,
                        version: version,
                        at: downloadPath
                    )
                )
            } catch {
                log.verbose("Error decompressing, will delete and download again: \(error)")

                return (
                    version,
                    try await downloadAndDecompress(
                        dependency,
                        version: version,
                        url: downloadUrl,
                        path: downloadPath,
                        checksumCache: checksumCache
                    )
                )
            }
        } else {
            return (
                version,
                try await downloadAndDecompress(
                    dependency,
                    version: version,
                    url: downloadUrl,
                    path: downloadPath,
                    checksumCache: checksumCache
                )
            )
        }
    }

    private func getArtifacts(
        dependency: Dependency,
        version: String,
        path: Path
    ) throws -> [Artifact] {
        let xcFrameworks = try path
            .recursiveChildren()
            .filter { $0.extension == "xcframework" }
            .compactMap { framework -> Artifact? in
                let targetPath = try getXCFrameworkPath(
                    dependency: dependency,
                    frameworkPath: framework
                )

                if targetPath.exists {
                    try targetPath.delete()
                }

                if
                    let excludes = dependency.excludes,
                    excludes.contains(framework.lastComponentWithoutExtension)
                {
                    return nil
                }

                try framework.copy(targetPath)

                return Artifact(
                    name: targetPath.lastComponentWithoutExtension,
                    parentNames: [dependency.name],
                    version: version,
                    path: targetPath
                )
            }

        if xcFrameworks.isEmpty {
            return try path
                .recursiveChildren()
                .filter { $0.extension == "framework" }
                .compactMap { framework -> Artifact? in
                    let targetPath = try getXCFrameworkPath(
                        dependency: dependency,
                        frameworkPath: framework
                    )

                    if targetPath.exists {
                        try targetPath.delete()
                    }

                    if
                        let excludes = dependency.excludes,
                        excludes.contains(framework.lastComponentWithoutExtension)
                    {
                        return nil
                    }

                    _ = try self.convertUniversalFrameworkToXCFramework(input: framework)

                    return Artifact(
                        name: targetPath.lastComponentWithoutExtension,
                        parentNames: [dependency.name],
                        version: version,
                        path: targetPath
                    )
                }
        }

        return xcFrameworks
    }

    public func postProcess() async throws {}

    private func downloadAndDecompress(
        _ dependency: Dependency,
        version: String,
        url: URL,
        path: Path,
        checksumCache: Path
    ) async throws -> Path {
        if path.exists {
            try path.delete()
        }

        let downloadPath = try await download(
            dependency: dependency,
            version: version,
            at: url
        )
        let decompressedPath = try decompress(
            dependency: dependency,
            version: version,
            at: downloadPath
        )

        do {
            try checksumCache.write(try path.checksum(.sha256))
        } catch {
            log.debug("Failed to write checksum cache for \(path)")
        }

        return decompressedPath
    }

    private func download(dependency: Dependency, version: String, at url: URL) async throws -> Path {
        let targetPath = try getDownloadDestination(
            dependency: dependency,
            version: version,
            fileExtension: url.pathExtension
        )

        if targetPath.exists {
            return targetPath
        }

        let _: Void = try await withCheckedThrowingContinuation { continuation in
            let task = self.urlSession
                .downloadTask(
                    with: url,
                    progressHandler: { log.progress(percent: $0) }
                ) { url, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let url = url {
                        do {
                            let downloadedPath = Path(url.path)
                            try downloadedPath.move(targetPath)
                            continuation.resume(returning: ())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        log.fatal("Unexpected download result")
                    }
                }

            log.info("Downloading \(url.lastPathComponent):")

            task.resume()
        }

        return targetPath
    }

    private func decompress(dependency: Dependency, version: String, at path: Path) throws -> Path {
        log.info("Decompressing \(path.lastComponent)...")

        guard let compression = FileCompression(path.url) else {
            log.fatal("Unsupported url extension \"\(path.url.pathExtension)\"")
        }

        let targetPath = try getDecompressedPath(
            dependency: dependency,
            version: version
        )

        if options.skipClean, targetPath.exists {
            return targetPath
        } else if targetPath.exists {
            try targetPath.delete()
        }

        switch compression {
        case .zip:
            try Zip.unzipFile(
                path.url,
                destination: targetPath.url,
                overwrite: true,
                password: nil,
                progress: { log.progress(percent: $0) }
            )
        case .gzip:
            let gunzippedPath = try path.gunzipped()
            try gunzippedPath.move(targetPath)
        case .tarGzip:
            let gunzippedPath = try path.gunzipped()
            let untaredPath = try gunzippedPath.untar()
            try untaredPath.move(targetPath)
        }

        return targetPath
    }

    private func convertUniversalFrameworkToXCFramework(input: Path) throws -> [Path] {
        let frameworkName = input.lastComponentWithoutExtension
        let binaryPath = input + frameworkName

        guard binaryPath.exists else {
            throw ScipioError.invalidFramework(input.lastComponent)
        }

        let rawArchitectures = try sh("/usr/bin/lipo", "-info", binaryPath.string)
            .outputString()
            .components(separatedBy: ":")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ") ?? []
        let architectures = rawArchitectures
            .compactMap { Architecture(rawValue: $0) }
        let unknownArchitectures = rawArchitectures
            .filter { Architecture(rawValue: $0) == nil }

        guard architectures == Architecture.allCases else {
            throw ScipioError.missingArchitectures(
                input.lastComponent,
                Array(Set(Architecture.allCases).subtracting(Set(architectures)))
            )
        }

        let platformSDKs = options.platforms.flatMap(\.sdks).uniqued()

        // TODO: Support macOS and tvOS
        guard platformSDKs.count == 2,
              platformSDKs.contains(.iphoneos),
              platformSDKs.contains(.iphonesimulator) else {

            fatalError("Only iOS is supported right now")
        }

        let sdkArchitectures = architectures.sdkArchitectures
        let sdks = Set(platformSDKs).intersection(sdkArchitectures.keys)

        let archivePaths = try sdks.map { sdk -> Path in
            let archivePath = Config.current.buildPath + "\(frameworkName)-\(sdk.rawValue)"
            let frameworksFolder = archivePath + "Products/Library/Frameworks"

            if archivePath.exists {
                try archivePath.delete()
            }

            try frameworksFolder.mkpath()

            try input.copy(frameworksFolder + input.lastComponent)

            let removeArchs = Set(architectures).subtracting(sdk.architectures)
            let removeArgs = (removeArchs
                .map(\.rawValue) + unknownArchitectures)
                .flatMap { ["-remove", $0] }
            let sdkBinaryPath = frameworksFolder + "\(input.lastComponent)/\(frameworkName)"

            try sh("/usr/bin/lipo", removeArgs + [binaryPath.string, "-o", sdkBinaryPath.string])

            return archivePath
        }

        return try XcodeBuilder.createXCFramework(
            archivePaths: archivePaths,
            skipIfExists: options.skipClean,
            useLibraryEvolution: true
        )
    }
}

// MARK: DownloadProduct

extension DownloadProcessor {

    public struct DownloadProduct: Product {

        public var productName: String
        public var version: String
        public var parentName: String
        public var path: Path

        public var parentNames: [String] {
            return [parentName]
        }
    }
}

private enum FileCompression {
    case zip
    case gzip
    case tarGzip

    init?(_ path: Path) {
        self.init(path.url)
    }

    init?(_ url: URL) {
        switch url.pathExtension {
        case "zip":
            self = .zip
        case "gz":
            if let ext = Path(url.path).withoutLastExtension().extension {
                switch ext {
                case "tar":
                    self = .tarGzip
                default:
                    return nil
                }
            } else {
                self = .gzip
            }
        default:
            return nil
        }
    }

    func decompressedName(url: URL) -> String {
        switch self {
        case .zip, .gzip:
            return Path(url.path)
                .lastComponentWithoutExtension
        case .tarGzip:
            return Path(url.path)
                .withoutLastExtension()
                .lastComponentWithoutExtension
        }
    }
}

private extension DownloadProcessor {

    private func getBinaryDependencyDirectory(dependency: any DownloadDependency) throws -> Path {
        let path = Config.current.buildPath + directoryName + dependency.name

        if !path.exists {
            try path.mkpath()
        }

        return path
    }

    func getDownloadDestination(dependency: any DownloadDependency, version: String, fileExtension: String) throws -> Path {
        return try getBinaryDependencyDirectory(dependency: dependency)
            + "\(dependency.name)-\(version).\(fileExtension)"
    }

    func getDecompressedPath(dependency: any DownloadDependency, version: String) throws -> Path {
        return try getBinaryDependencyDirectory(dependency: dependency)
            + "\(dependency.name)-\(version)"
    }

    func getXCFrameworkPath(dependency: any DownloadDependency, frameworkPath: Path) throws -> Path {
        return try getBinaryDependencyDirectory(dependency: dependency)
            + "\(frameworkPath.lastComponentWithoutExtension).xcframework"
    }

    func getChecksumCachePath(dependency: any DownloadDependency, version: String) throws -> Path {
        return try getBinaryDependencyDirectory(dependency: dependency)
            + "checksum-\(dependency.name)-\(version)"
    }
}


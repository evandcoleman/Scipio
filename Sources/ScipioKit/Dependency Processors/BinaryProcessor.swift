import Combine
import Foundation
import PathKit
import Zip

public final class BinaryProcessor: DependencyProcessor {

    public let dependencies: [BinaryDependency]
    public let options: ProcessorOptions

    private let urlSession: URLSession = .createWithExtensionsSupport()

    public init(dependencies: [BinaryDependency], options: ProcessorOptions) {
        self.dependencies = dependencies
        self.options = options
    }

    public func preProcess() -> AnyPublisher<[BinaryDependency], Error> {
        log.info("🔗  Processing binary dependencies...")

        return Just(dependencies)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    public func process(_ dependency: BinaryDependency?, resolvedTo resolvedDependency: BinaryDependency) -> AnyPublisher<[AnyArtifact], Error> {
        return Just(dependency)
            .setFailureType(to: Error.self)
            .tryFlatMap { dependency -> AnyPublisher<(BinaryDependency, Path), Error> in
                let downloadPath = Config.current.cachePath + resolvedDependency.url.lastPathComponent
                let checksumCache = Config.current.cachePath + ".binary-\(resolvedDependency.name)-\(resolvedDependency.version)"

                if downloadPath.exists, checksumCache.exists,
                   try downloadPath.checksum(.sha256) == (try checksumCache.read()) {

                    return Just(downloadPath)
                        .setFailureType(to: Error.self)
                        .tryFlatMap { path in
                            return Future.try {
                                return try self.decompress(dependency: resolvedDependency, at: path)
                            }
                            .catch { error -> AnyPublisher<Path, Error> in
                                log.verbose("Error decompressing, will delete and download again: \(error)")

                                return self.downloadAndDecompress(resolvedDependency, path: downloadPath, checksumCache: checksumCache)
                            }
                        }
                        .map { (resolvedDependency, $0) }
                        .eraseToAnyPublisher()
                } else {
                    return self.downloadAndDecompress(resolvedDependency, path: downloadPath, checksumCache: checksumCache)
                        .map { (resolvedDependency, $0) }
                        .eraseToAnyPublisher()
                }
            }
            .tryMap { dependency, path -> [AnyArtifact] in
                let xcFrameworks = try path
                    .recursiveChildren()
                    .filter { $0.extension == "xcframework" }
                    .compactMap { framework -> AnyArtifact? in
                        let targetPath = Config.current.buildPath + framework.lastComponent

                        if targetPath.exists {
                            try targetPath.delete()
                        }

                        if let excludes = dependency.excludes,
                           excludes.contains(framework.lastComponentWithoutExtension) {

                            return nil
                        }

                        try framework.copy(targetPath)

                        return AnyArtifact(Artifact(
                            name: targetPath.lastComponentWithoutExtension,
                            parentName: dependency.name,
                            version: dependency.version,
                            path: targetPath
                        ))
                    }

                if xcFrameworks.isEmpty {
                    return try path
                        .recursiveChildren()
                        .filter { $0.extension == "framework" }
                        .compactMap { framework -> AnyArtifact? in
                            let targetPath = Config.current.buildPath + "\(framework.lastComponentWithoutExtension).xcframework"

                            if targetPath.exists {
                                try targetPath.delete()
                            }

                            if let excludes = dependency.excludes,
                               excludes.contains(framework.lastComponentWithoutExtension) {

                                return nil
                            }

                            _ = try self.convertUniversalFrameworkToXCFramework(input: framework)

                            return AnyArtifact(Artifact(
                                name: targetPath.lastComponentWithoutExtension,
                                parentName: dependency.name,
                                version: dependency.version,
                                path: targetPath
                            ))
                        }
                }

                return xcFrameworks
            }
            .collect()
            .map { $0.flatMap { $0 } }
            .tryMap { artifacts in
                let filtered: [AnyArtifact] = artifacts
                    .reduce(into: []) { acc, next in
                        if !acc.contains(where: { $0.name == next.name }) {
                            acc.append(next)
                        }
                    }

                try resolvedDependency.cache(filtered.map(\.name))

                return filtered
            }
            .eraseToAnyPublisher()
    }

    public func postProcess() -> AnyPublisher<(), Error> {
        return Just(())
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    private func downloadAndDecompress(_ dependency: BinaryDependency, path: Path, checksumCache: Path) -> AnyPublisher<Path, Error> {
        return Future<Path, Error>.try {
            if path.exists {
                try path.delete()
            }

            return path
        }
        .flatMap { _ -> AnyPublisher<Path, Error> in
            return self.download(dependency: dependency)
                .tryMap { path in
                    return try self.decompress(dependency: dependency, at: path)
                }
                .handleEvents(receiveOutput: { _ in
                    do {
                        try checksumCache.write(try path.checksum(.sha256))
                    } catch {
                        log.debug("Failed to write checksum cache for \(path)")
                    }
                })
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }

    private func download(dependency: BinaryDependency) -> AnyPublisher<Path, Error> {
        let url = dependency.url
        let targetPath = Config.current.cachePath + Path(url.path).lastComponentWithoutExtension
        let targetRawPath = Config.current.cachePath + url.lastPathComponent

        return Future<URL, Error> { promise in
            let task = self.urlSession
                .downloadTask(with: url, progressHandler: { log.progress(percent: $0) }) { url, response, error in
                    if let error = error {
                        promise(.failure(error))
                    } else if let url = url {
                        promise(.success(url))
                    } else {
                        log.fatal("Unexpected download result")
                    }
                }

            log.info("Downloading \(url.lastPathComponent):")

            task.resume()
        }
        .tryMap { downloadUrl -> Path in
            if targetPath.exists {
                try targetPath.delete()
            }
            if targetRawPath.exists {
                try targetRawPath.delete()
            }

            let downloadedPath = Path(downloadUrl.path)

            try downloadedPath.move(targetRawPath)

            return targetRawPath
        }
        .eraseToAnyPublisher()
    }

    private func decompress(dependency: BinaryDependency, at path: Path) throws -> Path {
        let targetPath = Config.current.cachePath + Path(dependency.url.path).lastComponent.components(separatedBy: ".")[0]

        if options.skipClean, targetPath.exists {
            return targetPath
        } else if targetPath.exists {
            try targetPath.delete()
        }

        log.info("Decompressing \(path.lastComponent)...")

        switch dependency.url.pathExtension {
        case "zip":
            try Zip.unzipFile(path.url, destination: targetPath.url, overwrite: true, password: nil, progress: { log.progress(percent: $0) })
        case "gz":
            let gunzippedPath = try path.gunzipped()

            if gunzippedPath.extension == "tar" {
                let untaredPath = try gunzippedPath.untar()

                if !targetPath.exists {
                    try untaredPath.move(targetPath)
                }
            } else {
                try gunzippedPath.move(targetPath)
            }
        case "":
            break
        default:
            log.fatal("Unsupported package url extension \"\(dependency.url.pathExtension)\"")
        }

        return targetPath
    }

    private func convertUniversalFrameworkToXCFramework(input: Path) throws -> [Path] {
        let frameworkName = input.lastComponentWithoutExtension
        let binaryPath = input + frameworkName

        guard binaryPath.exists else {
            throw ScipioError.invalidFramework(input.lastComponent)
        }

        let rawArchitectures = try sh("xcrun lipo -i \(binaryPath.quoted)")
            .waitForOutputString()
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
                .map { "-remove \($0)" }
            let sdkBinaryPath = frameworksFolder + "\(input.lastComponent)/\(frameworkName)"

            try sh("xcrun lipo \(removeArgs.joined(separator: " ")) \(binaryPath.quoted) -o \(sdkBinaryPath.quoted)")
                .waitUntilExit()

            return archivePath
        }

        return try Xcode.createXCFramework(archivePaths: archivePaths, skipIfExists: options.skipClean)
    }
}

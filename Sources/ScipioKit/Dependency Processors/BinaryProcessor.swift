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
        return Just(dependencies)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    public func process(_ dependency: BinaryDependency?, resolvedTo resolvedDependency: BinaryDependency) -> AnyPublisher<[Artifact], Error> {
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
            .tryMap { dependency, path -> [Artifact] in
                return try path
                    .recursiveChildren()
                    .filter { $0.extension == "xcframework" }
                    .compactMap { framework -> Artifact? in
                        let targetPath = Config.current.buildPath + framework.lastComponent

                        if targetPath.exists {
                            try targetPath.delete()
                        }

                        if let excludes = dependency.excludes,
                           excludes.contains(framework.lastComponentWithoutExtension) {

                            return nil
                        }

                        try framework.copy(targetPath)

                        return Artifact(
                            name: targetPath.lastComponentWithoutExtension,
                            version: dependency.version,
                            path: targetPath
                        )
                    }
            }
            .collect()
            .map { $0.flatMap { $0 } }
            .tryMap { artifacts in
                let filtered: [Artifact] = artifacts
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
                .downloadTask(with: url, progressHandler: { log.progress("Downloading \(url.lastPathComponent)", percent: $0) }) { url, response, error in
                    if let error = error {
                        promise(.failure(error))
                    } else if let url = url {
                        promise(.success(url))
                    } else {
                        log.fatal("Unexpected download result")
                    }
                }

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
        let targetPath = Config.current.cachePath + Path(dependency.url.path).lastComponentWithoutExtension

        if options.skipClean, targetPath.exists {
            return targetPath
        }

        switch dependency.url.pathExtension {
        case "zip":
            try Zip.unzipFile(path.url, destination: targetPath.url, overwrite: true, password: nil, progress: { log.progress("Decompressing \(path.lastComponent)", percent: $0) })
        case "gz":
            let gunzippedPath = try path.gunzipped()

            if gunzippedPath.extension == "tar" {
                let untaredPath = try gunzippedPath.untar(progress: { log.progress("Untaring \(gunzippedPath.lastComponent)", percent: $0) })

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
}

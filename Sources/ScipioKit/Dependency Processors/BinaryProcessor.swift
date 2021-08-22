import Combine
import Foundation
import PathKit
import Zip

public struct BinaryProcessor: DependencyProcessor {

    let dependencies: [BinaryDependency]
    let options: ProcessorOptions

    private let urlSession: URLSession = .createWithExtensionsSupport()

    public init(dependencies: [BinaryDependency], options: ProcessorOptions) {
        self.dependencies = dependencies
        self.options = options
    }

    public func process() -> AnyPublisher<[Path], Error> {
        return dependencies
            .publisher
            .setFailureType(to: Error.self)
            .tryFlatMap { dependency -> AnyPublisher<Path, Error> in
                let downloadPath = Config.current.cachePath + dependency.url.lastPathComponent
                let checksumCache = Config.current.cachePath + ".binary-\(dependency.name)-\(dependency.version)"

                if downloadPath.exists, checksumCache.exists,
                   try downloadPath.checksum(.sha256) == (try checksumCache.read()) {

                    return Just(downloadPath)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                } else {
                    if downloadPath.exists {
                        try downloadPath.delete()
                    }

                    return download(dependency: dependency)
                        .handleEvents(receiveOutput: { _ in
                            do {
                                try checksumCache.write(try downloadPath.checksum(.sha256))
                            } catch {
                                log.debug("Failed to write checksum cache for \(downloadPath)")
                            }
                        })
                        .eraseToAnyPublisher()
                }
            }
            .tryMap { path -> [Path] in
                return try path
                    .recursiveChildren()
                    .filter { $0.extension == "xcframework" }
                    .map { framework -> Path in
                        let targetPath = Config.current.buildPath + framework.lastComponent

                        if targetPath.exists {
                            try targetPath.delete()
                        }

                        try framework.move(targetPath)

                        return targetPath
                    }
            }
            .collect()
            .map { $0.flatMap { $0 } }
            .eraseToAnyPublisher()
    }

    private func download(dependency: BinaryDependency) -> AnyPublisher<Path, Error> {
        let url = dependency.url
        let targetPath = Config.current.cachePath + Path(url.path).lastComponentWithoutExtension
        let targetRawPath = Config.current.cachePath + url.lastPathComponent

        return Future<URL, Error> { promise in
            let task = urlSession
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

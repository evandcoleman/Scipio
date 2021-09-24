import Combine
import Foundation
import PathKit

public protocol HTTPCacheEngineProtocol: CacheEngine {
    var uploadBaseUrl: URL { get }
    var downloadBaseUrl: URL { get }
    var urlSession: URLSession { get }

    func uploadUrlRequest(url: URL) -> URLRequest
}

public enum HTTPCacheEngineError: Error {
    case requestFailed(statusCode: Int, body: String? = nil)
    case downloadFailed
}

extension HTTPCacheEngineProtocol {

    public var uploadBaseUrl: URL { downloadBaseUrl }

    public func uploadUrl(for product: String, version: String) -> URL {
        return url(for: product, version: version, baseUrl: uploadBaseUrl)
    }

    public func downloadUrl(for product: String, version: String) -> URL {
        return url(for: product, version: version, baseUrl: downloadBaseUrl)
    }

    public func uploadUrlRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)

        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = [
            "Content-Type": "application/zip"
        ]

        return request
    }

    public func exists(product: String, version: String) -> AnyPublisher<Bool, Error> {
        var request = URLRequest(url: downloadUrl(for: product, version: version))
        request.httpMethod = "HEAD"

        return urlSession
            .dataTaskPublisher(for: request)
            .map { (($0.response as? HTTPURLResponse)?.statusCode ?? 500) < 400 }
            .mapError { $0 as Error }
            .eraseToAnyPublisher()
    }

    public func put(artifact: CompressedArtifact) -> AnyPublisher<CachedArtifact, Error> {
        return Future { promise in
            let request = uploadUrlRequest(url: uploadUrl(for: artifact.name, version: artifact.version))

            let task = urlSession
                .uploadTask(with: request, fromFile: artifact.path.url, progressHandler: { log.progress(percent: $0) }) { data, response, error in
                    if let error = error {
                        promise(.failure(error))
                    } else if let statusCode = (response as? HTTPURLResponse)?.statusCode, statusCode >= 400 {
                        promise(.failure(HTTPCacheEngineError.requestFailed(statusCode: statusCode, body: String(data: data ?? Data(), encoding: .utf8) ?? "")))
                    } else {
                        do {
                            promise(.success(try CachedArtifact(
                                name: artifact.name,
                                parentName: artifact.parentName,
                                url: downloadUrl(for: artifact.name, version: artifact.version),
                                localPath: artifact.path
                            )))
                        } catch {
                            promise(.failure(error))
                        }
                    }
                }

            log.info("Uploading \(artifact.name)")

            task.resume()
        }
        .eraseToAnyPublisher()
    }

    public func get(product: String, in parentName: String, version: String, destination: Path) -> AnyPublisher<CompressedArtifact, Error> {
        return Future<URL, Error> { promise in
            let url = downloadUrl(for: product, version: version)

            let task = urlSession
                .downloadTask(with: url, progressHandler: { log.progress(percent: $0) }) { url, response, error in
                    if let error = error {
                        promise(.failure(error))
                    } else if let statusCode = (response as? HTTPURLResponse)?.statusCode, statusCode >= 400 {
                        promise(.failure(HTTPCacheEngineError.requestFailed(statusCode: statusCode)))
                    } else if let url = url {
                        promise(.success(url))
                    } else {
                        promise(.failure(HTTPCacheEngineError.downloadFailed))
                    }
                }

            log.info("Downloading \(product):")

            task.resume()
        }
        .tryMap { url in
            if destination.exists {
                try destination.delete()
            }

            try Path(url.path).copy(destination)

            return CompressedArtifact(
                name: product,
                parentName: parentName,
                version: version,
                path: destination.isDirectory ? destination + url.lastPathComponent : destination
            )
        }
        .eraseToAnyPublisher()
    }

    public func url(for product: String, version: String, baseUrl: URL) -> URL {
        let encodedProduct = product.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let encodedVersion = version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!

        return baseUrl
            .appendingPathComponent(encodedProduct)
            .appendingPathComponent("\(encodedProduct)-\(encodedVersion).xcframework.zip")
    }
}

public struct HTTPCacheEngine: HTTPCacheEngineProtocol, Decodable, Equatable {

    public let url: URL

    public let urlSession: URLSession = .createWithExtensionsSupport()

    public var downloadBaseUrl: URL { url }

    enum CodingKeys: String, CodingKey {
        case url
    }
}

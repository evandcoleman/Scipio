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

    public func exists(product: String, version: String) async throws -> Bool {
        var request = URLRequest(url: downloadUrl(for: product, version: version))
        request.httpMethod = "HEAD"

        let (_, response) = try await urlSession
            .data(for: request)

        return ((response as? HTTPURLResponse)?.statusCode ?? 500) < 400
    }

    public func put(artifact: any LocalArtifact) async throws -> CachedArtifact {
        let request = uploadUrlRequest(url: uploadUrl(for: artifact.name, version: artifact.version))

        return try await withCheckedThrowingContinuation { continuation in
            let task = urlSession
                .uploadTask(
                    with: request,
                    fromFile: artifact.path.url,
                    progressHandler: { log.progress(percent: $0) }
                ) { data, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let statusCode = (response as? HTTPURLResponse)?.statusCode, statusCode >= 400 {
                        continuation.resume(
                            throwing: HTTPCacheEngineError.requestFailed(
                                statusCode: statusCode,
                                body: String(data: data ?? Data(), encoding: .utf8) ?? ""
                            )
                        )
                    } else {
                        do {
                            continuation.resume(
                                returning: try CachedArtifact(
                                    name: artifact.name, 
                                    version: artifact.version,
                                    parentNames: artifact.parentNames,
                                    url: downloadUrl(for: artifact.name, version: artifact.version),
                                    localPath: artifact.path
                                )
                            )
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

            log.info("Uploading \(artifact.name)")

            task.resume()
        }
    }

    public func get(
        product: String,
        parentNames: [String],
        version: String,
        destination: Path
    ) async throws -> any LocalArtifact {
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let url = downloadUrl(for: product, version: version)

            let task = urlSession
                .downloadTask(
                    with: url,
                    progressHandler: { log.progress(percent: $0) }
                ) { url, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let statusCode = (response as? HTTPURLResponse)?.statusCode, statusCode >= 400 {
                        continuation.resume(throwing: HTTPCacheEngineError.requestFailed(statusCode: statusCode))
                    } else if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: HTTPCacheEngineError.downloadFailed)
                    }
                }

            log.info("Downloading \(product):")

            task.resume()
        }

        if destination.exists {
            try destination.delete()
        }

        try Path(url.path).copy(destination)

        return CompressedArtifact(
            name: product,
            parentNames: parentNames,
            version: version,
            path: destination.isDirectory ? destination + url.lastPathComponent : destination
        )
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

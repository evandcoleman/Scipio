import Combine
import Foundation
import PathKit

struct HTTPCacheEngine: CacheEngine, Decodable, Equatable {

    let url: URL

    private var urlSession: URLSession { .shared }

    enum HTTPCacheEngineError: Error {
        case requestFailed(statusCode: Int, body: String? = nil)
        case downloadFailed
    }

    func downloadUrl(for product: String, version: String) -> URL {
        return url
            .appendingPathComponent(product)
            .appendingPathComponent("\(product)-\(version).xcframework.zip")
    }

    func exists(product: String, version: String) -> AnyPublisher<Bool, Error> {
        var request = URLRequest(url: downloadUrl(for: product, version: version))
        request.httpMethod = "HEAD"

        return urlSession
            .dataTaskPublisher(for: request)
            .map { (($0.response as? HTTPURLResponse)?.statusCode ?? 500) < 400 }
            .mapError { $0 as Error }
            .eraseToAnyPublisher()
    }

    func put(product: String, version: String, path: Path) -> AnyPublisher<(), Error> {
        return Future { promise in
            var request = URLRequest(url: downloadUrl(for: product, version: version))
            request.httpMethod = "PUT"
            request.allHTTPHeaderFields = [
                "Content-Type": "application/zip"
            ]

            let task = urlSession
                .uploadTask(with: request, fromFile: path.url) { data, response, error in
                    if let error = error {
                        promise(.failure(error))
                    } else if let statusCode = (response as? HTTPURLResponse)?.statusCode, statusCode >= 400 {
                        promise(.failure(HTTPCacheEngineError.requestFailed(statusCode: statusCode, body: String(data: data ?? Data(), encoding: .utf8) ?? "")))
                    } else {
                        promise(.success(()))
                    }
                }

            task.resume()
        }
        .eraseToAnyPublisher()
    }

    func get(product: String, version: String, destination: Path) -> AnyPublisher<Path, Error> {
        return Future<URL, Error> { promise in
            let url = downloadUrl(for: product, version: version)

            let task = urlSession
                .downloadTask(with: url) { url, response, error in
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

            task.resume()
        }
        .tryMap { url in
            try Path(url.path).copy(destination)

            return destination
        }
        .eraseToAnyPublisher()
    }
}
import Combine
import Foundation
import PathKit

protocol CacheEngine {
    func downloadUrl(for product: String, version: String) -> URL
    func exists(product: String, version: String) -> AnyPublisher<Bool, Error>
    func get(product: String, version: String, destination: Path) -> AnyPublisher<Path, Error>
    func put(product: String, version: String, path: Path) -> AnyPublisher<(), Error>
}

struct CacheEngineDescriptor: Decodable, Equatable, CacheEngine {
    let local: LocalCacheEngine?
    let http: HTTPCacheEngine?

    private var cache: CacheEngine {
        if let local = local {
            return local
        } else if let http = http {
            return http
        } else {
            log.fatal("At least one cache engine must be specified")
        }
    }

    func downloadUrl(for product: String, version: String) -> URL {
        return cache.downloadUrl(for: product, version: version)
    }

    func exists(product: String, version: String) -> AnyPublisher<Bool, Error> {
        log.verbose("Checking if \(product)-\(version) exists")
        return cache.exists(product: product, version: version)
    }

    func get(product: String, version: String, destination: Path) -> AnyPublisher<Path, Error> {
        log.verbose("Fetching \(product)-\(version)")
        return cache.get(product: product, version: version, destination: destination)
    }

    func put(product: String, version: String, path: Path) -> AnyPublisher<(), Error> {
        log.verbose("Caching \(product)-\(version)")
        return cache.put(product: product, version: version, path: path)
    }
}

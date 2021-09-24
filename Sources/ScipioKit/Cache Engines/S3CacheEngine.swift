import Combine
import Foundation
import PathKit

public struct S3CacheEngine: HTTPCacheEngineProtocol, Decodable, Equatable {

    public let bucket: String
    public let path: String?
    public let cdnUrl: URL?

    public var uploadBaseUrl: URL {
        return bucketS3Url
    }

    public var downloadBaseUrl: URL {
        return bucketUrl
    }

    public let urlSession: URLSession = .createWithExtensionsSupport()

    private var bucketUrl: URL {
        if let url = cdnUrl {
            if let path = path {
                return url
                    .appendingPathComponent(path)
            } else {
                return url
            }
        } else {
            return bucketS3Url
        }
    }

    private var bucketS3Url: URL {
        let baseUrl = URL(string: "https://\(bucket).s3.amazonaws.com")!

        if let path = path {
            return baseUrl
                .appendingPathComponent(path)
        } else {
            return baseUrl
        }
    }

    enum CodingKeys: String, CodingKey {
        case bucket
        case path
        case cdnUrl
    }

    public func uploadUrlRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)

        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = [
            "Content-Type": "application/zip",
            "x-amz-acl": "bucket-owner-full-control",
        ]

        return request
    }
}

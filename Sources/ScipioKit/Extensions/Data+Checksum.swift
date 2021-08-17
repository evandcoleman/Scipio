import CryptoKit
import Foundation

extension Data {
    enum ChecksumStrategy {
        case sha256
    }

    func checksum(_ strategy: ChecksumStrategy) -> String {
        switch strategy {
        case .sha256:
            return SHA256.hash(data: self)
                .compactMap { String(format: "%02x", $0) }
                .joined()
        }
    }
}

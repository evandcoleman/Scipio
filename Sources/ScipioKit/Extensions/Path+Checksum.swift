import CommonCrypto
import Foundation
import PathKit

extension Path {
    func checksum(_ strategy: Data.ChecksumStrategy) throws -> String {
        return try read().checksum(strategy)
    }
}

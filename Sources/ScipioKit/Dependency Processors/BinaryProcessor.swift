import Foundation
import PathKit
import Zip

import Basics

public class BinaryProcessor: DownloadProcessor<BinaryDependency> {

    public enum Error: LocalizedError {
        case missingVersion

        public var errorDescription: String? {
            switch self {
            case .missingVersion:
                return "version is required for binary dependencies"
            }
        }
    }

    override public var directoryName: String {
        return "Binaries"
    }

    override public func preProcess() async throws -> [DownloadProduct] {
        log.info("🔗  Processing binary dependencies...")

        return try await super.preProcess()
    }

    override public func getDownloadUrl(dependency: BinaryDependency) async throws -> (version: String, url: URL) {
        guard let version = dependency.version else {
            throw Error.missingVersion
        }

        return (version, dependency.url)
    }
}

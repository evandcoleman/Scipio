import Foundation
import PathKit
@testable import ScipioKit

extension CachedArtifact {
    static func mock(name: String, parentName: String) throws -> CachedArtifact {
        let path = try Path.temporaryForTests() + "\(name).xcframework.zip"

        if path.exists {
            try path.delete()
        }

        try path.write("\(parentName)-\(name)")

        return try CachedArtifact(
            name: name,
            parentName: parentName,
            url: URL(string: "https://scipio.test/packages/\(name)/\(name).xcframework.zip")!,
            localPath: path
        )
    }
}

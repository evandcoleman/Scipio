import Foundation
import PathKit
import SWCompression

extension Path {
    func gunzipped() throws -> Path {
        let outPath = parent() + lastComponentWithoutExtension
        try outPath.write(try GzipArchive.unarchive(archive: try read()))

        return outPath
    }
}

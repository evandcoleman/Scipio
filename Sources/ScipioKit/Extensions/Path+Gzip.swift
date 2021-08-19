import Foundation
import Gzip
import PathKit

extension Path {
    func gunzipped() throws -> Path {
        let outPath = parent() + lastComponentWithoutExtension
        try outPath.write(try read().gunzipped())

        return outPath
    }
}

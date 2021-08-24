import Foundation
import PathKit
@testable import ScipioKit
import XCTest

extension XCTest {
    func setupConfig(_ config: Config = .init(name: "TestProject", cache: LocalCacheEngine(path: Path.temporary + "TestProjectCache"), deploymentTarget: ["iOS": "12.0"])) {
        Config.current = config
    }
}

import PathKit
@testable import ScipioKit
import XCTest

final class ConfigTests: XCTestCase {
    func testReadConfig() throws {
        let configText = """
        name: Test
        deploymentTarget:
          iOS: "12.0"
        cache:
          local:
            path: ~/Desktop/TestCache
        packages:
            - name: SnapKit
              url: https://github.com/SnapKit/SnapKit
              branch: 5.0.0
            - name: SwiftyJSON
              url: https://github.com/SwiftyJSON/SwiftyJSON
              from: 5.0.0
        """
        let path = Path.temporary + "scipio.yml"
        try path.write(configText)
        let config = Config.readConfig(from: path)

        XCTAssertEqual(config.packages?.count, 2)
        XCTAssertEqual(config.name, "Test")
        XCTAssertEqual(config.platformVersions, [.iOS: "12.0"])
        XCTAssertNotNil(config.packages?.contains { $0.name == "SnapKit" })
        XCTAssertNotNil(config.packages?.contains { $0.name == "SwiftyJSON" })
    }
}

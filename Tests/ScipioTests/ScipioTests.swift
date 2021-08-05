import PathKit
@testable import ScipioKit
import XCTest

final class ConfigTests: XCTestCase {
    func testReadConfig() throws {
        let configText = """
        packages:
          Facebook:
            products:
              - FacebookCore
          Firebase:
            products:
              - target: FirebaseAnalytics
              - FirebaseAuth
        """
        let path = Path.temporary + "scipio.yml"
        try path.write(configText)
        let config = Config.readConfig(from: path)

        XCTAssertEqual(config.packages.count, 2)
        XCTAssertNotNil(config.packages["Facebook"])
        XCTAssertNotNil(config.packages["Firebase"])
        XCTAssertEqual(config.packages["Facebook"]?.products, [Config.Product.scheme("FacebookCore")])
        XCTAssertEqual(config.packages["Firebase"]?.products, [Config.Product.target("FirebaseAnalytics"), Config.Product.scheme("FirebaseAuth")])
    }
}

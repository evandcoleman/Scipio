// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "Test",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(name: "Alamofire", targets: ["Alamofire"])
    ],
    targets: [
        .binaryTarget(
            name: "Alamofire",
            path: "Alamofire/Alamofire-78424be314842833c04bc3bef5b72e85fff99204.xcframework"
        )
    ]
)
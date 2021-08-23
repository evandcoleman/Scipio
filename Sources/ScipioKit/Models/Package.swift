//import Combine
//import Foundation
//import Gzip
//import PathKit
//import ProjectSpec
//import Regex
//import XcodeGenKit
//import XcodeProj
//import Zip
//
//public struct Package {
//
//
//
//    public func upload(parent: Package, force: Bool) -> AnyPublisher<(), Error> {
//        return productNames()
//            .flatMap { $0.flatMap(\.value).publisher }
//            .flatMap { product -> AnyPublisher<(String, Bool), Error> in
//                guard !force else {
//                    return Just((product, true))
//                        .setFailureType(to: Error.self)
//                        .eraseToAnyPublisher()
//                }
//
//                return Config.current.cache
//                    .exists(product: product, version: self.version)
//                    .flatMap { exists -> AnyPublisher<Bool, Error> in
//                        if exists, !self.compressedPath(for: product).exists {
//                            return Config.current.cache
//                                .get(
//                                    product: product,
//                                    version: self.version,
//                                    destination: self.compressedPath(for: product)
//                                )
//                                .map { _ in exists }
//                                .eraseToAnyPublisher()
//                        } else {
//                            return Just(exists)
//                                .setFailureType(to: Error.self)
//                                .eraseToAnyPublisher()
//                        }
//                    }
//                    .filter { _ in self.artifactPath(for: product).exists || self.compressedPath(for: product).exists }
//                    .map { (product, !$0) }
//                    .eraseToAnyPublisher()
//            }
//            .tryFlatMap { product, shouldUpload -> AnyPublisher<(), Error> in
//                let frameworkPath = self.artifactPath(for: product)
//                let zipPath = self.compressedPath(for: product)
//
//                if frameworkPath.exists, !zipPath.exists {
//                    do {
//                        try Zip.zipFiles(paths: [frameworkPath.url], zipFilePath: zipPath.url, password: nil, progress: { log.progress("Compressing \(frameworkPath.lastComponent)", percent: $0) })
//                    } catch ZipError.zipFail {
//                        throw UploadError.zipFailed(product: product, path: frameworkPath)
//                    }
//                }
//
//                let url = Config.current.cache.downloadUrl(for: product, version: self.version)
//                let checksum = try zipPath.checksum(.sha256)
//
//                let uploadOrNotPublisher: AnyPublisher<(), Error>
//                if shouldUpload {
//                    log.info("☁️ Uploading \(product)...")
//                    uploadOrNotPublisher = Config.current.cache
//                        .put(product: product, version: self.version, path: zipPath)
//                } else {
//                    uploadOrNotPublisher = Just(())
//                        .setFailureType(to: Error.self)
//                        .eraseToAnyPublisher()
//                }
//
//                return uploadOrNotPublisher
//                    .tryMap { value in
//                        switch parent.description {
//                        case .package(let manifest):
//                            let target = manifest.targets.first { $0.name == product }
//                            let manifestPath = parent.path + "Package.swift"
//                            var packageContents: String = try manifestPath.read()
//
//                            if let target = target, target.checksum != checksum {
//                                log.info("✍️ Updating checksum for \(product) because they do not match...")
//
//                                if url.isFileURL {
//                                    let regex = try Regex(string: #"(\.binaryTarget\([\n\r\s]+name\s?:\s"\#(product)"\s?,[\n\r\s]+path:\s?)"(.*)""#)
//
//                                    packageContents = packageContents.replacingFirst(
//                                        matching: regex,
//                                        with: #"$1"\#(url.path)"$3"#
//                                    )
//                                } else {
//                                    let regex = try Regex(string: #"(\.binaryTarget\([\n\r\s]+name\s?:\s"\#(product)"\s?,[\n\r\s]+url:\s?)"(.*)"(\s?,[\n\r\s]+checksum:\s?)"(.*)""#)
//
//                                    packageContents = packageContents.replacingFirst(
//                                        matching: regex,
//                                        with: #"$1"\#(url)"$3"\#(checksum)""#
//                                    )
//                                }
//                            } else if target == nil {
//                                self.addProduct(product, to: &packageContents)
//
//                                let allTargetMatches = Regex(#"(\.binaryTarget\([\n\r\s]*name\s?:\s"[A-Za-z]*"[^,]*,[^,]*,[^,]*,)"#).allMatches(in: packageContents)
//                                packageContents.insert(contentsOf: "\n        .binaryTarget(\n            name: \"\(product)\",\n            url: \"\(url)\",\n            checksum: \"\(checksum)\"\n        ),", at: allTargetMatches.last!.range.upperBound)
//                            }
//
//                            try manifestPath.write(packageContents)
//                        default:
//                            log.fatal("Parent package must be a Swift package")
//                        }
//
//                        return value
//                    }
//                    .eraseToAnyPublisher()
//            }
//            .eraseToAnyPublisher()
//    }
//
//
//    internal func missingProducts() -> AnyPublisher<[String], Error> {
//        return productNames()
//            .flatMap { $0.flatMap(\.value).publisher }
//            .flatMap { product -> AnyPublisher<String, Error> in
//                if self.artifactPath(for: product).exists {
//                    return Empty()
//                        .setFailureType(to: Error.self)
//                        .eraseToAnyPublisher()
//                }
//
//                return Config.current.cache
//                    .exists(product: product, version: version)
//                    .filter { !$0 }
//                    .map { _ in product }
//                    .eraseToAnyPublisher()
//            }
//            .collect()
//            .eraseToAnyPublisher()
//    }
//
//
//    private func addProduct(_ product: String, targets: [String]? = nil, dynamic: Bool = false, to packageContents: inout String) {
//        let allProductMatches = Regex(#"(\.library\([\n\r\s]*name\s?:\s"[A-Za-z]*"[^,]*,[^,]*,)"#).allMatches(in: packageContents)
//        packageContents.insert(contentsOf: ".library(name: \"\(product)\", \(dynamic ? "type: .dynamic, " : "")targets: [\((targets ?? [product]).map { "\"\($0)\"" }.joined(separator: ", "))]),\n", at: allProductMatches.first!.range.lowerBound)
//    }
//
//
//
//    private func artifactPath(for product: String) -> Path {
//        return Config.current.buildPath + "\(product).xcframework"
//    }
//
//    private func compressedPath(for product: String) -> Path {
//        return Config.current.buildPath + "\(product).xcframework.zip"
//    }
//}

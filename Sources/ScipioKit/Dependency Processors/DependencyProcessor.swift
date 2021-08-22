import Combine
import Foundation
import PathKit

public protocol DependencyProcessor {
    associatedtype Input: Dependency

    init(dependencies: [Input], options: ProcessorOptions)
//    func shouldBuild(_ dependency: Input) -> AnyPublisher<Bool, Error>
//    func shouldUpload(_ dependency: Input) -> AnyPublisher<Bool, Error>
    func process() -> AnyPublisher<[Path], Error>
}

public struct ProcessorOptions {
    public let platform: Platform
    public let skipClean: Bool
    public let forceBuild: Bool
    public let forceUpload: Bool

    public init(platform: Platform, skipClean: Bool, forceBuild: Bool, forceUpload: Bool) {
        self.platform = platform
        self.skipClean = skipClean
        self.forceBuild = forceBuild
        self.forceUpload = forceUpload
    }
}

import Foundation
import PathKit

import PackageModel

//public struct SwiftPackageDescriptor: DependencyProducts {
//
//    public let name: String
//    public let version: String
//    public let path: Path
//    public let buildables: [SwiftPackageBuildable]
//
//    public var productNames: [String]? {
//        return buildables.map(\.name)
//    }
//
//    public init(path: Path, name: String, version: String) throws {
//        self.name = name
//        self.path = path
//        self.buildables = manifest.getBuildables()
//        self.version = version
//    }
//
//    public func version(for productName: String) -> String {
//        return version
//    }
//}
//
//extension Manifest {
//
//    public func getBuildables() -> [SwiftPackageBuildable] {
//        return products
//            .filter { $0.type.isLibrary }
//            .flatMap { getBuildables(in: $0) }
//            .uniqued()
//    }
//
//    private func getBuildables(in product: ProductDescription) -> [SwiftPackageBuildable] {
//        let targets = recursiveTargets(in: product)
//
//        return targets
//            .compactMap { target -> SwiftPackageBuildable? in
//                let dependencies = target.dependencies.map(\.name)
//
//                if target.type == .binary {
//                    return .binaryTarget(target)
//                } else if dependencies.count == 1,
//                          targets.first(where: { $0.name == dependencies[0] })?.type == .binary {
//
//                    return nil
//                } else {
//                    return .target(target.name)
//                }
//            }
//    }
//
//    private func recursiveTargets(in product: ProductDescription) -> [TargetDescription] {
//        return product
//            .targets
//            .compactMap { target in targets.first { $0.name == target } }
//            .flatMap { recursiveTargets(in: $0) }
//    }
//
//    private func recursiveTargets(in target: TargetDescription) -> [TargetDescription] {
//        return [target] + target
//            .dependencies
//            .flatMap { recursiveTargets(in: $0, target: target) }
//    }
//
//    private func recursiveTargets(
//        in dependency: TargetDescription.Dependency,
//        target: TargetDescription
//    ) -> [TargetDescription] {
//        let resolvedTarget = targets.first { $0.name == dependency.name }
//
//        if let resolvedTarget {
//            return recursiveTargets(in: resolvedTarget)
//        }
//
//        return [target]
//    }
//}

extension TargetDescription.Dependency {

    var name: String {
        switch self {
        case .byName(let name, _):
            return name
        case .target(let name, _):
            return name
        case .product(let name, _, _, _):
            return name
        }
    }

    var package: String? {
        switch self {
        case .product(_, let package, _, _):
            return package
        case .byName, .target:
            return nil
        }
    }
}

public enum SwiftPackageBuildable: Equatable, Hashable {
    case target(String, buildName: String? = nil)
    case binaryTarget(TargetDescription)

    public var buildName: String {
        switch self {
        case .target(let name, let buildName):
            return buildName ?? name
        case .binaryTarget:
            return name
        }
    }

    public var name: String {
        switch self {
        case .target(let name, _):
            return name
        case .binaryTarget(let target):
            if let urlString = target.url, let url = URL(string: urlString) {
                return url.lastPathComponent
                    .components(separatedBy: ".")[0]
            } else if let path = target.path {
                return Path(path).lastComponent
                    .components(separatedBy: ".")[0]
            } else {
                return target.name
            }
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .target(let name, let buildName):
            hasher.combine("target")
            hasher.combine(name)
            hasher.combine(buildName)
        case .binaryTarget(let target):
            hasher.combine("binaryTarget")
            hasher.combine(target.name)
        }
    }
}

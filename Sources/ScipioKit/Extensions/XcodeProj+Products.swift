import PathKit
import XcodeProj

extension XcodeProj {
    var productNames: [String] {
        return pbxproj
            .groups
            .first { $0.name == "Products" }?
            .children
            .compactMap { $0.name?.components(separatedBy: ".").first } ?? []
    }

    func productNames(for targetName: String) -> [String] {
        return pbxproj
            .targets(named: targetName)
            .flatMap { [Path($0.product?.nameOrPath ?? "").lastComponentWithoutExtension] + $0.dependencies.compactMap { $0.target?.product?.nameOrPath }.map { Path($0).lastComponentWithoutExtension } }
            .compactMap { $0 }
    }
}

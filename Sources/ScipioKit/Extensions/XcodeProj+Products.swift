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
            .flatMap { [$0.productName] + $0.dependencies.compactMap { $0.target?.productName } }
            .compactMap { $0 }
    }
}

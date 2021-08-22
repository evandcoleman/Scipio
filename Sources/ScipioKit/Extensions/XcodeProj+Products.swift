import XcodeProj

extension XcodeProj {
    var productNames: [String] {
        return pbxproj
            .groups
            .first { $0.name == "Products" }?
            .children
            .compactMap { $0.name?.components(separatedBy: ".").first } ?? []
    }
}

import PathKit
import XcodeProj

enum ProjectProduct: Hashable {
    case product(String)
    case path(Path)

    var name: String {
        switch self {
        case .product(let name):
            return name
        case .path(let path):
            return path.lastComponentWithoutExtension
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

extension XcodeProj {
    var productNames: [String] {
        return pbxproj
            .groups
            .first { $0.name == "Products" }?
            .children
            .compactMap { $0.name?.components(separatedBy: ".").first } ?? []
    }

    func productNames(for targetName: String, podsRoot: Path) -> [ProjectProduct] {
        return pbxproj
            .targets(named: targetName)
            .flatMap { $0.productNames(podsRoot: podsRoot) }
            .filter { !$0.name.isEmpty }
            .uniqued()
    }
}

extension PBXTarget {
    func productNames(podsRoot: Path) -> [ProjectProduct] {
        var names: [ProjectProduct] = []

        if let productPath = product?.path {
            names <<< .product(Path(productPath).lastComponentWithoutExtension)
        }

        if let aggregateTarget = self as? PBXAggregateTarget {
            let vendoredFrameworkNames = aggregateTarget
                .buildPhases
                .flatMap { $0.inputFileListPaths ?? [] }
                .flatMap { path -> [ProjectProduct] in
                    let fixedPath = path
                        .replacingOccurrences(of: "${PODS_ROOT}/", with: "")
                        .replacingOccurrences(of: "$PODS_ROOT/", with: "")
                    let contents = (try? (podsRoot + Path(fixedPath)).read()) ?? ""

                    return contents
                        .components(separatedBy: "\n")
                        .compactMap { pathString in
                            let path = podsRoot + Path(
                                pathString
                                    .replacingOccurrences(of: "${PODS_ROOT}/", with: "")
                                    .replacingOccurrences(of: "$PODS_ROOT/", with: "")
                            )

                            return path.extension == "xcframework" ? .path(path) : nil
                        }
                }

            names <<< vendoredFrameworkNames
        }

        for dependency in dependencies {
            if let target = dependency.target {
                names <<< target.productNames(podsRoot: podsRoot)
            }
        }

        return names
    }
}

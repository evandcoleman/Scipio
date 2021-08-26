import Foundation
import PathKit
import SWCompression

public extension Path {
    func untar() throws -> Path {
        let path = parent() + lastComponentWithoutExtension
        let entries = try TarContainer.open(container: try read())

        try createFilesAndDirectories(
            path: path,
            entries: entries
        )

        return path
    }

    private func createFilesAndDirectories(path: Path, entries: [TarEntry]) throws {
        for entry in entries {
            let entryPath = (path + entry.info.name)
                .normalize()

            log.debug(entryPath.string)

            switch entry.info.type {
            case .regular:
                try entryPath.write(entry.data ?? Data())
            case .directory:
                try entryPath.mkpath()
            case .symbolicLink:
                let linkPath = (path + entry.info.linkName).normalize()
                try linkPath.symlink(entryPath)
            case .hardLink:
                let linkPath = (path + entry.info.linkName).normalize()
                try linkPath.link(entryPath)
            default:
                break
            }
        }
    }
}

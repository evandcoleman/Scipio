//
//  GithubReleaseProcessor.swift
//
//
//  Created by Evan Coleman on 8/21/24.
//

import Foundation
import PathKit

public final class GithubReleaseProcessor: DownloadProcessor<GithubReleaseDependency> {

    override public var directoryName: String {
        return "GithubReleases"
    }

    override public func preProcess() async throws -> [DownloadProduct] {
        log.info("🧑‍💻  Processing Github Release dependencies...")

        return try await super.preProcess()
    }

    override public func getDownloadUrl(
        dependency: GithubReleaseDependency
    ) async throws -> (version: String, url: URL) {
        let releaseArtifact = try await findGitHubReleaseArtifact(
            orgRepo: dependency.repo,
            version: dependency.version,
            filename: dependency.filename
        )

        return (releaseArtifact.version, releaseArtifact.downloadURL)
    }

    enum GitHubError: Error {
        case invalidURL
        case releaseNotFound
        case artifactNotFound
    }

    struct GitHubReleaseArtifact {
        let downloadURL: URL
        let version: String
    }

    private func findGitHubReleaseArtifact(
        orgRepo: String,
        version: String?,
        filename: String
    ) async throws -> GitHubReleaseArtifact {
        let session = URLSession.shared
        let releaseAPI: String

        if let version = version {
            releaseAPI = "https://api.github.com/repos/\(orgRepo)/releases/tags/\(version)"
        } else {
            releaseAPI = "https://api.github.com/repos/\(orgRepo)/releases/latest"
        }

        guard let url = URL(string: releaseAPI) else {
            throw GitHubError.invalidURL
        }

        let (data, _) = try await session.data(from: url)

        if
            let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let assets = json["assets"] as? [[String: Any]],
            let tagName = json["tag_name"] as? String
        {

            if
                let asset = assets.first(where: { $0["name"] as? String == filename }),
                let downloadURLString = asset["browser_download_url"] as? String,
                let downloadURL = URL(string: downloadURLString)
            {

                return GitHubReleaseArtifact(
                    downloadURL: downloadURL,
                    version: tagName
                )
            } else {
                throw GitHubError.artifactNotFound
            }
        } else {
            throw GitHubError.releaseNotFound
        }
    }
}

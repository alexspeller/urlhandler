import Foundation

public struct ChromeProfile: Equatable, Sendable {
    /// On-disk directory name — the value to use as `profile` in config.json ("Default", "Profile 1", ...).
    public let directory: String
    /// User-facing display name from Chrome's Local State.
    public let name: String
}

/// Discovers Chrome profiles from `~/Library/Application Support/Google/Chrome/Local State`,
/// whose `profile.info_cache` maps each on-disk directory name to a display name.
public enum ChromeProfiles {
    public static var chromeLocalStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    }

    public static func list(localState url: URL = chromeLocalStateURL) throws -> [ChromeProfile] {
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> [ChromeProfile] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else {
            return []
        }
        return cache
            .map { directory, info in
                let name = (info as? [String: Any])?["name"] as? String
                return ChromeProfile(directory: directory, name: name ?? directory)
            }
            .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
    }
}

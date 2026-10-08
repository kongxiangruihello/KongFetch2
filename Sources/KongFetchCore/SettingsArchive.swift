import Foundation

/// A file holding KongFetch's settings and snippets, for moving them to another Mac or keeping a copy.
/// Clipboard history, recent items and indexes are never included.
public struct SettingsArchive {
    public static let fileExtension = "kfsettings"
    public static let keyPrefix = "kf4."
    /// Facts about this Mac rather than choices, which the other Mac must work out for itself.
    public static let machineSpecificKeys: Set<String> = ["kf4.folderAccessRequested", "kf4.hasCompletedFirstLaunch"]

    public var defaults: [String: Any]
    public var snippets: [TextSnippet]
    public var created: Date
    public var appVersion: String

    public init(defaults: [String: Any], snippets: [TextSnippet], created: Date = Date(), appVersion: String) {
        self.defaults = defaults.filter { Self.isTransferable($0.key) }
        self.snippets = snippets
        self.created = created
        self.appVersion = appVersion
    }

    public static func isTransferable(_ key: String) -> Bool {
        key.hasPrefix(keyPrefix) && !machineSpecificKeys.contains(key)
    }

    public enum ArchiveError: LocalizedError {
        case unreadable
        case notKongFetch

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取这个文件。"
            case .notKongFetch: return "这不是 KongFetch 导出的设置文件。"
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plist: [String: Any] = [
            "format": "KongFetch settings",
            "version": 1,
            "appVersion": appVersion,
            "created": created,
            "defaults": defaults,
            "snippets": try encoder.encode(snippets)
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public static func decode(_ data: Data) throws -> SettingsArchive {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ArchiveError.unreadable
        }
        guard plist["format"] as? String == "KongFetch settings", let defaults = plist["defaults"] as? [String: Any] else {
            throw ArchiveError.notKongFetch
        }
        var snippets: [TextSnippet] = []
        if let data = plist["snippets"] as? Data {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snippets = (try? decoder.decode([TextSnippet].self, from: data)) ?? []
        }
        return SettingsArchive(defaults: defaults, snippets: snippets,
                               created: plist["created"] as? Date ?? Date(), appVersion: plist["appVersion"] as? String ?? "?")
    }
}

import Foundation
import Combine
import KongFetchCore

/// User settings, persisted in UserDefaults under the "kf4." prefix
/// so they never collide with the old KongFetch 3.x keys.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults

    @Published var searchShortcut: Shortcut? { didSet { store(searchShortcut, "searchShortcut") } }
    @Published var clipboardShortcut: Shortcut? { didSet { store(clipboardShortcut, "clipboardShortcut") } }
    @Published var doubleTapModifier: TapModifier { didSet { defaults.set(doubleTapModifier.rawValue, forKey: key("doubleTapModifier")) } }

    @Published var excludedPathPrefixes: [String] { didSet { defaults.set(excludedPathPrefixes, forKey: key("excludedPathPrefixes")) } }
    @Published var includeLibraryFolders: Bool { didSet { defaults.set(includeLibraryFolders, forKey: key("includeLibraryFolders")) } }

    @Published var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: key("clipboardEnabled")) } }
    @Published var clipboardPaused: Bool { didSet { defaults.set(clipboardPaused, forKey: key("clipboardPaused")) } }
    /// 0 keeps unpinned entries forever.
    @Published var clipboardRetentionDays: Int { didSet { defaults.set(clipboardRetentionDays, forKey: key("clipboardRetentionDays")) } }
    @Published var clipboardMaximumItems: Int { didSet { defaults.set(clipboardMaximumItems, forKey: key("clipboardMaximumItems")) } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: key("autoPaste")) } }
    @Published var clipboardExcludedApps: [String] { didSet { defaults.set(clipboardExcludedApps, forKey: key("clipboardExcludedApps")) } }

    @Published var hasCompletedFirstLaunch: Bool { didSet { defaults.set(hasCompletedFirstLaunch, forKey: key("hasCompletedFirstLaunch")) } }
    /// Whether KongFetch has asked for access to Documents, Desktop, Downloads and iCloud Drive.
    @Published var folderAccessRequested: Bool { didSet { defaults.set(folderAccessRequested, forKey: key("folderAccessRequested")) } }

    static let defaultExcludedApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.dashlane.Dashlane", "com.apple.Passwords", "com.apple.keychainaccess", "org.keepassxc.keepassxc"
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ name: String, _ fallback: T) -> T { defaults.object(forKey: "kf4." + name) as? T ?? fallback }

        searchShortcut = Self.loadShortcut(defaults, "searchShortcut") ?? Shortcut.defaultSearch
        clipboardShortcut = Self.loadShortcut(defaults, "clipboardShortcut") ?? Shortcut.defaultClipboard
        doubleTapModifier = TapModifier(rawValue: value("doubleTapModifier", "control")) ?? .control
        excludedPathPrefixes = value("excludedPathPrefixes", [String]())
        includeLibraryFolders = value("includeLibraryFolders", false)
        clipboardEnabled = value("clipboardEnabled", false)
        clipboardPaused = value("clipboardPaused", false)
        clipboardRetentionDays = value("clipboardRetentionDays", 30)
        clipboardMaximumItems = value("clipboardMaximumItems", 300)
        autoPaste = value("autoPaste", true)
        clipboardExcludedApps = value("clipboardExcludedApps", Self.defaultExcludedApps)
        hasCompletedFirstLaunch = value("hasCompletedFirstLaunch", false)
        folderAccessRequested = value("folderAccessRequested", false)
    }

    var clipboardLimits: ClipboardHistory.Limits {
        ClipboardHistory.Limits(maximumItems: max(20, min(clipboardMaximumItems, 2000)),
                                retentionDays: clipboardRetentionDays > 0 ? clipboardRetentionDays : nil)
    }

    private func key(_ name: String) -> String { "kf4." + name }

    /// A cleared shortcut is stored as an explicit "none" so it is not replaced by the default on the next launch.
    private func store(_ shortcut: Shortcut?, _ name: String) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key(name))
        } else {
            defaults.set(Data("none".utf8), forKey: key(name))
        }
    }

    private static func loadShortcut(_ defaults: UserDefaults, _ name: String) -> Shortcut?? {
        guard let data = defaults.data(forKey: "kf4." + name) else { return nil }
        if data == Data("none".utf8) { return .some(nil) }
        return (try? JSONDecoder().decode(Shortcut.self, from: data)).map { .some($0) }
    }
}

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
    /// Keep a pinyin index of file names in Documents, Desktop, Downloads, iCloud Drive and the extra folders.
    @Published var pinyinIndexEnabled: Bool { didSet { defaults.set(pinyinIndexEnabled, forKey: key("pinyinIndexEnabled")) } }
    @Published var pinyinIndexExtraRoots: [String] { didSet { defaults.set(pinyinIndexExtraRoots, forKey: key("pinyinIndexExtraRoots")) } }

    @Published var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: key("clipboardEnabled")) } }
    @Published var clipboardPaused: Bool { didSet { defaults.set(clipboardPaused, forKey: key("clipboardPaused")) } }
    /// 0 keeps unpinned entries forever.
    @Published var clipboardRetentionDays: Int { didSet { defaults.set(clipboardRetentionDays, forKey: key("clipboardRetentionDays")) } }
    @Published var clipboardMaximumItems: Int { didSet { defaults.set(clipboardMaximumItems, forKey: key("clipboardMaximumItems")) } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: key("autoPaste")) } }
    /// Recognize text in copied pictures.
    @Published var clipboardOCR: Bool { didSet { defaults.set(clipboardOCR, forKey: key("clipboardOCR")) } }
    @Published var ocrEnabled: Bool { didSet { defaults.set(ocrEnabled, forKey: key("ocrEnabled")) } }
    /// Folders whose scanned PDFs and images are recognized for full-text search.
    @Published var ocrFolders: [String] { didSet { defaults.set(ocrFolders, forKey: key("ocrFolders")) } }
    @Published var ocrPageLimit: Int { didSet { defaults.set(ocrPageLimit, forKey: key("ocrPageLimit")) } }
    @Published var ocrOnlyOnPower: Bool { didSet { defaults.set(ocrOnlyOnPower, forKey: key("ocrOnlyOnPower")) } }
    @Published var ocrDownloadFromICloud: Bool { didSet { defaults.set(ocrDownloadFromICloud, forKey: key("ocrDownloadFromICloud")) } }
    @Published var clipboardExcludedApps: [String] { didSet { defaults.set(clipboardExcludedApps, forKey: key("clipboardExcludedApps")) } }
    /// What "整理后粘贴" (⌘J in the clipboard window) does.
    @Published var cleanupOperations: [TextCleanup.Operation] {
        didSet { defaults.set(cleanupOperations.map(\.rawValue), forKey: key("cleanupOperations")) }
    }
    /// Expand snippet keywords typed in any app.
    @Published var snippetExpansion: Bool { didSet { defaults.set(snippetExpansion, forKey: key("snippetExpansion")) } }
    /// Web searches reached by a keyword in the search window.
    @Published var quickLinks: [QuickLink] {
        didSet { if let data = try? JSONEncoder().encode(quickLinks) { defaults.set(data, forKey: key("quickLinks")) } }
    }

    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: key("autoCheckUpdates")) } }
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
        pinyinIndexEnabled = value("pinyinIndexEnabled", true)
        pinyinIndexExtraRoots = value("pinyinIndexExtraRoots", [String]())
        clipboardEnabled = value("clipboardEnabled", false)
        clipboardPaused = value("clipboardPaused", false)
        clipboardRetentionDays = value("clipboardRetentionDays", 30)
        clipboardMaximumItems = value("clipboardMaximumItems", 300)
        autoPaste = value("autoPaste", true)
        clipboardExcludedApps = value("clipboardExcludedApps", Self.defaultExcludedApps)
        clipboardOCR = value("clipboardOCR", true)
        ocrEnabled = value("ocrEnabled", true)
        ocrFolders = value("ocrFolders", [String]())
        ocrPageLimit = value("ocrPageLimit", 200)
        ocrOnlyOnPower = value("ocrOnlyOnPower", true)
        ocrDownloadFromICloud = value("ocrDownloadFromICloud", false)
        cleanupOperations = (defaults.array(forKey: "kf4.cleanupOperations") as? [String])?
            .compactMap(TextCleanup.Operation.init(rawValue:)) ?? TextCleanup.defaultOperations
        quickLinks = defaults.data(forKey: "kf4.quickLinks").flatMap { try? JSONDecoder().decode([QuickLink].self, from: $0) }
            ?? QuickLinks.defaults
        snippetExpansion = value("snippetExpansion", true)
        hasCompletedFirstLaunch = value("hasCompletedFirstLaunch", false)
        autoCheckUpdates = value("autoCheckUpdates", true)
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

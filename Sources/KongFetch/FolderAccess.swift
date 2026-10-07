import AppKit

/// macOS hides Spotlight results in protected folders (Documents, Desktop, Downloads, iCloud Drive)
/// from apps that have not been allowed into them. Touching each folder once makes the system ask.
enum FolderAccess {
    struct Folder: Identifiable, Equatable {
        let id: String
        let title: String
        let url: URL
    }

    static var folders: [Folder] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Folder(id: "documents", title: "文稿", url: home.appendingPathComponent("Documents")),
            Folder(id: "desktop", title: "桌面", url: home.appendingPathComponent("Desktop")),
            Folder(id: "downloads", title: "下载", url: home.appendingPathComponent("Downloads")),
            Folder(id: "icloud", title: "iCloud 云盘", url: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))
        ].filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Lists each folder, which shows the system prompt the first time. Returns folder id → allowed.
    @discardableResult
    static func requestAll() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for folder in folders {
            result[folder.id] = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) != nil
        }
        return result
    }

    /// Current state without prompting. Only meaningful after `requestAll()` has run once,
    /// because before that macOS has not decided yet.
    static func currentState() -> [String: Bool] {
        requestAll()
    }

    static var hasFullDiskAccess: Bool {
        // A file only readable with Full Disk Access.
        let probe = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
        return FileManager.default.isReadableFile(atPath: probe.path) && (try? Data(contentsOf: probe, options: .mappedIfSafe)) != nil
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openFilesAndFoldersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}

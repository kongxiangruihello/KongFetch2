import AppKit
import CoreServices
import KongFetchCore

/// Definitions from the dictionaries enabled in the Dictionary app (现代汉语、牛津英汉汉英…).
enum DictionaryLookup {
    /// The search-window keyword: "cd 仁".
    static let keyword = "cd"

    /// The word after "cd ", if the text starts with it.
    static func word(in text: String) -> String? {
        let trimmed = text.drop { $0 == " " }
        guard trimmed.lowercased().hasPrefix(keyword + " ") || trimmed.lowercased().hasPrefix(keyword + "\u{3000}") else { return nil }
        let word = trimmed.dropFirst(keyword.count + 1).trimmingCharacters(in: .whitespaces)
        return word.isEmpty ? nil : word
    }

    static func definition(of word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = CFRange(location: 0, length: (trimmed as NSString).length)
        guard let definition = DCSCopyTextDefinition(nil, trimmed as CFString, range)?.takeRetainedValue() else { return nil }
        let text = (definition as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func openInDictionaryApp(_ word: String) {
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        guard let url = URL(string: "dict://" + encoded) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration)
    }
}

/// The text selected in the frontmost app.
enum SelectedText {
    /// Reads the selection through Accessibility; apps that do not expose it are asked to copy (⌘C),
    /// and the clipboard is put back afterwards. Calls back on the main thread.
    static func fetch(monitor: ClipboardMonitor, completion: @escaping (String?) -> Void) {
        if let text = accessibilitySelection() {
            completion(text)
            return
        }
        guard Paster.isTrusted else { completion(nil); return }
        let pasteboard = NSPasteboard.general
        let saved = SnippetExpansionService.copyItems(of: pasteboard)
        let before = pasteboard.changeCount
        monitor.ignoreChanges(for: 1.5)
        SnippetExpansionService.post(key: CGKeyCode(8), flags: .maskCommand) // ⌘C (kVK_ANSI_C)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard pasteboard.changeCount != before else { completion(nil); return }
            let text = pasteboard.string(forType: .string)
            monitor.restoreItems(saved)
            completion(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil)
        }
    }

    private static func accessibilitySelection() -> String? {
        guard Paster.isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// KongReview (the user's highlight and review app) takes text through kongreview://add links.
enum KongReviewLink {
    static let bundleIdentifier = "com.kongxiangrui.KongReview"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// Opens KongReview's quick-capture window filled in with `text` (nothing is saved until the user confirms there).
    @discardableResult
    static func send(text: String, title: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var parts = ["text=" + QuickLink.encode(String(trimmed.prefix(20_000)))]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            parts.append("title=" + QuickLink.encode(title))
        }
        guard let url = URL(string: "kongreview://add?" + parts.joined(separator: "&")) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration)
        return true
    }

    /// The document name in the frontmost window's title (a PDF, EPUB, Word file…), as the source.
    static func frontWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        // "论语译注.pdf – 第 3 页" → "论语译注". Titles that are not a document's file name ("未命名", a web
        // page) are left out rather than becoming a wrong source.
        let first = title.components(separatedBy: CharacterSet(charactersIn: "–—|")).first?.trimmingCharacters(in: .whitespaces) ?? title
        let ext = (first as NSString).pathExtension.lowercased()
        let documentTypes: Set<String> = ["pdf", "epub", "doc", "docx", "pages", "txt", "md", "rtf", "mobi", "azw3", "djvu"]
        guard documentTypes.contains(ext) else { return nil }
        return (first as NSString).deletingPathExtension
    }
}

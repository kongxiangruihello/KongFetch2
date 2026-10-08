import AppKit
import Carbon.HIToolbox
import KongFetchCore

/// The user's snippets, observable by Settings and the clipboard window.
final class SnippetLibrary: ObservableObject {
    let store: SnippetStore
    @Published var snippets: [TextSnippet]

    init(fileURL: URL) {
        store = SnippetStore(fileURL: fileURL)
        snippets = store.snippets
        if !FileManager.default.fileExists(atPath: fileURL.path) { try? store.save() }
    }

    func upsert(_ snippet: TextSnippet) {
        store.upsert(snippet)
        snippets = store.snippets
    }

    func remove(_ id: UUID) {
        store.remove(id)
        snippets = store.snippets
    }

    func replaceAll(_ new: [TextSnippet]) {
        store.replaceAll(new)
        snippets = store.snippets
    }

    func touch(_ id: UUID) {
        store.touch(id)
        snippets = store.snippets
    }

    func snippet(_ id: UUID) -> TextSnippet? { store.snippet(id) }

    var duplicateKeywords: [String] { store.duplicateKeywords }
}

/// Watches typing system-wide (listen-only, like the double-tap monitor) and replaces a typed keyword
/// with its snippet: the keyword is deleted with Backspace, the text pasted with ⌘V, and the previous
/// clipboard put back afterwards.
///
/// Needs Input Monitoring (to see keys) and Accessibility (to send keys). With a keyboard layout such as ABC
/// the keyword expands at once. With an input method (Pinyin…) the same keys may only be composing, so the
/// app's text is checked through Accessibility first: the keyword must really be there before the cursor
/// (in Chinese mode ";" becomes "；", so ";rq" does not match and nothing happens).
final class SnippetExpansionService {
    private let library: SnippetLibrary
    private let monitor: ClipboardMonitor
    private var expander = SnippetExpander()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Whether the selected input source is a keyboard layout (not an input method).
    private var layoutSelected = true
    /// Marks events KongFetch posts itself so the tap ignores them.
    private static let ownEventTag: Int64 = 0x4B46_534E // "KFSN"

    var enabled = false { didSet { if enabled != oldValue { refresh() } } }
    private(set) var lastExpansion: Date?
    private(set) var lastProblem: String?

    var isListening: Bool { tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var inputMethodActive: Bool { !layoutSelected }

    init(library: SnippetLibrary, monitor: ClipboardMonitor) {
        self.library = library
        self.monitor = monitor
        updateInputSource()
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                            object: nil, queue: .main) { [weak self] _ in self?.updateInputSource() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            self?.expander.reset()
        })
    }

    /// Call when snippets change.
    func reloadSnippets() {
        expander.setSnippets(library.snippets)
        refresh()
    }

    func refresh() {
        expander.setSnippets(library.snippets)
        let wanted = enabled && !expander.isEmpty
        if !wanted {
            stopTap()
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        if !isListening { stopTap(); startTap() }
        if retryTimer == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                guard let self, self.enabled, !self.isListening else { return }
                self.stopTap()
                self.startTap()
            }
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
    }

    private func updateInputSource() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(current, kTISPropertyInputSourceType) else { layoutSelected = true; return }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        layoutSelected = type == (kTISTypeKeyboardLayout as String)
        expander.reset()
    }

    // MARK: Tap

    private func startTap() {
        guard CGPreflightListenEventAccess() else { return }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: snippetEventCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        expander.reset()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            expander.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            expander.reset()
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == Self.ownEventTag { return }
            let flags = event.flags
            if flags.contains(.maskCommand) || flags.contains(.maskControl) {
                expander.reset()
                return
            }
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            switch keyCode {
            case kVK_Delete:
                expander.deleteBackward()
                return
            case kVK_Return, kVK_Tab, kVK_Escape, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                 kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ANSI_KeypadEnter:
                expander.reset()
                return
            default:
                break
            }
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
            guard length > 0 else { return }
            let typed = String(utf16CodeUnits: chars, count: length)
            if let hit = expander.type(typed), let snippet = library.snippet(hit.id) {
                if layoutSelected {
                    // The posted Backspaces queue up behind the keyword's last key.
                    DispatchQueue.main.async { [weak self] in self?.expand(snippet, keywordLength: hit.keywordLength) }
                } else {
                    // Give the app a moment to take the key, then make sure the keyword was committed as typed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        guard Self.textBeforeCursor(utf16Length: (snippet.keyword as NSString).length) == snippet.keyword else {
                            self?.lastProblem = "使用输入法时，未能确认“\(snippet.keyword)”已输入（可切换到英文状态或 ABC 键盘）"
                            return
                        }
                        self?.expand(snippet, keywordLength: hit.keywordLength)
                    }
                }
            }
        default:
            break
        }
    }

    // MARK: Expanding

    private func expand(_ snippet: TextSnippet, keywordLength: Int) {
        guard Paster.isTrusted else {
            lastProblem = "需要“辅助功能”权限才能替换关键词"
            return
        }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Preferences.defaultExcludedApps.contains(where: { $0.caseInsensitiveCompare(front) == .orderedSame }) {
            return
        }
        let pasteboard = NSPasteboard.general
        let saved = Self.copyItems(of: pasteboard)
        let rendered = SnippetTemplate.render(snippet.content, clipboard: pasteboard.string(forType: .string))
        guard monitor.restoreText(rendered.text) else { return }
        Self.post(key: CGKeyCode(kVK_Delete), count: keywordLength)
        Self.post(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        if rendered.cursorOffsetFromEnd > 0 {
            Self.post(key: CGKeyCode(kVK_LeftArrow), count: rendered.cursorOffsetFromEnd)
        }
        library.touch(snippet.id)
        lastExpansion = Date()
        lastProblem = nil
        // Put the previous clipboard back once the app has pasted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [monitor] in
            monitor.restoreItems(saved)
        }
    }

    /// The text just before the cursor in the focused text field of the frontmost app, via Accessibility.
    static func textBeforeCursor(utf16Length: Int) -> String? {
        guard utf16Length > 0 else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedRef as! AXUIElement
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selection), selection.length == 0,
              selection.location >= utf16Length else { return nil }
        var wanted = CFRange(location: selection.location - utf16Length, length: utf16Length)
        if let parameter = AXValueCreate(.cfRange, &wanted) {
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(focused, kAXStringForRangeParameterizedAttribute as CFString,
                                                          parameter, &result) == .success, let text = result as? String {
                return text
            }
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else { return nil }
        let ns = value as NSString
        guard wanted.location + wanted.length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: wanted.location, length: wanted.length))
    }

    static func post(key: CGKeyCode, flags: CGEventFlags = [], count: Int = 1) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<max(count, 0) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
                event.flags = flags
                event.setIntegerValueField(.eventSourceUserData, value: ownEventTag)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    /// A copy of every item and type on the pasteboard.
    static func copyItems(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { types[type] = data } }
            return types
        }
    }
}

private func snippetEventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<SnippetExpansionService>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

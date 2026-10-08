import AppKit
import Carbon.HIToolbox

/// A global key combination such as ⌘⌥Space.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// The key's label at recording time, e.g. "V" or "空格".
    var keyLabel: String

    // ⌘⌥Space is taken by Finder's search window and ⌃⌥Space by the input-source switch, so default to ⌃⌥F.
    static let defaultSearch = Shortcut(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "F")
    static let defaultClipboard = Shortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "V")
    static let defaultLookup = Shortcut(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "D")

    var display: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    /// Builds a shortcut from a key press. Requires ⌘, ⌥ or ⌃ so plain typing is never captured.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard !modifierKeyCodes.contains(event.keyCode) else { return nil }
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mods, keyLabel: Self.label(for: event))
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    private static func label(for event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "空格", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
        ]
        if let name = special[Int(event.keyCode)] { return name }
        let chars = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return chars.isEmpty || chars.unicodeScalars.contains(where: { $0.value < 32 }) ? "键\(event.keyCode)" : chars
    }
}

/// Registers system-wide hot keys through Carbon (works without any special permission).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum Slot: UInt32, CaseIterable {
        case search = 1
        case clipboard = 2
        case lookup = 3
        case capture = 4
    }

    private struct Registration {
        var shortcut: Shortcut
        var ref: EventHotKeyRef?
        var action: () -> Void
    }

    private var registrations: [Slot: Registration] = [:]
    private var handler: EventHandlerRef?
    private(set) var isSuspended = false
    private let signature: OSType = 0x4B46_6368 // "KFch"

    private init() {}

    /// Returns false if the combination is already taken by macOS or another app.
    @discardableResult
    func register(_ shortcut: Shortcut?, for slot: Slot, action: @escaping () -> Void) -> Bool {
        unregister(slot)
        guard let shortcut else { return true }
        // macOS's own shortcuts (Spotlight, Finder search, input sources…) win over ours, so refuse them.
        guard !Self.isSystemShortcut(shortcut) else { return false }
        installHandlerIfNeeded()
        var registration = Registration(shortcut: shortcut, ref: nil, action: action)
        if !isSuspended {
            registration.ref = registerCarbon(shortcut, slot: slot)
            guard registration.ref != nil else { return false }
        }
        registrations[slot] = registration
        return true
    }

    func unregister(_ slot: Slot) {
        if let ref = registrations[slot]?.ref { UnregisterEventHotKey(ref) }
        registrations[slot] = nil
    }

    func isRegistered(_ slot: Slot) -> Bool {
        registrations[slot]?.ref != nil
    }

    /// Temporarily releases all combinations, e.g. while the user records a new one.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for slot in Array(registrations.keys) {
            if let ref = registrations[slot]?.ref { UnregisterEventHotKey(ref) }
            registrations[slot]?.ref = nil
        }
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for slot in Array(registrations.keys) {
            if let shortcut = registrations[slot]?.shortcut {
                registrations[slot]?.ref = registerCarbon(shortcut, slot: slot)
            }
        }
    }

    /// Whether an enabled macOS keyboard shortcut (System Settings › Keyboard › Shortcuts) uses this combination.
    static func isSystemShortcut(_ shortcut: Shortcut) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        for entry in entries {
            guard (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value,
                  let modifiers = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { continue }
            if code == shortcut.keyCode && modifiers & mask == shortcut.carbonModifiers & mask { return true }
        }
        return false
    }

    fileprivate func fire(_ id: UInt32) {
        guard !isSuspended, let slot = Slot(rawValue: id), let registration = registrations[slot] else { return }
        DispatchQueue.main.async { registration.action() }
    }

    private func registerCarbon(_ shortcut: Shortcut, slot: Slot) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: slot.rawValue)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().fire(hotKeyID.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

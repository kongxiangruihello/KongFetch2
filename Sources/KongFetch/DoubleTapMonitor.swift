import AppKit
import KongFetchCore

/// Watches keyboard events system-wide (listen-only) to recognise a double tap of one modifier.
///
/// Requires Input Monitoring permission. The tap is retried every few seconds while the permission
/// is missing, so granting it in System Settings takes effect without restarting the app.
final class DoubleTapMonitor {
    var trigger: TapModifier = .off {
        didSet {
            guard trigger != oldValue else { return }
            detector.reset()
            triggerDown = false
            refresh()
        }
    }
    var onDoubleTap: (() -> Void)?

    private(set) var lastEventAt: Date?
    private(set) var lastFiredAt: Date?

    private var detector = DoubleTapDetector()
    private var triggerDown = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?

    var hasPermission: Bool { CGPreflightListenEventAccess() }
    var isListening: Bool { tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Starts or stops listening to match `trigger` and the current permission.
    func refresh() {
        if trigger == .off {
            stopTap()
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        if !isListening {
            stopTap()
            startTap()
        }
        if retryTimer == nil {
            // Also revives a tap the system disabled or invalidated.
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                guard let self, self.trigger != .off, !self.isListening else { return }
                self.stopTap()
                self.startTap()
            }
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
    }

    /// Shows the system prompt (first time only) and opens the Input Monitoring pane.
    func requestPermission() {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        refresh()
        if !isListening, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startTap() {
        guard CGPreflightListenEventAccess() else { return }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: doubleTapEventCallback,
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
        detector.reset()
        triggerDown = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            detector.reset()
            triggerDown = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            lastEventAt = Date()
            _ = detector.handle(.interrupt, at: ProcessInfo.processInfo.systemUptime)
        case .flagsChanged:
            lastEventAt = Date()
            let transition = ModifierTransition.input(previouslyDown: triggerDown,
                                                      current: ModifierSet(event.flags),
                                                      trigger: trigger.modifierSet)
            triggerDown = transition.isDown
            // Uptime, not CGEvent.timestamp: the event timestamp's unit is not guaranteed across Macs.
            if let input = transition.input, detector.handle(input, at: ProcessInfo.processInfo.systemUptime) {
                lastFiredAt = Date()
                DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
            }
        default:
            break
        }
    }
}

private func doubleTapEventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<DoubleTapMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

extension ModifierSet {
    init(_ flags: CGEventFlags) {
        var set: ModifierSet = []
        if flags.contains(.maskControl) { set.insert(.control) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskCommand) { set.insert(.command) }
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { set.insert(.function) }
        self = set
    }
}

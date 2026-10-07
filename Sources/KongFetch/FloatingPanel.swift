import AppKit
import Quartz

/// A Spotlight-style panel: it takes keyboard focus without activating KongFetch,
/// so the app you were using stays frontmost (and receives the paste afterwards).
class FloatingPanel: NSPanel {
    /// Handles a key press before the panel does. Return true if consumed.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Called when the panel loses keyboard focus (e.g. the user clicked elsewhere).
    var onResignKey: (() -> Void)?
    /// Supplies Quick Look content while this panel is key.
    weak var quickLookProvider: (QLPreviewPanelDataSource & QLPreviewPanelDelegate & QuickLookProviding)?

    let effectView = NSVisualEffectView()

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered,
                   defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        // Fixed size: content (e.g. a large image) must not stretch the panel.
        contentMinSize = size
        contentMaxSize = size

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        contentView = effectView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        // Editing shortcuts must work even though KongFetch's menu bar is never active.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector?
            switch key {
            case "x": action = #selector(NSText.cut(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z",
           NSApp.sendAction(Selector(("redo:")), to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Centres the panel horizontally, in the upper part of the screen under the mouse.
    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - frame.width / 2,
                                 y: visible.maxY - visible.height * 0.18 - frame.height)
            setFrameOrigin(NSPoint(x: origin.x.rounded(), y: max(visible.minY, origin.y).rounded()))
        }
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookProvider != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookProvider
        panel.delegate = quickLookProvider
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookProvider?.quickLookDidEnd()
    }
}

protocol QuickLookProviding: AnyObject {
    func quickLookDidEnd()
}

// MARK: - Small shared UI pieces

/// Selection drawn as a soft accent-coloured rounded rectangle, readable whether or not the app is active.
final class SoftSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// Icon + title + subtitle cell used by both panels.
final class TwoLineCellView: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        badge.textColor = .tertiaryLabelColor
        badge.alignment = .right
        for view in [icon, title, subtitle, badge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badge.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A borderless, large text field for the top of a panel.
func makePanelSearchField(placeholder: String) -> NSTextField {
    let field = NSTextField()
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 22, weight: .regular)
    field.placeholderString = placeholder
    field.cell?.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
}

func makeSeparator() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    box.translatesAutoresizingMaskIntoConstraints = false
    return box
}

func makeFooterLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

func makeResultsTable(rowHeight: CGFloat) -> (NSTableView, NSScrollView) {
    let table = NSTableView()
    table.headerView = nil
    table.rowHeight = rowHeight
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .regular
    table.refusesFirstResponder = true
    table.allowsEmptySelection = true
    table.style = .plain
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    return (table, scroll)
}

extension Date {
    /// "14:05", "昨天 14:05", "10月3日" or "2025年10月3日".
    var shortDescription: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(self) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: self)
        }
        if calendar.isDateInYesterday(self) {
            formatter.dateFormat = "HH:mm"
            return "昨天 " + formatter.string(from: self)
        }
        formatter.dateFormat = calendar.isDate(self, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: self)
    }
}

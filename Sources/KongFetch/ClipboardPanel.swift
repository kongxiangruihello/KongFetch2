import AppKit
import ImageIO
import KongFetchCore

/// The clipboard history window. Opening it does not take focus away from the app you are in,
/// so choosing an entry can paste straight into that app.
final class ClipboardPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let panel = FloatingPanel(size: NSSize(width: 780, height: 480))
    private let monitor: ClipboardMonitor
    private let preferences: Preferences
    private var history: ClipboardHistory { monitor.history }

    private let field = makePanelSearchField(placeholder: "搜索剪贴板历史")
    private let table: NSTableView
    private let scroll: NSScrollView
    /// A text view set up by AppKit to wrap at the scroll view's width from the first showing on.
    private let textScroll = NSTextView.scrollableTextView()
    private var textPreview: NSTextView { textScroll.documentView as! NSTextView }
    private let imagePreview = NSImageView()
    private let detailLabel = makeFooterLabel()
    private let statusLabel = makeFooterLabel()
    private let hintLabel = makeFooterLabel()
    private let pauseButton = NSButton(title: "暂停记录", target: nil, action: nil)
    private let onboarding = NSStackView()

    private var rows: [ClipItem] = []
    private var thumbnailCache = NSCache<NSString, NSImage>()
    /// Show the selected text as "整理后粘贴" would paste it (⌘E).
    private var previewCleaned = false
    /// True while the ⌘K menu is open, so losing focus to it does not close the window.
    private var menuOpen = false

    var openSettings: (() -> Void)?

    init(monitor: ClipboardMonitor, preferences: Preferences) {
        self.monitor = monitor
        self.preferences = preferences
        let pair = makeResultsTable(rowHeight: 44)
        table = pair.0
        scroll = pair.1
        super.init()
        buildLayout()
        field.delegate = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pasteSelectedAction)
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onResignKey = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.panel.isVisible, !self.panel.isKeyWindow, !self.menuOpen, self.panel.attachedSheet == nil else { return }
                self.hide()
            }
        }
        history.onChange = { [weak self] in self?.reloadIfVisible() }
    }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func show() {
        field.stringValue = ""
        previewCleaned = false
        reload()
        panel.present()
        panel.makeFirstResponder(field)
    }

    func hide() {
        panel.orderOut(nil)
    }

    // MARK: Layout

    private func buildLayout() {
        let content = panel.effectView
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        pauseButton.bezelStyle = .inline
        pauseButton.controlSize = .small
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.translatesAutoresizingMaskIntoConstraints = false

        textPreview.isEditable = false
        textPreview.isSelectable = true
        textPreview.drawsBackground = false
        textPreview.font = .systemFont(ofSize: 13)
        textPreview.textContainerInset = NSSize(width: 12, height: 12)
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        imagePreview.imageScaling = .scaleProportionallyDown
        imagePreview.translatesAutoresizingMaskIntoConstraints = false
        // An image's natural size must never grow the window.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imagePreview.setContentCompressionResistancePriority(.init(1), for: orientation)
            imagePreview.setContentHuggingPriority(.init(1), for: orientation)
        }
        detailLabel.alignment = .center

        hintLabel.alignment = .right
        hintLabel.stringValue = "↩ 粘贴   ⇧↩ 纯文本   ⌘J 整理后粘贴   ⌘E 预览整理   ⌘K 更多操作"

        buildOnboarding()

        let topLine = makeSeparator()
        let bottomLine = makeSeparator()
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, field, pauseButton, topLine, scroll, divider, textScroll, imagePreview, detailLabel,
                     bottomLine, statusLabel, hintLabel, onboarding] as [NSView] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            field.heightAnchor.constraint(equalToConstant: 30),
            pauseButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            pauseButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),

            topLine.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            topLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -4),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.5),

            divider.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 4),
            divider.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            textScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            textScroll.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            textScroll.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -6),
            imagePreview.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 16),
            imagePreview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            imagePreview.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 16),
            imagePreview.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -10),
            detailLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            detailLabel.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -8),

            bottomLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -30),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -15),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: hintLabel.leadingAnchor, constant: -12),
            hintLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            hintLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),

            onboarding.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            onboarding.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 10),
            onboarding.widthAnchor.constraint(equalToConstant: 460)
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func buildOnboarding() {
        let title = NSTextField(labelWithString: "剪贴板历史尚未启用")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString:
            "启用后，KongFetch 会记住之后复制的文字、图片和文件，可以搜索并再次粘贴。\n" +
            "内容只保存在这台 Mac，不参与时间机器备份；带有机密标记的内容（如密码管理器复制的密码）和排除的应用不会记录。" +
            "未带标记的私密内容仍可能被记录，可随时暂停或清空。")
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        let enable = NSButton(title: "启用剪贴板历史", target: self, action: #selector(enableHistory))
        enable.bezelStyle = .rounded
        enable.keyEquivalent = "\r"
        onboarding.orientation = .vertical
        onboarding.alignment = .centerX
        onboarding.spacing = 12
        onboarding.translatesAutoresizingMaskIntoConstraints = false
        for view in [title, body, enable] { onboarding.addArrangedSubview(view) }
        body.widthAnchor.constraint(equalTo: onboarding.widthAnchor).isActive = true
    }

    // MARK: Data

    private func reloadIfVisible() {
        if panel.isVisible { reload() }
    }

    private func reload() {
        let enabled = preferences.clipboardEnabled
        onboarding.isHidden = enabled
        for view in [field, scroll, textScroll, imagePreview, detailLabel, pauseButton, hintLabel] as [NSView] {
            view.isHidden = !enabled
        }
        guard enabled else {
            statusLabel.stringValue = ""
            return
        }
        let selectedID = selectedItem?.id
        let needle = TextFolding.fold(field.stringValue.trimmingCharacters(in: .whitespaces))
        rows = history.items
            .filter { needle.isEmpty || TextFolding.fold($0.searchText).contains(needle) }
            .sorted { $0.pinned != $1.pinned ? $0.pinned : $0.lastUsed > $1.lastUsed }
        table.reloadData()
        let index = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        if rows.indices.contains(index) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        updatePreview()
        updateStatus()
    }

    private func updateStatus() {
        pauseButton.title = preferences.clipboardPaused ? "继续记录" : "暂停记录"
        var parts: [String] = []
        parts.append(preferences.clipboardPaused ? "已暂停" : "正在记录")
        parts.append("\(history.items.count) 条 · " + ByteCountFormatter.string(fromByteCount: Int64(history.totalBytes), countStyle: .file))
        if preferences.autoPaste && !Paster.isTrusted { parts.append("自动粘贴需要辅助功能权限（⌘, 打开设置）") }
        if let problem = history.problem { parts.append(problem) } else if let notice = monitor.lastNotice { parts.append(notice) }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    private var selectedItem: ClipItem? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    private func updatePreview() {
        guard let item = selectedItem else {
            textScroll.isHidden = !preferences.clipboardEnabled
            imagePreview.isHidden = true
            textPreview.string = rows.isEmpty && preferences.clipboardEnabled ? "还没有记录。复制一些内容后会出现在这里。" : ""
            detailLabel.stringValue = ""
            return
        }
        var details = [item.sourceName ?? "未知来源", "复制于 " + item.created.shortDescription]
        switch item.kind {
        case .text:
            textScroll.isHidden = false
            imagePreview.isHidden = true
            let text = item.text ?? ""
            textPreview.string = previewCleaned ? TextCleanup.apply(preferences.cleanupOperations, to: text) : text
            details.append("\(text.count) 字")
            if item.richTextFile != nil { details.append("含格式") }
            if previewCleaned { details.append("整理预览（⌘E 关闭）") }
        case .files:
            textScroll.isHidden = false
            imagePreview.isHidden = true
            textPreview.string = (item.filePaths ?? []).map { PathDisplay.pretty($0, home: NSHomeDirectory()) }.joined(separator: "\n")
            let missing = (item.filePaths ?? []).filter { !FileManager.default.fileExists(atPath: $0) }.count
            if missing > 0 { details.append("\(missing) 个文件已不存在") }
        case .image:
            let image = item.imageFile.flatMap { history.store.readBlob($0) }.flatMap(NSImage.init(data:))
            details.append(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
            if let recognized = item.recognizedText, !recognized.isEmpty {
                // Picture on top, the recognized text below it, in one scrollable view.
                textScroll.isHidden = false
                imagePreview.isHidden = true
                let shown = previewCleaned ? TextCleanup.apply(preferences.cleanupOperations, to: recognized) : recognized
                textPreview.textStorage?.setAttributedString(Self.imageWithText(image, shown, width: textScroll.contentSize.width - 30))
                details.append("⌘T 拷贝图中文字")
            } else {
                textScroll.isHidden = true
                imagePreview.isHidden = false
                imagePreview.image = image
                if item.recognizedText == nil && preferences.clipboardOCR {
                    details.append("正在识别文字…")
                    monitor.recognizeText(in: item)
                }
            }
        }
        textPreview.scrollToBeginningOfDocument(nil)
        detailLabel.stringValue = details.joined(separator: " · ")
    }

    static func imageWithText(_ image: NSImage?, _ text: String, width: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let image, image.size.width > 0 {
            let attachment = NSTextAttachment()
            attachment.image = image
            let scale = min(1, max(width, 100) / image.size.width)
            attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "\n\n"))
        }
        result.append(NSAttributedString(string: "识别的文字\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        result.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        return result
    }

    // MARK: Keyboard

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            paste(plainText: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false); return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): paste(plainText: true); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { hide() } else { field.stringValue = ""; reload() }
            return true
        default:
            return false
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .shift, event.keyCode == 36 { paste(plainText: true); return true }
        guard flags == .command else { return false }
        switch event.keyCode {
        case 36: copyOnly(); return true                      // ⌘↩
        case 51 where field.stringValue.isEmpty: deleteSelected(); return true   // ⌘⌫
        default: break
        }
        switch key {
        case "p": togglePin(); return true
        case "t": copyRecognizedText(); return true
        case "j": pasteCleaned(preferences.cleanupOperations); return true
        case "e": togglePreviewCleaned(); return true
        case "k": showActionMenu(); return true
        case ",": hide(); openSettings?(); return true
        case "w": hide(); return true
        default:
            if let digit = Int(key), (1...9).contains(digit), rows.indices.contains(digit - 1) {
                table.selectRowIndexes(IndexSet(integer: digit - 1), byExtendingSelection: false)
                paste(plainText: false)
                return true
            }
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let next = max(0, min(rows.count - 1, (table.selectedRow < 0 ? -1 : table.selectedRow) + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: Actions

    @objc private func pasteSelectedAction() {
        paste(plainText: false)
    }

    private func paste(plainText: Bool) {
        guard let item = selectedItem else { return }
        guard monitor.restore(item, plainTextOnly: plainText) else {
            statusLabel.stringValue = "这条记录的数据已丢失，无法粘贴"
            return
        }
        history.touch(item.id)
        finishPaste()
    }

    /// Hides the window and, if allowed, pastes into the app that was in front.
    private func finishPaste() {
        hide()
        guard preferences.autoPaste else { return }
        if Paster.isTrusted {
            // Wait for the previous app's window to take keyboard focus back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Paster.pasteIntoFrontmostApp() }
        }
    }

    /// Tidies the selected text (or the text recognized in a picture) and pastes it as plain text.
    private func pasteCleaned(_ operations: [TextCleanup.Operation]) {
        guard let item = selectedItem else { return }
        guard let text = monitor.plainText(of: item), !text.isEmpty else {
            statusLabel.stringValue = item.kind == .image && item.recognizedText == nil ? "仍在识别图中文字，请稍候" : "这条记录没有可整理的文字"
            return
        }
        guard !operations.isEmpty else {
            statusLabel.stringValue = "还没有选择整理方式（⌘K › 整理方式…）"
            return
        }
        guard monitor.restoreText(TextCleanup.apply(operations, to: text)) else { return }
        history.touch(item.id)
        finishPaste()
    }

    private func togglePreviewCleaned() {
        previewCleaned.toggle()
        updatePreview()
    }

    // MARK: Action menu (⌘K)

    private func showActionMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = selectedItem
        let hasText = item.flatMap { monitor.plainText(of: $0) }?.isEmpty == false

        let summary = preferences.cleanupOperations.map(\.shortTitle).joined(separator: "、")
        add(menu, "整理后粘贴" + (summary.isEmpty ? "" : "（\(summary)）"), "j", #selector(menuPasteCleaned), enabled: hasText)
        let single = NSMenuItem(title: "单项整理后粘贴", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for operation in TextCleanup.Operation.allCases {
            let entry = add(submenu, operation.title, "", #selector(menuPasteOneOperation(_:)), enabled: hasText)
            entry.representedObject = operation.rawValue
        }
        single.submenu = submenu
        single.isEnabled = hasText
        menu.addItem(single)
        add(menu, previewCleaned ? "关闭整理预览" : "预览整理效果", "e", #selector(menuTogglePreview), enabled: hasText)
        menu.addItem(.separator())
        add(menu, "粘贴为纯文本", "\r", #selector(menuPastePlain), enabled: item != nil, modifiers: [.shift])
        add(menu, "仅拷贝，不粘贴", "\r", #selector(menuCopyOnly), enabled: item != nil)
        if item?.kind == .image { add(menu, "拷贝图中文字", "t", #selector(menuCopyRecognized), enabled: true) }
        add(menu, item?.pinned == true ? "取消固定" : "固定", "p", #selector(menuTogglePin), enabled: item != nil)
        add(menu, "删除", "\u{8}", #selector(menuDelete), enabled: item != nil)
        menu.addItem(.separator())
        let ways = NSMenuItem(title: "整理方式（⌘J）", action: nil, keyEquivalent: "")
        let waysMenu = NSMenu()
        waysMenu.autoenablesItems = false
        for operation in TextCleanup.Operation.allCases {
            let entry = add(waysMenu, operation.title, "", #selector(menuToggleOperation(_:)), enabled: true)
            entry.representedObject = operation.rawValue
            entry.state = preferences.cleanupOperations.contains(operation) ? .on : .off
        }
        ways.submenu = waysMenu
        menu.addItem(ways)

        let row = max(0, table.selectedRow)
        let rect = table.numberOfRows > 0 ? table.rect(ofRow: row) : table.bounds
        menuOpen = true
        _ = menu.popUp(positioning: nil, at: NSPoint(x: rect.midX, y: rect.maxY), in: table)
        menuOpen = false
        if panel.isVisible { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field) }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ key: String, _ action: Selector, enabled: Bool,
                     modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        entry.target = self
        entry.isEnabled = enabled
        menu.addItem(entry)
        return entry
    }

    @objc private func menuPasteCleaned() { pasteCleaned(preferences.cleanupOperations) }
    @objc private func menuPasteOneOperation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let operation = TextCleanup.Operation(rawValue: raw) else { return }
        pasteCleaned([operation])
    }
    @objc private func menuTogglePreview() { togglePreviewCleaned() }
    @objc private func menuPastePlain() { paste(plainText: true) }
    @objc private func menuCopyOnly() { copyOnly() }
    @objc private func menuCopyRecognized() { copyRecognizedText() }
    @objc private func menuTogglePin() { togglePin() }
    @objc private func menuDelete() { deleteSelected() }
    @objc private func menuToggleOperation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let operation = TextCleanup.Operation(rawValue: raw) else { return }
        var list = preferences.cleanupOperations
        if let index = list.firstIndex(of: operation) {
            list.remove(at: index)
        } else {
            list.append(operation)
            // Simplified and traditional exclude each other.
            if operation == .toSimplified { list.removeAll { $0 == .toTraditional } }
            if operation == .toTraditional { list.removeAll { $0 == .toSimplified } }
        }
        preferences.cleanupOperations = list
        updatePreview()
    }

    private func copyOnly() {
        guard let item = selectedItem else { return }
        if monitor.restore(item) {
            history.touch(item.id)
            statusLabel.stringValue = "已拷贝，可切换到其他应用粘贴"
        }
    }

    private func copyRecognizedText() {
        guard let item = selectedItem, item.kind == .image else { return }
        guard let text = item.recognizedText, !text.isEmpty else {
            statusLabel.stringValue = item.recognizedText == nil ? "仍在识别，请稍候" : "这张图片里没有识别到文字"
            return
        }
        if monitor.restore(item, plainTextOnly: true) {
            statusLabel.stringValue = "已拷贝图中文字（\(text.count) 字）"
        }
    }

    private func togglePin() {
        guard let item = selectedItem else { return }
        do {
            try history.setPinned(item.id, !item.pinned)
        } catch ClipboardHistory.PinError.tooManyPinned(let limit) {
            statusLabel.stringValue = "最多固定 \(limit) 条，请先取消一些固定"
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func deleteSelected() {
        guard let item = selectedItem else { return }
        let row = table.selectedRow
        history.remove(item.id)
        if !rows.isEmpty {
            let next = min(row, rows.count - 1)
            table.selectRowIndexes(IndexSet(integer: max(0, next)), byExtendingSelection: false)
            updatePreview()
        }
    }

    @objc private func togglePause() {
        preferences.clipboardPaused.toggle()
        if !preferences.clipboardPaused { monitor.skipCurrentContents() }
        reload()
        panel.makeFirstResponder(field)
    }

    @objc private func enableHistory() {
        monitor.skipCurrentContents()
        preferences.clipboardPaused = false
        preferences.clipboardEnabled = true
        reload()
        panel.makeFirstResponder(field)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SoftSelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("clip")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TwoLineCellView ?? {
            let view = TwoLineCellView(frame: .zero)
            view.identifier = id
            return view
        }()
        let item = rows[row]
        cell.icon.image = icon(for: item)
        cell.title.stringValue = item.title.isEmpty ? "（空白）" : item.title
        cell.subtitle.stringValue = [item.pinned ? "📌 已固定" : nil, item.sourceName, item.lastUsed.shortDescription]
            .compactMap { $0 }.joined(separator: " · ")
        cell.badge.stringValue = row < 9 ? "⌘\(row + 1)" : ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private func icon(for item: ClipItem) -> NSImage? {
        switch item.kind {
        case .text:
            return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "文字")
        case .files:
            guard let first = item.filePaths?.first else { return nil }
            return NSWorkspace.shared.icon(forFile: first)
        case .image:
            guard let name = item.imageFile else { return nil }
            if let cached = thumbnailCache.object(forKey: name as NSString) { return cached }
            guard let url = history.store.blobURL(name),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64
                  ] as CFDictionary) else { return nil }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: 28, height: 28))
            thumbnailCache.setObject(image, forKey: name as NSString)
            return image
        }
    }
}

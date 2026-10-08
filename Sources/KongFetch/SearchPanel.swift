import AppKit
import Quartz
import QuickLookThumbnailing
import KongFetchCore

/// The main search window: field on top, results on the left, preview on the right.
final class SearchPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate,
                                   QLPreviewPanelDataSource, QLPreviewPanelDelegate, QuickLookProviding {
    let panel = FloatingPanel(size: NSSize(width: 800, height: 500))
    private let coordinator: FileSearchCoordinator
    private let field = makePanelSearchField(placeholder: "搜索文件、文件夹和应用")
    private let table: NSTableView
    private let scroll: NSScrollView
    private let preview = FilePreviewView()
    private let statusLabel = makeFooterLabel()
    private let hintLabel = makeFooterLabel()
    private let spinner = NSProgressIndicator()
    private let modeButton = NSButton(title: "名称", target: nil, action: nil)
    /// Search inside files instead of names only. Toggled with Tab.
    private var contentMode = false

    /// One line in the results list: a file, or a web search to open in the browser.
    private enum Row {
        case file(SearchResult)
        case web(QuickLink, String)
        /// "cd 仁": the word and its definition from the system dictionaries (nil if none was found).
        case definition(String, String?)

        var file: SearchResult? {
            if case .file(let result) = self { return result }
            return nil
        }
    }

    private var rows: [Row] = []
    private var results: [SearchResult] { rows.compactMap(\.file) }
    /// Web searches shown above the files (a keyword match) or below them (when nothing was found).
    private var webRows: [Row] = []
    private var showingRecents = false
    /// True once the user picks a row with the arrows or the mouse; until then the top result stays selected
    /// while Spotlight streams in more results.
    private var userChoseRow = false
    private var pendingSearch: DispatchWorkItem?
    private var quickLookOpen = false
    /// True while the ⌘K menu is open, so losing focus to it does not close the window.
    private var menuOpen = false

    /// Set by the app delegate to open Settings.
    var openSettings: (() -> Void)?
    /// Explains missing folder permissions when a search finds nothing.
    var accessHint: (() -> String?)?
    /// The user's web searches (Settings › 网页搜索).
    var quickLinks: () -> [QuickLink] = { QuickLinks.defaults }

    init(coordinator: FileSearchCoordinator) {
        self.coordinator = coordinator
        let pair = makeResultsTable(rowHeight: 46)
        table = pair.0
        scroll = pair.1
        super.init()
        buildLayout()
        field.delegate = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onResignKey = { [weak self] in self?.panelLostFocus() }
        panel.quickLookProvider = self
        preview.ocrStore = coordinator.ocrStore
    }

    // MARK: Showing and hiding

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func show() {
        panel.present()
        panel.makeFirstResponder(field)
        if field.stringValue.isEmpty {
            // A fresh search starts by name; full-text stays on only while a query is being refined.
            if contentMode { toggleMode() }
            showRecents()
        } else {
            field.currentEditor()?.selectAll(nil)
        }
    }

    /// Opens the window with `text` already typed, e.g. "cd 仁" from the look-up shortcut.
    func show(query text: String) {
        panel.present()
        panel.makeFirstResponder(field)
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        if contentMode { toggleMode() } else { runSearch(text) }
    }

    func hide() {
        pendingSearch?.cancel()
        coordinator.cancel()
        spinner.stopAnimation(nil)
        if QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible {
            ql.orderOut(nil)
        }
        panel.orderOut(nil)
        // Quick Look may have activated KongFetch; hand focus back to the previous app.
        if NSApp.isActive && !NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) && $0.level == .normal }) {
            NSApp.hide(nil)
        }
    }

    private func panelLostFocus() {
        // Give Quick Look or a sheet a moment to become key before deciding the user clicked away.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow, !self.quickLookOpen, !self.menuOpen,
                  self.panel.attachedSheet == nil else { return }
            self.hide()
        }
    }

    // MARK: Layout

    private func buildLayout() {
        let content = panel.effectView
        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        magnifier.contentTintColor = .secondaryLabelColor
        magnifier.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let topLine = makeSeparator()
        let bottomLine = makeSeparator()
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.alignment = .right
        hintLabel.stringValue = "⇥ 名称/全文   ↩ 打开   ⌘↩ 在访达中显示   ⌘Y 快速查看   ⌘K 更多操作   cd 查词"

        modeButton.bezelStyle = .inline
        modeButton.controlSize = .small
        modeButton.target = self
        modeButton.action = #selector(toggleMode)
        modeButton.toolTip = "切换按名称或按内容搜索（Tab）"
        modeButton.translatesAutoresizingMaskIntoConstraints = false

        for view in [magnifier, field, modeButton, spinner, topLine, scroll, divider, preview, bottomLine, statusLabel, hintLabel] as [NSView] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            magnifier.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: modeButton.leadingAnchor, constant: -8),
            modeButton.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            modeButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            field.heightAnchor.constraint(equalToConstant: 30),
            spinner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            spinner.centerYAnchor.constraint(equalTo: field.centerYAnchor),

            topLine.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            topLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -4),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.56),

            divider.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 4),
            divider.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            preview.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),

            bottomLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -30),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -15),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: hintLabel.leadingAnchor, constant: -12),
            hintLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            hintLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor)
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) {
        pendingSearch?.cancel()
        let text = field.stringValue
        let work = DispatchWorkItem { [weak self] in self?.runSearch(text) }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func runSearch(_ text: String) {
        userChoseRow = false
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            coordinator.cancel()
            spinner.stopAnimation(nil)
            showRecents()
            return
        }
        showingRecents = false
        // "cd 仁": the system dictionary, plus 汉典 when it has nothing.
        if text.hasSuffix(" "), text.trimmingCharacters(in: .whitespaces).lowercased() == DictionaryLookup.keyword {
            coordinator.cancel()
            spinner.stopAnimation(nil)
            webRows = []
            setRows([])
            statusLabel.stringValue = "输入要查的字或词"
            return
        }
        if let word = DictionaryLookup.word(in: text) {
            coordinator.cancel()
            spinner.stopAnimation(nil)
            let definition = DictionaryLookup.definition(of: word)
            var lookupRows: [Row] = [.definition(word, definition)]
            if let handian = quickLinks().first(where: { $0.keyword == "hd" }) { lookupRows.append(.web(handian, word)) }
            webRows = []
            setRows(lookupRows)
            statusLabel.stringValue = definition == nil
                ? "系统词典里没有“\(word)”。可在“词典”App 的设置中启用更多词典，或用汉典查"
                : "↩ 在“词典”中打开   ⌘C 拷贝释义"
            return
        }
        // "hd 仁": the web search goes first, files matching the whole text still follow.
        let keywordMatch = QuickLinks.match(text, in: quickLinks())
        webRows = keywordMatch.map { [Row.web($0.link, $0.query)] } ?? []
        spinner.startAnimation(nil)
        coordinator.search(text, content: contentMode) { [weak self] results, finished in
            guard let self else { return }
            if finished, results.isEmpty, keywordMatch == nil {
                let query = text.trimmingCharacters(in: .whitespaces)
                self.webRows = self.quickLinks().filter(\.fallback).map { Row.web($0, query) }
            }
            let files = results.map(Row.file)
            self.setRows(keywordMatch != nil ? self.webRows + files : files + self.webRows)
            if let match = keywordMatch {
                self.statusLabel.stringValue = "↩ 在\(match.link.name)中搜索「\(match.query)」" + (results.isEmpty ? "" : " · ↓ 另有 \(results.count) 个文件")
            } else if finished {
                self.spinner.stopAnimation(nil)
                if results.isEmpty {
                    self.statusLabel.stringValue = self.accessHint?() ?? "没有找到文件。可试试拼音首字母、减少关键词，或在网上搜索"
                } else {
                    self.statusLabel.stringValue = "\(results.count) 个结果"
                }
            } else {
                self.statusLabel.stringValue = "正在搜索… \(results.count)"
            }
            if finished { self.spinner.stopAnimation(nil) }
        }
    }

    private func showRecents() {
        showingRecents = true
        webRows = []
        setRows(coordinator.recentResults().map(Row.file))
        statusLabel.stringValue = results.isEmpty
            ? "输入名称开始搜索 · 语法：ext:pdf  kind:folder  \"短语\"  -排除  days:7"
            : "最近打开 · 输入名称开始搜索"
    }

    private func setRows(_ newRows: [Row]) {
        let previous = userChoseRow ? selectedResult?.path : nil
        rows = newRows
        table.reloadData()
        let index = previous.flatMap { path in rows.firstIndex { $0.file?.path == path } } ?? 0
        if rows.indices.contains(index) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        updatePreview()
    }

    private var selectedRow: Row? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    private var selectedResult: SearchResult? { selectedRow?.file }

    // MARK: Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false } // let the input method finish composing
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); return true
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): moveSelection(by: 8); return true
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): moveSelection(by: -8); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)): toggleMode(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { hide() } else { field.stringValue = ""; runSearch("") }
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
        if flags == .command {
            switch key {
            case "\r": revealSelected(); return true
            case "y": toggleQuickLook(); return true
            case ",": hide(); openSettings?(); return true
            case "w": hide(); return true
            case "c":
                // With text selected in the field, ⌘C copies that text as usual.
                if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
                copySelected(); return true
            case "k":
                showActionMenu(); return true
            default:
                if let digit = Int(key), (1...9).contains(digit), rows.indices.contains(digit - 1) {
                    activate(rows[digit - 1]); return true
                }
            }
        }
        if flags == [.command, .option], key == "c" { copySelectedPath(); return true }
        if flags == .command, event.keyCode == 36 { revealSelected(); return true } // ⌘↩
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = table.selectedRow < 0 ? (delta > 0 ? -1 : rows.count) : table.selectedRow
        let next = max(0, min(rows.count - 1, current + delta))
        userChoseRow = true
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: Actions

    @objc func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return }
        activate(rows[row])
    }

    private func activate(_ row: Row) {
        switch row {
        case .file(let result):
            open(result)
        case .definition(let word, _):
            hide()
            DictionaryLookup.openInDictionaryApp(word)
        case .web(let link, let query):
            guard let url = link.url(for: query) else {
                statusLabel.stringValue = "“\(link.name)”的网址无效，请在设置 › 网页搜索中检查"
                return
            }
            hide()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                if let error { DispatchQueue.main.async { Self.presentError(error) } }
            }
        }
    }

    private func open(_ result: SearchResult) {
        hide()
        coordinator.recents.record(result.path)
        if result.isApplication {
            NSWorkspace.shared.openApplication(at: result.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { Self.presentError(error) } }
            }
        } else if !NSWorkspace.shared.open(result.url) {
            Self.presentError(CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: result.path]))
        }
    }

    private func revealSelected() {
        guard let result = selectedResult else { return }
        hide()
        coordinator.recents.record(result.path)
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    /// ⌘C: the file, the definition text or the web address, depending on the row.
    private func copySelected() {
        switch selectedRow {
        case .definition(_, let definition?)?:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(definition, forType: .string)
            statusLabel.stringValue = "已拷贝释义"
        case .web(let link, let query)?:
            guard let url = link.url(for: query) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            statusLabel.stringValue = "已拷贝网址"
        default:
            copySelectedFile()
        }
    }

    private func copySelectedFile() {
        guard let result = selectedResult else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([result.url as NSURL])
        statusLabel.stringValue = "已拷贝文件：\(result.fileName)"
    }

    private func copySelectedPath() {
        guard let result = selectedResult else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.path, forType: .string)
        statusLabel.stringValue = "已拷贝路径"
    }

    // MARK: Action menu (⌘K)

    private func showActionMenu() {
        guard let row = selectedRow else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch row {
        case .file(let result):
            add(menu, "打开", "\r", []) { [weak self] in self?.open(result) }
            let openWith = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
            let apps = NSMenu()
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: result.url)
            for app in NSWorkspace.shared.urlsForApplications(toOpen: result.url).prefix(15) {
                let name = (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension
                let entry = add(apps, name + (app == defaultApp ? "（默认）" : ""), "", []) { [weak self] in self?.open(result, with: app) }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            }
            openWith.submenu = apps
            openWith.isEnabled = !apps.items.isEmpty && !result.isApplication
            menu.addItem(openWith)
            add(menu, "在访达中显示", "\r", [.command]) { [weak self] in self?.revealSelected() }
            add(menu, "快速查看", "y", [.command]) { [weak self] in self?.toggleQuickLook() }
            menu.addItem(.separator())
            add(menu, "拷贝文件", "c", [.command]) { [weak self] in self?.copySelectedFile() }
            add(menu, "拷贝路径", "c", [.command, .option]) { [weak self] in self?.copySelectedPath() }
            add(menu, "拷贝名称", "", []) { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.fileName, forType: .string)
                self?.statusLabel.stringValue = "已拷贝名称"
            }
            add(menu, "在终端中打开", "", []) { [weak self] in self?.openInTerminal(result) }
            menu.addItem(.separator())
            add(menu, "移到废纸篓", "", []) { [weak self] in self?.moveToTrash(result) }
        case .web:
            add(menu, "在浏览器中打开", "\r", []) { [weak self] in self?.activate(row) }
            add(menu, "拷贝网址", "c", [.command]) { [weak self] in self?.copySelected() }
        case .definition(let word, let definition):
            add(menu, "在“词典”中打开", "\r", []) { [weak self] in self?.activate(row) }
            add(menu, "拷贝释义", "c", [.command], enabled: definition != nil) { [weak self] in self?.copySelected() }
            add(menu, "拷贝“\(word)”", "", []) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(word, forType: .string)
            }
        }
        let index = max(0, table.selectedRow)
        let rect = table.numberOfRows > 0 ? table.rect(ofRow: index) : table.bounds
        menuOpen = true
        _ = menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 40, y: rect.maxY), in: table)
        menuOpen = false
        if panel.isVisible { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field) }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags,
                     enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let entry = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
        entry.keyEquivalentModifierMask = modifiers
        entry.isEnabled = enabled
        menu.addItem(entry)
        return entry
    }

    private func open(_ result: SearchResult, with app: URL) {
        hide()
        coordinator.recents.record(result.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([result.url], withApplicationAt: app, configuration: configuration) { _, error in
            if let error { DispatchQueue.main.async { Self.presentError(error) } }
        }
    }

    private func openInTerminal(_ result: SearchResult) {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: result.path, isDirectory: &isDirectory)
        let folder = isDirectory.boolValue && !result.isApplication ? result.url : result.url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        hide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: configuration) { _, error in
            if let error { DispatchQueue.main.async { Self.presentError(error) } }
        }
    }

    /// Moves to the Trash (it can be put back from there), then removes the row.
    private func moveToTrash(_ result: SearchResult) {
        NSWorkspace.shared.recycle([result.url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.statusLabel.stringValue = "未能移到废纸篓：\(error.localizedDescription)"
                    return
                }
                let index = self.table.selectedRow
                self.rows.removeAll { $0.file?.path == result.path }
                self.table.reloadData()
                if !self.rows.isEmpty {
                    self.table.selectRowIndexes(IndexSet(integer: min(max(0, index), self.rows.count - 1)), byExtendingSelection: false)
                }
                self.updatePreview()
                self.statusLabel.stringValue = "已将“\(result.fileName)”移到废纸篓（可在废纸篓中放回）"
            }
        }
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Quick Look

    private func toggleQuickLook() {
        guard selectedResult != nil else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible {
            ql.orderOut(nil)
            return
        }
        quickLookOpen = true
        // Quick Look needs KongFetch to be active to take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
    }

    func quickLookDidEnd() {
        quickLookOpen = false
        if panel.isVisible { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field) }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedResult == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let url = selectedResult?.url else { return nil }
        return url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys inside Quick Look move through the results.
        guard event.type == .keyDown else { return false }
        switch Int(event.keyCode) {
        case 125: moveSelection(by: 1); panel.reloadData(); return true
        case 126: moveSelection(by: -1); panel.reloadData(); return true
        default: return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SoftSelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("result")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TwoLineCellView ?? {
            let view = TwoLineCellView(frame: .zero)
            view.identifier = id
            return view
        }()
        cell.badge.stringValue = row < 9 ? "⌘\(row + 1)" : ""
        switch rows[row] {
        case .file(let result):
            cell.icon.image = NSWorkspace.shared.icon(forFile: result.path)
            cell.title.stringValue = result.displayName
            let parent = (result.path as NSString).deletingLastPathComponent
            cell.subtitle.stringValue = PathDisplay.pretty(parent, home: NSHomeDirectory())
        case .definition(let word, let definition):
            cell.icon.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "词典")
            cell.title.stringValue = "词典：\(word)"
            cell.subtitle.stringValue = definition.map {
                String($0.prefix(120)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            } ?? "系统词典中没有找到"
        case .web(let link, let query):
            cell.icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "网页搜索")
            cell.title.stringValue = "在\(link.name)中搜索「\(query)」"
            cell.subtitle.stringValue = "网页搜索 · 关键词 \(link.keyword) · " + (link.url(for: query)?.host ?? "网址无效")
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if NSApp.currentEvent?.type == .leftMouseDown || NSApp.currentEvent?.type == .leftMouseUp { userChoseRow = true }
        updatePreview()
        if quickLookOpen, QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.reloadData() }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), let file = rows[row].file else { return nil }
        return file.url as NSURL
    }

    @objc private func toggleMode() {
        contentMode.toggle()
        modeButton.title = contentMode ? "全文" : "名称"
        field.placeholderString = contentMode ? "搜索文件内容（PDF、Word、Pages、文本……）" : "搜索文件、文件夹和应用"
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        runSearch(field.stringValue)
    }

    private func updatePreview() {
        if case .definition(let word, let definition)? = selectedRow {
            preview.showDefinition(word: word, text: definition)
            return
        }
        let needles = contentMode && !showingRecents ? SearchQuery.parse(field.stringValue).nameNeedles : []
        preview.show(selectedResult, needles: needles)
    }
}

/// Right-hand pane: thumbnail and basic facts about the selected item.
final class FilePreviewView: NSView {
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let snippetLabel = NSTextField(wrappingLabelWithString: "")
    /// Scrollable text for dictionary definitions; hidden while a file is shown.
    private let definitionScroll = NSTextView.scrollableTextView()
    private var definitionView: NSTextView { definitionScroll.documentView as! NSTextView }
    private var currentPath: String?
    private var currentNeedles: [String] = []
    var ocrStore: OCRStore?
    private static let snippetQueue = DispatchQueue(label: "KongFetch.snippet", qos: .userInitiated)

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 3
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = true
        snippetLabel.font = .systemFont(ofSize: 12)
        snippetLabel.maximumNumberOfLines = 7
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.isSelectable = true
        for view in [imageView, nameLabel, detailLabel, snippetLabel, definitionScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        definitionScroll.isHidden = true
        definitionScroll.drawsBackground = false
        definitionScroll.hasVerticalScroller = true
        definitionScroll.autohidesScrollers = true
        definitionView.isEditable = false
        definitionView.isSelectable = true
        definitionView.drawsBackground = false
        definitionView.textContainerInset = NSSize(width: 14, height: 14)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 150),
            imageView.heightAnchor.constraint(equalToConstant: 150),
            nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 12),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            snippetLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 10),
            snippetLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            snippetLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            definitionScroll.topAnchor.constraint(equalTo: topAnchor),
            definitionScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            definitionScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            definitionScroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows a dictionary definition instead of a file.
    func showDefinition(word: String, text: String?) {
        currentPath = nil
        for view in [imageView, nameLabel, detailLabel, snippetLabel] as [NSView] { view.isHidden = true }
        definitionScroll.isHidden = false
        let content = NSMutableAttributedString(string: word + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.labelColor
        ])
        content.append(NSAttributedString(string: text ?? "系统词典中没有找到这个词。", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: text == nil ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]))
        definitionView.textStorage?.setAttributedString(content)
        definitionView.scrollToBeginningOfDocument(nil)
    }

    /// `needles` are the content-search words; when given, a passage containing them is shown.
    func show(_ result: SearchResult?, needles: [String] = []) {
        if !definitionScroll.isHidden {
            definitionScroll.isHidden = true
            for view in [imageView, nameLabel, detailLabel, snippetLabel] as [NSView] { view.isHidden = false }
        }
        guard let result else {
            currentPath = nil
            imageView.image = nil
            nameLabel.stringValue = ""
            detailLabel.stringValue = ""
            snippetLabel.stringValue = ""
            return
        }
        guard result.path != currentPath || needles != currentNeedles else { return }
        currentPath = result.path
        currentNeedles = needles
        showSnippet(for: result.url, needles: needles)
        imageView.image = NSWorkspace.shared.icon(forFile: result.path)
        nameLabel.stringValue = result.displayName

        let url = result.url
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isPackageKey])
        var lines: [String] = []
        if let type = values?.localizedTypeDescription { lines.append("种类：\(type)") }
        if values?.isDirectory != true || values?.isPackage == true, let size = values?.fileSize ?? result.size {
            lines.append("大小：" + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let modified = values?.contentModificationDate ?? result.modified { lines.append("修改：\(modified.shortDescription)") }
        lines.append("位置：" + PathDisplay.pretty(url.deletingLastPathComponent().path, home: NSHomeDirectory()))
        detailLabel.stringValue = lines.joined(separator: "\n")

        let scale = window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 150, height: 150), scale: scale, representationTypes: .thumbnail)
        let path = result.path
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let thumbnail else { return }
            DispatchQueue.main.async {
                guard let self, self.currentPath == path else { return }
                self.imageView.image = thumbnail.nsImage
            }
        }
    }

    private func showSnippet(for url: URL, needles: [String]) {
        snippetLabel.stringValue = ""
        guard !needles.isEmpty else { return }
        snippetLabel.stringValue = "正在查找文中位置…"
        snippetLabel.textColor = .tertiaryLabelColor
        let path = url.path
        let ocr = ocrStore
        Self.snippetQueue.async { [weak self] in
            let outcome = ContentPreview.find(in: url, needles: needles, ocr: ocr)
            DispatchQueue.main.async {
                guard let self, self.currentPath == path, self.currentNeedles == needles else { return }
                self.snippetLabel.textColor = .labelColor
                switch outcome {
                case .found(let found):
                    let text = NSMutableAttributedString(string: found.snippet.text, attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
                    ])
                    text.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45),
                                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold)], range: found.snippet.highlight)
                    let label = (found.page.map { "第 \($0) 页" } ?? "") + (found.recognized ? "（识别文字）" : "")
                    if !label.isEmpty {
                        text.insert(NSAttributedString(string: label + "：", attributes: [
                            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor
                        ]), at: 0)
                    }
                    self.snippetLabel.attributedStringValue = text
                case .notFound:
                    self.snippetLabel.textColor = .secondaryLabelColor
                    self.snippetLabel.stringValue = "匹配可能在文件名、元数据或无法直接读取的内容中。"
                case .notDownloaded:
                    self.snippetLabel.textColor = .secondaryLabelColor
                    self.snippetLabel.stringValue = "iCloud 文件尚未下载到本机，打开后可查看匹配位置。"
                case .unsupported:
                    self.snippetLabel.stringValue = ""
                }
            }
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

import AppKit
import Combine
import KongFetchCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let bundleIdentifier = "com.kongxiangrui.KongFetch"
    static let legacyBundleIdentifier = "com.kongfetch.mac"

    private let preferences = Preferences.shared
    private let status = AppStatus()
    private let doubleTap = DoubleTapMonitor()
    private var statusItem: NSStatusItem!
    private var searchPanel: SearchPanelController!
    private var clipboardPanel: ClipboardPanelController!
    private var clipboardMonitor: ClipboardMonitor!
    private var clipboardHistory: ClipboardHistory!
    private var settingsWindow: SettingsWindowController?
    private var subscriptions = Set<AnyCancellable>()
    private var folderAccessCache: (checked: Date, state: [String: Bool], fullDisk: Bool)?
    private var pinyinIndex: PinyinIndexService!
    private var ocr: OCRService!
    private var updater: Updater!
    private var snippets: SnippetLibrary!
    private var snippetExpansion: SnippetExpansionService!

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KongFetch4", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if quitIfAlreadyRunning() { return }
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        let support = Self.supportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let recents = RecentItems(fileURL: support.appendingPathComponent("recents.json"))
        clipboardHistory = ClipboardHistory(store: ClipboardStore(directory: support.appendingPathComponent("Clipboard", isDirectory: true)),
                                            limits: preferences.clipboardLimits)
        clipboardMonitor = ClipboardMonitor(history: clipboardHistory, preferences: preferences)
        pinyinIndex = PinyinIndexService(cacheURL: support.appendingPathComponent("pinyin-index.txt"))
        pinyinIndex.onChange = { [weak self] in self?.status.refresh() }
        updater = Updater(supportDirectory: support)
        updater.onChange = { [weak self] in self?.status.refresh() }
        if preferences.autoCheckUpdates { updater.startAutomaticChecks() }
        ocr = OCRService(directory: support.appendingPathComponent("OCR", isDirectory: true))
        ocr.onChange = { [weak self] in self?.status.refresh() }
        searchPanel = SearchPanelController(coordinator: FileSearchCoordinator(recents: recents, preferences: preferences,
                                                                               pinyinIndex: pinyinIndex.index, ocrStore: ocr.store))
        snippets = SnippetLibrary(fileURL: support.appendingPathComponent("snippets.json"))
        snippetExpansion = SnippetExpansionService(library: snippets, monitor: clipboardMonitor)
        clipboardPanel = ClipboardPanelController(monitor: clipboardMonitor, preferences: preferences, library: snippets)
        searchPanel.openSettings = { [weak self] in self?.openSettings() }
        searchPanel.quickLinks = { [preferences] in preferences.quickLinks }
        clipboardPanel.openSettings = { [weak self] in self?.openSettings() }

        buildStatusItem()
        registerHotKeys()
        doubleTap.onDoubleTap = { [weak self] in self?.searchPanel.toggle() }
        doubleTap.trigger = preferences.doubleTapModifier
        doubleTap.refresh()
        clipboardMonitor.start()
        status.provider = { [weak self] in self?.makeSnapshot() ?? AppStatus.Snapshot() }
        observePreferences()
        snippetExpansion.enabled = preferences.snippetExpansion
        snippetExpansion.reloadSnippets()
        ocr.configure(ocrSettings)
        offerToQuitLegacyVersion()

        searchPanel.accessHint = { [weak self] in self?.folderAccessHint() }
        if !preferences.folderAccessRequested {
            // Ask now so Spotlight results from Documents, Desktop, Downloads and iCloud Drive are not hidden.
            requestFolderAccess()
        } else {
            restartPinyinIndex()
        }

        if !preferences.hasCompletedFirstLaunch {
            preferences.hasCompletedFirstLaunch = true
            if preferences.doubleTapModifier != .off && !doubleTap.hasPermission {
                _ = CGRequestListenEventAccess()
            }
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        clipboardHistory?.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching KongFetch again from Finder or Spotlight shows the search panel.
        searchPanel.show()
        return false
    }

    // MARK: Setup

    private func quitIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let other = others.first else { return false }
        other.activate(options: [])
        NSApp.terminate(nil)
        return true
    }

    /// KongFetch 3.x would also react to double Control and record the clipboard; offer to quit it.
    private func offerToQuitLegacyVersion() {
        let legacy = NSRunningApplication.runningApplications(withBundleIdentifier: Self.legacyBundleIdentifier)
        guard !legacy.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "旧版 KongFetch 仍在运行"
        alert.informativeText = "旧版也会响应连按 Control 并记录剪贴板，两者同时运行会互相干扰。要退出旧版吗？"
        alert.addButton(withTitle: "退出旧版")
        alert.addButton(withTitle: "保留")
        if alert.runModal() == .alertFirstButtonReturn {
            legacy.forEach { $0.terminate() }
        }
        NSApp.hide(nil)
    }

    private func registerHotKeys() {
        HotKeyCenter.shared.register(preferences.searchShortcut, for: .search) { [weak self] in self?.searchPanel.toggle() }
        HotKeyCenter.shared.register(preferences.clipboardShortcut, for: .clipboard) { [weak self] in self?.clipboardPanel.toggle() }
        HotKeyCenter.shared.register(preferences.lookupShortcut, for: .lookup) { [weak self] in self?.lookUpSelection() }
    }

    /// Looks up the text selected in the frontmost app in the search window's dictionary.
    private func lookUpSelection() {
        SelectedText.fetch(monitor: clipboardMonitor) { [weak self] text in
            let firstLine = text?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let word = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
            self?.searchPanel.show(query: DictionaryLookup.keyword + " " + word)
        }
    }

    private func observePreferences() {
        // @Published delivers the new value before the property is stored, so always use the value passed in.
        preferences.$searchShortcut.dropFirst().sink { [weak self] shortcut in
            HotKeyCenter.shared.register(shortcut, for: .search) { self?.searchPanel.toggle() }
            self?.status.refresh()
        }.store(in: &subscriptions)
        preferences.$clipboardShortcut.dropFirst().sink { [weak self] shortcut in
            HotKeyCenter.shared.register(shortcut, for: .clipboard) { self?.clipboardPanel.toggle() }
            self?.status.refresh()
        }.store(in: &subscriptions)
        preferences.$lookupShortcut.dropFirst().sink { [weak self] shortcut in
            HotKeyCenter.shared.register(shortcut, for: .lookup) { self?.lookUpSelection() }
            self?.status.refresh()
        }.store(in: &subscriptions)
        preferences.$doubleTapModifier.dropFirst().sink { [weak self] modifier in
            self?.doubleTap.trigger = modifier
        }.store(in: &subscriptions)
        preferences.$clipboardRetentionDays.combineLatest(preferences.$clipboardMaximumItems).dropFirst().sink { [weak self] days, count in
            self?.clipboardHistory.limits = ClipboardHistory.Limits(maximumItems: max(20, min(count, 2000)), retentionDays: days > 0 ? days : nil)
        }.store(in: &subscriptions)
        preferences.$pinyinIndexEnabled.combineLatest(preferences.$pinyinIndexExtraRoots).dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.restartPinyinIndex() }
            .store(in: &subscriptions)
        preferences.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.ocr.configure(self.ocrSettings)
            }
            .store(in: &subscriptions)
        preferences.$autoCheckUpdates.dropFirst().sink { [weak self] enabled in
            if enabled { self?.updater.startAutomaticChecks() } else { self?.updater.stopAutomaticChecks() }
        }.store(in: &subscriptions)
        preferences.$clipboardEnabled.dropFirst().sink { [weak self] enabled in
            if enabled { self?.clipboardMonitor.skipCurrentContents() }
        }.store(in: &subscriptions)
        preferences.$snippetExpansion.dropFirst().sink { [weak self] enabled in
            self?.snippetExpansion.enabled = enabled
            self?.status.refresh()
        }.store(in: &subscriptions)
        snippets.$snippets.dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.snippetExpansion.reloadSnippets() }
            .store(in: &subscriptions)
    }

    private func installMainMenu() {
        // Not visible (no Dock icon), but needed for ⌘C / ⌘V / ⌘, in Settings.
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "KongFetch")
        appMenu.addItem(withTitle: "关于 KongFetch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 KongFetch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
            button.toolTip = "KongFetch"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let search = menu.addItem(withTitle: "搜索文件", action: #selector(showSearch), keyEquivalent: "")
        search.target = self
        if let shortcut = preferences.searchShortcut { search.title += "    " + shortcut.display }
        let clipboard = menu.addItem(withTitle: "剪贴板历史", action: #selector(showClipboard), keyEquivalent: "")
        clipboard.target = self
        if let shortcut = preferences.clipboardShortcut { clipboard.title += "    " + shortcut.display }
        if preferences.clipboardEnabled {
            let pause = menu.addItem(withTitle: preferences.clipboardPaused ? "继续记录剪贴板" : "暂停记录剪贴板",
                                     action: #selector(toggleClipboardPause), keyEquivalent: "")
            pause.target = self
        }
        menu.addItem(.separator())
        if preferences.doubleTapModifier != .off && !doubleTap.isListening {
            let warning = menu.addItem(withTitle: "⚠︎ 连按 \(preferences.doubleTapModifier.title) 未生效，点此查看", action: #selector(openSettingsAction), keyEquivalent: "")
            warning.target = self
        }
        switch updater.state.phase {
        case .updating(let step):
            menu.addItem(withTitle: "正在更新：" + step, action: nil, keyEquivalent: "")
        default:
            if !updater.state.pending.isEmpty {
                let item = menu.addItem(withTitle: "安装更新（\(updater.state.pending.count) 项）…", action: #selector(installUpdateFromMenu), keyEquivalent: "")
                item.target = self
            }
        }
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 KongFetch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func showSearch() { searchPanel.show() }
    @objc private func showClipboard() { clipboardPanel.show() }

    @objc private func toggleClipboardPause() {
        preferences.clipboardPaused.toggle()
        if !preferences.clipboardPaused { clipboardMonitor.skipCurrentContents() }
    }

    @objc private func openSettingsAction() { openSettings() }

    // MARK: Settings

    private func openSettings() {
        if settingsWindow == nil {
            let actions = SettingsActions(
                requestInputMonitoring: { [weak self] in
                    self?.doubleTap.requestPermission()
                    self?.snippetExpansion.refresh()
                },
                requestAccessibility: { Paster.requestTrust(); Paster.openAccessibilitySettings() },
                setLoginItem: { [weak self] enabled in
                    do { try LoginItem.set(enabled) } catch {
                        let alert = NSAlert(error: error)
                        alert.runModal()
                    }
                    self?.status.refresh()
                },
                clearClipboard: { [weak self] includingPinned in self?.clipboardHistory.clear(includingPinned: includingPinned); self?.status.refresh() },
                revealDataFolder: { NSWorkspace.shared.activateFileViewerSelecting([AppDelegate.supportDirectory.appendingPathComponent("Clipboard")]) },
                requestFolderAccess: { [weak self] in self?.requestFolderAccess() },
                rebuildPinyinIndex: { [weak self] in self?.pinyinIndex.rebuild(); self?.status.refresh() },
                ocrCheckNow: { [weak self] in self?.ocr.checkNow() },
                ocrSetPaused: { [weak self] paused in self?.ocr.setPaused(paused); self?.status.refresh() },
                ocrClear: { [weak self] in self?.ocr.clearResults() },
                checkForUpdates: { [weak self] in self?.updater.clearFailure(); self?.updater.check() },
                installUpdate: { [weak self] in self?.updater.update() },
                rollbackUpdate: { [weak self] in self?.confirmRollback() },
                showUpdateLog: { [weak self] in
                    guard let url = self?.updater.logURL, FileManager.default.fileExists(atPath: url.path) else { return }
                    NSWorkspace.shared.open(url)
                }
            )
            settingsWindow = SettingsWindowController(preferences: preferences, status: status, library: snippets, actions: actions)
        }
        settingsWindow?.present()
    }

    private func makeSnapshot() -> AppStatus.Snapshot {
        var s = AppStatus.Snapshot()
        s.inputMonitoringAllowed = doubleTap.hasPermission
        s.doubleTapListening = doubleTap.isListening
        s.lastKeyboardEvent = doubleTap.lastEventAt
        s.lastDoubleTap = doubleTap.lastFiredAt
        s.accessibilityAllowed = Paster.isTrusted
        s.searchHotKeyRegistered = HotKeyCenter.shared.isRegistered(.search)
        s.clipboardHotKeyRegistered = HotKeyCenter.shared.isRegistered(.clipboard)
        s.lookupHotKeyRegistered = HotKeyCenter.shared.isRegistered(.lookup)
        s.loginItemEnabled = LoginItem.isEnabled
        s.loginItemNote = LoginItem.note
        s.signing = SigningInfo.describe()
        let info = Bundle.main.infoDictionary
        s.version = "\(info?["CFBundleShortVersionString"] as? String ?? "开发版") (\(info?["CFBundleVersion"] as? String ?? "-"))"
        s.bundlePath = Bundle.main.bundleURL.path
        s.clipboardCount = clipboardHistory.items.count
        s.clipboardBytes = clipboardHistory.totalBytes
        let access = folderAccessState()
        s.folderAccess = access.state
        s.fullDiskAccess = access.fullDisk
        s.pinyinIndexCount = pinyinIndex.index.count
        s.pinyinIndexScanning = pinyinIndex.isScanning
        s.pinyinIndexUpdated = pinyinIndex.lastCompleted
        s.pinyinIndexRoots = pinyinRoots()
        s.ocrRecognized = ocr.store.recognizedDocumentCount
        s.ocrProgress = ocr.progress
        s.ocrPaused = ocr.paused
        s.update = updater.state
        s.snippetListening = snippetExpansion.isListening
        s.snippetInputMethodActive = snippetExpansion.inputMethodActive
        s.snippetProblem = snippetExpansion.lastProblem
        s.snippetLastExpansion = snippetExpansion.lastExpansion
        return s
    }

    // MARK: Updates

    @objc private func installUpdateFromMenu() {
        let pending = updater.state.pending
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "安装 KongFetch 更新？"
        alert.informativeText = pending.prefix(10).map { "• " + $0 }.joined(separator: "\n") +
            "\n\n将在本机编译（约一两分钟），完成后 KongFetch 会自动重新打开。"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "以后")
        if alert.runModal() == .alertFirstButtonReturn {
            updater.update()
            openSettings()
        } else {
            NSApp.hide(nil)
        }
    }

    private func confirmRollback() {
        guard let latest = updater.state.backups.first else { return }
        let alert = NSAlert()
        alert.messageText = "回退到 \(latest.replacingOccurrences(of: ".app", with: ""))？"
        alert.informativeText = "KongFetch 会退出并打开上一版。设置和数据不受影响。"
        alert.addButton(withTitle: "回退")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { updater.rollback() }
    }

    private var ocrSettings: OCRService.Settings {
        OCRService.Settings(enabled: preferences.ocrEnabled, folders: preferences.ocrFolders,
                            pageLimit: preferences.ocrPageLimit, onlyOnPower: preferences.ocrOnlyOnPower,
                            downloadFromICloud: preferences.ocrDownloadFromICloud)
    }

    // MARK: Pinyin index

    /// Allowed default folders plus the user's extra folders, or nothing when the index is off.
    private func pinyinRoots() -> [String] {
        guard preferences.pinyinIndexEnabled else { return [] }
        let access = folderAccessState()
        var roots = FolderAccess.folders.filter { access.fullDisk || access.state[$0.id] == true }.map(\.url.path)
        for extra in preferences.pinyinIndexExtraRoots {
            let path = (extra as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
               !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                roots.append(path)
            }
        }
        return roots
    }

    private func restartPinyinIndex() {
        pinyinIndex.start(roots: pinyinRoots())
    }

    // MARK: Folder access

    private func requestFolderAccess() {
        preferences.folderAccessRequested = true
        let state = FolderAccess.requestAll()
        folderAccessCache = (Date(), state, FolderAccess.hasFullDiskAccess)
        restartPinyinIndex()
        status.refresh()
    }

    /// Cached for a few seconds: listing the folders every second while Settings is open is wasteful.
    private func folderAccessState() -> (state: [String: Bool], fullDisk: Bool) {
        guard preferences.folderAccessRequested else { return ([:], FolderAccess.hasFullDiskAccess) }
        if let cache = folderAccessCache, Date().timeIntervalSince(cache.checked) < 5 { return (cache.state, cache.fullDisk) }
        let state = FolderAccess.currentState()
        let fullDisk = FolderAccess.hasFullDiskAccess
        folderAccessCache = (Date(), state, fullDisk)
        return (state, fullDisk)
    }

    /// Shown in the search panel when nothing is found and some folders are off limits.
    private func folderAccessHint() -> String? {
        let access = folderAccessState()
        guard !access.fullDisk else { return nil }
        let denied = FolderAccess.folders.filter { access.state[$0.id] == false }.map(\.title)
        guard !denied.isEmpty else { return nil }
        return "未授权访问“\(denied.joined(separator: "、"))”，其中的文件搜不到（⌘, 打开设置）"
    }
}

/// The menu bar icon: a magnifier with a small "k", drawn as a template so it follows light/dark mode.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 5, width: 11, height: 11))
            ring.lineWidth = 1.8
            ring.stroke()
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 11.4, y: 6.6))
            handle.line(to: NSPoint(x: 16, y: 2))
            handle.lineWidth = 2.2
            handle.lineCapStyle = .round
            handle.stroke()
            let k = NSAttributedString(string: "k", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: NSColor.black
            ])
            let size = k.size()
            k.draw(at: NSPoint(x: 7.5 - size.width / 2, y: 10.5 - size.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}

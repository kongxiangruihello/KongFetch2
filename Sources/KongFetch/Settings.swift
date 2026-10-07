import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import KongFetchCore

/// Live facts shown in Settings and Diagnostics, refreshed every second while Settings is open.
final class AppStatus: ObservableObject {
    struct Snapshot: Equatable {
        var inputMonitoringAllowed = false
        var doubleTapListening = false
        var lastKeyboardEvent: Date?
        var lastDoubleTap: Date?
        var accessibilityAllowed = false
        var searchHotKeyRegistered = false
        var clipboardHotKeyRegistered = false
        var loginItemEnabled = false
        var loginItemNote = ""
        var signing = ""
        var version = ""
        var bundlePath = ""
        var clipboardCount = 0
        var clipboardBytes = 0
    }

    @Published private(set) var snapshot = Snapshot()
    var provider: (() -> Snapshot)?
    private var timer: Timer?

    func startUpdating() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopUpdating() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        if let next = provider?(), next != snapshot { snapshot = next }
    }
}

/// Things the settings screen can ask the app to do.
struct SettingsActions {
    var requestInputMonitoring: () -> Void
    var requestAccessibility: () -> Void
    var setLoginItem: (Bool) -> Void
    var clearClipboard: (_ includingPinned: Bool) -> Void
    var revealDataFolder: () -> Void
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var status: AppStatus
    let actions: SettingsActions

    var body: some View {
        TabView {
            GeneralSettings(preferences: preferences, status: status, actions: actions)
                .tabItem { Label("通用", systemImage: "gearshape") }
            SearchSettings(preferences: preferences)
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            ClipboardSettings(preferences: preferences, status: status, actions: actions)
                .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }
            DiagnosticsView(preferences: preferences, status: status, actions: actions)
                .tabItem { Label("诊断", systemImage: "stethoscope") }
        }
        .padding(20)
        .frame(width: 600, height: 500)
    }
}

private struct StatusBadge: View {
    let ok: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundColor(ok ? .green : .orange)
            .font(.callout)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var status: AppStatus
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                LabeledContent("搜索快捷键") {
                    ShortcutRecorder(shortcut: $preferences.searchShortcut)
                        .frame(width: 220, height: 24)
                }
                if preferences.searchShortcut != nil && !status.snapshot.searchHotKeyRegistered {
                    Text("这个组合已被其他应用占用，请换一个。").font(.caption).foregroundColor(.orange)
                }
                Picker("连按两次唤起", selection: $preferences.doubleTapModifier) {
                    ForEach(TapModifier.allCases) { Text($0.title).tag($0) }
                }
                if preferences.doubleTapModifier != .off {
                    HStack {
                        if status.snapshot.doubleTapListening {
                            StatusBadge(ok: true, text: "正在监听")
                        } else {
                            StatusBadge(ok: false, text: status.snapshot.inputMonitoringAllowed ? "监听尚未启动，稍候会自动重试" : "需要“输入监控”权限")
                            Spacer()
                            Button("授权…") { actions.requestInputMonitoring() }
                        }
                    }
                    Text("快速按下并松开两次，中间不要按其他键。授权后无需重启。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section {
                Toggle("登录时启动", isOn: Binding(get: { status.snapshot.loginItemEnabled }, set: { actions.setLoginItem($0) }))
                if !status.snapshot.loginItemNote.isEmpty {
                    Text(status.snapshot.loginItemNote).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SearchSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("范围") {
                Toggle("包含“资源库”和隐藏文件夹", isOn: $preferences.includeLibraryFolders)
                VStack(alignment: .leading, spacing: 6) {
                    Text("不搜索这些文件夹（每行一个，可用 ~）")
                    TextEditor(text: Binding(
                        get: { preferences.excludedPathPrefixes.joined(separator: "\n") },
                        set: { preferences.excludedPathPrefixes = $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
            }
            Section("搜索语法") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("合同 2024　　名称同时包含两个词")
                    Text("\"年度 合同\"　　完整短语")
                    Text("-草稿　　　　排除包含该词的名称")
                    Text("ext:pdf,docx 或 .pdf　　扩展名")
                    Text("kind:folder　　应用 / 文件夹 / 图片 / pdf / 文档 / 视频 / 音频 / 压缩包")
                    Text("days:7　　　　最近 7 天修改过")
                    Text("拼音：应用名称和最近打开的文件支持全拼与首字母，例如 wx、weixin")
                }
                .font(.callout)
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ClipboardSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var status: AppStatus
    let actions: SettingsActions
    @State private var selection = Set<String>()
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("记录剪贴板历史", isOn: $preferences.clipboardEnabled)
                LabeledContent("打开历史的快捷键") {
                    ShortcutRecorder(shortcut: $preferences.clipboardShortcut).frame(width: 220, height: 24)
                }
                if preferences.clipboardShortcut != nil && !status.snapshot.clipboardHotKeyRegistered {
                    Text("这个组合已被其他应用占用，请换一个。").font(.caption).foregroundColor(.orange)
                }
                Toggle("选中后直接粘贴到当前应用", isOn: $preferences.autoPaste)
                if preferences.autoPaste {
                    HStack {
                        StatusBadge(ok: status.snapshot.accessibilityAllowed,
                                    text: status.snapshot.accessibilityAllowed ? "已获得辅助功能权限" : "需要“辅助功能”权限，否则只拷贝不粘贴")
                        Spacer()
                        if !status.snapshot.accessibilityAllowed { Button("授权…") { actions.requestAccessibility() } }
                    }
                }
            }
            Section("保留") {
                Picker("未固定的记录保留", selection: $preferences.clipboardRetentionDays) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("一年").tag(365)
                    Text("一直保留").tag(0)
                }
                Picker("最多保留", selection: $preferences.clipboardMaximumItems) {
                    Text("100 条").tag(100)
                    Text("300 条").tag(300)
                    Text("1000 条").tag(1000)
                }
                HStack {
                    Text("当前 \(status.snapshot.clipboardCount) 条，占用 " + ByteCountFormatter.string(fromByteCount: Int64(status.snapshot.clipboardBytes), countStyle: .file))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("在访达中显示") { actions.revealDataFolder() }
                    Button("清空…") { confirmClear = true }
                }
            }
            Section("不记录这些应用中的复制") {
                List(selection: $selection) {
                    ForEach(preferences.clipboardExcludedApps, id: \.self) { bundleID in
                        HStack {
                            Text(Self.appName(bundleID))
                            Spacer()
                            Text(bundleID).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .frame(height: 110)
                HStack {
                    Button("添加应用…") { addApps() }
                    Button("移除所选") {
                        preferences.clipboardExcludedApps.removeAll { selection.contains($0) }
                        selection.removeAll()
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    Button("恢复默认") {
                        let merged = Set(preferences.clipboardExcludedApps).union(Preferences.defaultExcludedApps)
                        preferences.clipboardExcludedApps = merged.sorted()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清空剪贴板历史？", isPresented: $confirmClear) {
            Button("清空未固定的记录", role: .destructive) { actions.clearClipboard(false) }
            Button("全部清空（包括固定）", role: .destructive) { actions.clearClipboard(true) }
        } message: {
            Text("只删除 KongFetch 保存的历史，不影响当前剪贴板。")
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.title = "选择不记录的应用"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        var list = preferences.clipboardExcludedApps
        for id in ids where !list.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) { list.append(id) }
        preferences.clipboardExcludedApps = list
    }

    static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        }
        return "（未安装）"
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var status: AppStatus
    let actions: SettingsActions

    var body: some View {
        let s = status.snapshot
        VStack(alignment: .leading, spacing: 10) {
            Text("连按两次修饰键：如果没反应，按顺序看下面几项").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("1. 输入监控权限", s.inputMonitoringAllowed ? "已允许" : "未允许", s.inputMonitoringAllowed)
                row("2. 键盘监听", s.doubleTapListening ? "正在监听" : "未启动", s.doubleTapListening)
                row("3. 最近收到按键", s.lastKeyboardEvent.map(Self.time) ?? "尚未收到", s.lastKeyboardEvent != nil)
                row("4. 最近一次识别为连按", s.lastDoubleTap.map(Self.time) ?? "尚未识别", s.lastDoubleTap != nil)
                row("触发键", preferences.doubleTapModifier.title, preferences.doubleTapModifier != .off)
                Divider()
                row("搜索快捷键", s.searchHotKeyRegistered ? "已注册 " + (preferences.searchShortcut?.display ?? "") : "未注册", s.searchHotKeyRegistered)
                row("剪贴板快捷键", s.clipboardHotKeyRegistered ? "已注册 " + (preferences.clipboardShortcut?.display ?? "") : "未注册", s.clipboardHotKeyRegistered)
                row("辅助功能（自动粘贴）", s.accessibilityAllowed ? "已允许" : "未允许", s.accessibilityAllowed)
                row("签名", s.signing, !s.signing.contains("ad hoc"))
                row("版本", s.version, true)
            }
            Text(s.bundlePath).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            Text("第 1 项已允许但第 2 项未启动：在“系统设置 › 隐私与安全性 › 输入监控”中删除 KongFetch 后重新添加。签名为 ad hoc 时，每次更新都需要这样重新授权。")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("授权输入监控…") { actions.requestInputMonitoring() }
                Button("拷贝诊断信息") { copyReport(s) }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String, _ ok: Bool) -> some View {
        GridRow {
            Text(title)
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundColor(ok ? .green : .orange)
                Text(value).textSelection(.enabled)
            }
        }
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func copyReport(_ s: AppStatus.Snapshot) {
        let lines = [
            "KongFetch \(s.version)", s.bundlePath, "签名：\(s.signing)",
            "输入监控：\(s.inputMonitoringAllowed)", "监听：\(s.doubleTapListening)",
            "最近按键：\(s.lastKeyboardEvent.map(Self.time) ?? "-")", "最近连按：\(s.lastDoubleTap.map(Self.time) ?? "-")",
            "触发键：\(preferences.doubleTapModifier.rawValue)",
            "搜索快捷键：\(s.searchHotKeyRegistered) \(preferences.searchShortcut?.display ?? "-")",
            "剪贴板快捷键：\(s.clipboardHotKeyRegistered) \(preferences.clipboardShortcut?.display ?? "-")",
            "辅助功能：\(s.accessibilityAllowed)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onChange = { shortcut = $0 }
        return button
    }

    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        view.onChange = { shortcut = $0 }
        view.shortcut = shortcut
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut? { didSet { if !isRecording { refreshTitle() } } }
    var onChange: ((Shortcut?) -> Void)?
    private var isRecording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(clicked)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func clicked() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        title = "按下组合键…（⎋ 取消，⌫ 清除）"
        // Release our own hot keys so pressing the current combination is captured here.
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain && event.keyCode == 53 { stopRecording(); return }               // Esc
        if plain && (event.keyCode == 51 || event.keyCode == 117) {               // Delete
            onChange?(nil)
            shortcut = nil
            stopRecording()
            return
        }
        guard let recorded = Shortcut(event: event) else { NSSound.beep(); return }
        shortcut = recorded
        onChange?(recorded)
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeyCenter.shared.resume()
        refreshTitle()
    }

    private func refreshTitle() {
        title = shortcut?.display ?? "点击设置"
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil && isRecording { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
}

// MARK: - Window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let status: AppStatus

    init(preferences: Preferences, status: AppStatus, actions: SettingsActions) {
        self.status = status
        let host = NSHostingController(rootView: SettingsView(preferences: preferences, status: status, actions: actions))
        let window = NSWindow(contentViewController: host)
        window.title = "KongFetch 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        status.startUpdating()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        status.stopUpdating()
        // KongFetch has no Dock icon; give focus back to the previous app.
        DispatchQueue.main.async { NSApp.hide(nil) }
    }
}

// MARK: - Login item and signing

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var note: String {
        switch SMAppService.mainApp.status {
        case .requiresApproval: return "需要在“系统设置 › 通用 › 登录项”中允许 KongFetch。"
        case .notFound: return Bundle.main.bundleURL.pathExtension == "app" ? "请先把 KongFetch 放进“应用程序”文件夹。" : "开发模式运行时不可用。"
        default: return ""
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

enum SigningInfo {
    /// Describes how the running app is signed, which decides whether permissions survive updates.
    static func describe() -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return "无法读取"
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return "未签名" }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return "ad hoc（每次更新后需重新授权）"
        }
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let first = certificates.first, let name = SecCertificateCopySubjectSummary(first) as String? {
            return "证书：\(name)"
        }
        return "已签名"
    }
}

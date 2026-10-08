import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KongFetchCore

/// State of the batch-rename window.
final class BatchRenameModel: ObservableObject {
    @Published var items: [BatchRename.Item] = []
    @Published var rule = BatchRename.Rule()
    @Published var message: String?
    /// Moves that would undo the last rename (new path → old path).
    @Published private(set) var undoMoves: [(from: String, to: String)] = []

    var previews: [BatchRename.Preview] {
        BatchRename.plan(items, rule: rule) { FileManager.default.fileExists(atPath: $0) }
    }

    func add(_ urls: [URL]) {
        var known = Set(items.map(\.path))
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !known.contains(path), FileManager.default.fileExists(atPath: path) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            items.append(BatchRename.Item(path: path, modified: modified))
            known.insert(path)
        }
        message = nil
    }

    func remove(_ paths: Set<String>) {
        items.removeAll { paths.contains($0.path) }
    }

    /// Files selected in the frontmost Finder window (asks once for permission to control Finder).
    func addFinderSelection() {
        let source = """
        tell application "Finder"
            set picked to selection as alias list
            set output to ""
            repeat with anItem in picked
                set output to output & POSIX path of anItem & linefeed
            end repeat
            return output
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
            message = code == -1743
                ? "没有控制“访达”的权限：请在“系统设置 › 隐私与安全性 › 自动化”中允许 KongFetch 控制“访达”。"
                : "没能读取访达中的选择。"
            return
        }
        let urls = result.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        if urls.isEmpty { message = "访达中没有选中的文件。" }
        add(urls)
    }

    /// Renames everything without problems. If any move fails, the moves already made are undone.
    func apply() {
        let plan = previews
        let steps = BatchRename.steps(for: plan)
        guard !steps.isEmpty else { message = "没有需要改名的文件。"; return }
        let fm = FileManager.default
        var done: [(from: String, to: String)] = []
        do {
            for step in steps {
                try fm.moveItem(atPath: step.from, toPath: step.to)
                done.append(step)
            }
        } catch {
            for step in done.reversed() { try? fm.moveItem(atPath: step.to, toPath: step.from) }
            message = "改名失败，已全部恢复：\(error.localizedDescription)"
            return
        }
        let renamed = plan.filter { $0.changed && $0.problem == nil }
        undoMoves = renamed.map { ($0.newPath, $0.item.path) }
        // Keep working with the renamed files.
        let byOld = Dictionary(uniqueKeysWithValues: renamed.map { ($0.item.path, $0.newPath) })
        items = items.map { item in
            guard let new = byOld[item.path] else { return item }
            return BatchRename.Item(path: new, modified: item.modified)
        }
        let skipped = plan.filter { $0.changed && $0.problem != nil }.count
        message = "已改名 \(renamed.count) 个文件" + (skipped > 0 ? "，\(skipped) 个有问题未改" : "") + "。可以“撤销”。"
        log(renamed.map { "\($0.item.path) → \($0.newName)" })
    }

    func undo() {
        guard !undoMoves.isEmpty else { return }
        // Undo is a rename plan too (new names back to old), done the same safe way.
        let previews = undoMoves.map { move in
            BatchRename.Preview(item: BatchRename.Item(path: move.from), newName: (move.to as NSString).lastPathComponent, problem: nil)
        }
        let fm = FileManager.default
        var done: [(from: String, to: String)] = []
        do {
            for step in BatchRename.steps(for: previews) {
                try fm.moveItem(atPath: step.from, toPath: step.to)
                done.append(step)
            }
        } catch {
            for step in done.reversed() { try? fm.moveItem(atPath: step.to, toPath: step.from) }
            message = "撤销失败（文件可能已被移动）：\(error.localizedDescription)"
            return
        }
        let back = Dictionary(uniqueKeysWithValues: undoMoves.map { ($0.from, $0.to) })
        items = items.map { item in back[item.path].map { BatchRename.Item(path: $0, modified: item.modified) } ?? item }
        message = "已撤销 \(undoMoves.count) 个文件的改名。"
        log(undoMoves.map { "撤销：\($0.from) → \(($0.to as NSString).lastPathComponent)" })
        undoMoves = []
    }

    private func log(_ lines: [String]) {
        let url = AppDelegate.supportDirectory.appendingPathComponent("rename.log")
        let text = "== \(Date())\n" + lines.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

struct BatchRenameView: View {
    @ObservedObject var model: BatchRenameModel
    @State private var selection = Set<String>()
    @State private var dropTargeted = false

    var body: some View {
        let previews = model.previews
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("添加文件…") { addFiles() }
                Button("使用访达中选中的文件") { model.addFinderSelection() }
                Button("移除所选") { model.remove(selection); selection.removeAll() }.disabled(selection.isEmpty)
                Button("清空") { model.items.removeAll(); selection.removeAll() }.disabled(model.items.isEmpty)
                Spacer()
                Text("\(model.items.count) 个文件").foregroundColor(.secondary)
            }
            ruleEditor
            Table(previews, selection: $selection) {
                TableColumn("原名称") { preview in
                    Text(preview.item.name).lineLimit(1).truncationMode(.middle)
                }
                TableColumn("新名称") { preview in
                    HStack(spacing: 4) {
                        if let problem = preview.problem {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).help(problem.message)
                        }
                        Text(preview.newName).lineLimit(1).truncationMode(.middle)
                            .foregroundColor(preview.problem != nil ? .orange : (preview.changed ? .primary : .secondary))
                    }
                }
                TableColumn("说明") { preview in
                    Text(preview.problem?.message ?? (preview.changed ? "" : "不变"))
                        .foregroundColor(.secondary).lineLimit(1)
                }
                .width(min: 80, ideal: 150)
            }
            .overlay {
                if model.items.isEmpty {
                    Text("把文件拖到这里，或点“添加文件…”“使用访达中选中的文件”")
                        .foregroundColor(.secondary)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: dropTargeted ? 2 : 0))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.add([url]) } }
                    }
                }
                return true
            }
            HStack {
                if let message = model.message {
                    Text(message).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                Button("撤销") { model.undo() }.disabled(model.undoMoves.isEmpty)
                let count = previews.filter { $0.changed && $0.problem == nil }.count
                Button(count > 0 ? "改名 \(count) 个文件" : "改名") { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
    }

    private var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $model.rule.mode) {
                ForEach(BatchRename.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            if model.rule.mode == .replace {
                HStack {
                    TextField("查找", text: $model.rule.find).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    TextField("替换为（可留空）", text: $model.rule.replacement).textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 16) {
                    Toggle("正则表达式（$1 引用分组）", isOn: $model.rule.useRegex)
                    Toggle("忽略大小写", isOn: $model.rule.ignoreCase)
                }
            } else {
                HStack {
                    TextField("模板", text: $model.rule.template).textFieldStyle(.roundedBorder)
                    Stepper("起始 \(model.rule.start)", value: $model.rule.start, in: 0...99_999)
                    Stepper("位数 \(model.rule.digits)", value: $model.rule.digits, in: 1...6)
                }
                HStack(spacing: 16) {
                    Text("{name} 原名　{n} 编号　{date} 修改日期　{parent} 所在文件夹").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Picker("编号顺序", selection: $model.rule.order) {
                        ForEach(BatchRename.Order.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 200)
                }
            }
            HStack(spacing: 16) {
                Toggle("保留扩展名", isOn: $model.rule.keepExtension)
                Picker("繁简", selection: $model.rule.script) {
                    ForEach(BatchRename.Script.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 180)
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择要改名的文件"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        model.add(panel.urls)
    }
}

extension BatchRename.Preview: Identifiable {
    public var id: String { item.path }
}

final class BatchRenameWindowController: NSWindowController, NSWindowDelegate {
    let model = BatchRenameModel()

    init() {
        let host = NSHostingController(rootView: BatchRenameView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "批量重命名"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 600))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the window; `urls` are added to the list.
    func present(adding urls: [URL] = []) {
        model.add(urls)
        NSApp.setActivationPolicy(.regular)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    func windowWillClose(_ notification: Notification) {
        // Stay a menu-bar app unless Settings is still open.
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.title == "KongFetch 设置" }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

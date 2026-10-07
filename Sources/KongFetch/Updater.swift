import AppKit
import Security

/// Updates KongFetch from its own source folder.
///
/// The app is signed with a certificate that only exists on this Mac, so updates are built here:
/// fetch the GitHub repository, fast-forward, run scripts/build-app.sh, check that the new app carries
/// the same signature identity (so permissions survive), back up the running app, then a small helper
/// script swaps the bundles after KongFetch quits and opens the new one.
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case updating(String)
        case failed(String)
    }

    struct State: Equatable {
        var phase: Phase = .idle
        /// Subjects of commits on GitHub that are not installed yet, newest first.
        var pending: [String] = []
        var lastCheck: Date?
        var sourceRoot: String?
        var backups: [String] = []
    }

    private(set) var state = State()
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "KongFetch.updater", qos: .utility)
    private let supportDirectory: URL
    private var timer: Timer?
    var logURL: URL { supportDirectory.appendingPathComponent("update.log") }
    private var backupsURL: URL { supportDirectory.appendingPathComponent("Backups", isDirectory: true) }

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
        state.sourceRoot = Self.locateSourceRoot()
        state.backups = listBackups()
    }

    // MARK: Source folder

    /// The repository this copy was built from: recorded in Info.plist by the build script,
    /// or the usual place in Documents.
    static func locateSourceRoot() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let recorded = Bundle.main.object(forInfoDictionaryKey: "KFSourceRoot") as? String { candidates.append(recorded) }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub/KongFetch2").path)
        return candidates.first { fm.fileExists(atPath: $0 + "/.git") && fm.fileExists(atPath: $0 + "/scripts/build-app.sh") }
    }

    // MARK: Checking

    /// Checks on launch (after a short delay) and then every six hours.
    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check() }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        switch state.phase {
        case .checking, .updating: return
        default: break
        }
        guard let root = state.sourceRoot else {
            set { $0.phase = .failed("找不到 KongFetch 的源码文件夹（应在 文稿/GitHub/KongFetch2）") }
            return
        }
        set { $0.phase = .checking }
        queue.async { [weak self] in
            guard let self else { return }
            let fetch = self.git(["fetch", "--quiet", "origin", "main"], root)
            guard fetch.status == 0 else {
                self.set { $0.phase = .idle; $0.lastCheck = Date() }
                self.log("检查失败：\(fetch.output)")
                return
            }
            // Compare with the commit this running copy was built from (after a rollback that is older than
            // the source folder), falling back to the source folder's HEAD.
            let base = Self.installedCommit.flatMap { self.git(["cat-file", "-e", $0], root).status == 0 ? $0 : nil } ?? "HEAD"
            let log = self.git(["log", "--format=%s", "\(base)..origin/main"], root)
            let subjects = log.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            self.set { $0.phase = .idle; $0.pending = subjects; $0.lastCheck = Date() }
        }
    }

    /// Recorded by the build script; nil for builds made before 4.3.2.
    static var installedCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "KFSourceCommit") as? String
    }

    // MARK: Updating

    /// Pulls, builds, verifies and installs. KongFetch quits and reopens when it succeeds.
    func update() {
        guard let root = state.sourceRoot else { return }
        switch state.phase {
        case .checking, .updating: return
        default: break
        }
        set { $0.phase = .updating("正在获取更新…") }
        queue.async { [weak self] in
            guard let self else { return }
            self.log("==== 更新开始 \(Date())")
            do {
                try self.step(self.git(["fetch", "--quiet", "origin", "main"], root), "无法连接 GitHub")
                let dirty = self.git(["status", "--porcelain", "--untracked-files=no"], root)
                guard dirty.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw UpdateError("源码文件夹里有未提交的修改，为避免覆盖，已停止更新。")
                }
                try self.step(self.git(["merge", "--ff-only", "origin/main"], root), "无法合并 GitHub 上的新代码")

                self.set { $0.phase = .updating("正在编译（约一两分钟）…") }
                try self.step(self.run("/bin/bash", ["scripts/build-app.sh"], root), "编译失败")

                let built = URL(fileURLWithPath: root).appendingPathComponent("build/KongFetch.app")
                self.set { $0.phase = .updating("正在校验签名…") }
                try self.verifySignature(of: built)

                self.set { $0.phase = .updating("正在备份当前版本…") }
                try self.backupRunningApp()

                self.set { $0.phase = .updating("正在安装，KongFetch 将重新打开…") }
                try self.installAndRelaunch(built)
            } catch {
                let message = (error as? UpdateError)?.message ?? error.localizedDescription
                self.log("失败：\(message)")
                self.set { $0.phase = .failed(message) }
            }
        }
    }

    /// Reinstalls the most recent backup.
    func rollback() {
        guard let latest = listBackups().first else { return }
        let url = backupsURL.appendingPathComponent(latest)
        set { $0.phase = .updating("正在回退到 \(latest)…") }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.installAndRelaunch(url)
            } catch {
                self.set { $0.phase = .failed("回退失败：\(error.localizedDescription)") }
            }
        }
    }

    func clearFailure() {
        if case .failed = state.phase { set { $0.phase = .idle } }
    }

    // MARK: Steps (on `queue`)

    private struct UpdateError: Error { let message: String; init(_ message: String) { self.message = message } }

    private func step(_ result: (status: Int32, output: String), _ failure: String) throws {
        guard result.status == 0 else {
            let detail = result.output.split(separator: "\n").suffix(3).joined(separator: " ")
            throw UpdateError(failure + (detail.isEmpty ? "" : "：" + detail))
        }
    }

    /// The new app must satisfy the running app's designated requirement, so macOS keeps treating
    /// it as the same app (Input Monitoring and Accessibility stay granted).
    private func verifySignature(of app: URL) throws {
        var current: SecStaticCode?
        var candidate: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &current) == errSecSuccess, let current,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw UpdateError("无法读取新版本的签名")
        }
        if SigningInfo.describe().contains("ad hoc") {
            log("当前版本为 ad hoc 签名，跳过身份比对；更新后需重新授权。")
            guard SecStaticCodeCheckValidity(candidate, [], nil) == errSecSuccess else { throw UpdateError("新版本签名无效") }
            return
        }
        guard SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("无法读取当前版本的签名要求")
        }
        let status = SecStaticCodeCheckValidity(candidate, [], requirement)
        guard status == errSecSuccess else {
            throw UpdateError("新版本的签名与当前版本不一致（\(status)），为保住已授予的权限，已停止安装。请确认钥匙串里的“KongFetch Local Signing”证书还在。")
        }
    }

    private func backupRunningApp() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let target = backupsURL.appendingPathComponent(Self.runningBackupName)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try step(run("/usr/bin/ditto", [Bundle.main.bundleURL.path, target.path], "/"), "备份失败")
        // Keep the two most recent earlier versions (plus the one just backed up).
        for old in listBackups().dropFirst(2) { try? fm.removeItem(at: backupsURL.appendingPathComponent(old)) }
        set { $0.backups = self.listBackups() }
    }

    /// Writes a helper that waits for KongFetch to quit, swaps the bundle (restoring the old one if
    /// copying fails) and opens the result. Then quits KongFetch.
    private func installAndRelaunch(_ newApp: URL) throws {
        let target = Bundle.main.bundleURL.path.hasSuffix(".app") ? Bundle.main.bundleURL.path : "/Applications/KongFetch.app"
        let script = """
        #!/bin/bash
        pid="$1"; new="$2"; target="$3"; log="$4"
        for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        {
          echo "安装 $new -> $target"
          rm -rf "$target.updating-old"
          if mv "$target" "$target.updating-old" && ditto "$new" "$target"; then
            rm -rf "$target.updating-old"
            echo "安装完成"
          else
            echo "安装失败，恢复原版本"
            rm -rf "$target"
            mv "$target.updating-old" "$target"
          fi
        } >> "$log" 2>&1
        open "$target"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("kongfetch-install-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target, logURL.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        log("已启动安装程序，KongFetch 即将退出。")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Backup name of the running copy, e.g. "KongFetch-4.3.2-14.app".
    private static var runningBackupName: String {
        let info = Bundle.main.infoDictionary
        return "KongFetch-\(info?["CFBundleShortVersionString"] as? String ?? "?")-\(info?["CFBundleVersion"] as? String ?? "?").app"
    }

    /// Backups other than the version that is running now (after a rollback the backup of the
    /// running version is still there, and reinstalling it would change nothing), newest build first.
    private func listBackups() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: backupsURL.path))?.filter { $0.hasSuffix(".app") } ?? []
        func build(_ name: String) -> Int {
            Int(name.dropLast(4).split(separator: "-").last ?? "") ?? 0
        }
        func modified(_ name: String) -> Date {
            (try? fm.attributesOfItem(atPath: backupsURL.appendingPathComponent(name).path)[.modificationDate] as? Date) ?? .distantPast
        }
        return names.filter { $0 != Self.runningBackupName }.sorted { a, b in
            build(a) != build(b) ? build(a) > build(b) : modified(a) > modified(b)
        }
    }

    // MARK: Processes

    private func git(_ arguments: [String], _ root: String) -> (status: Int32, output: String) {
        run("/usr/bin/git", ["-C", root] + arguments, root)
    }

    /// Runs a command to completion, appending its output to the update log.
    private func run(_ executable: String, _ arguments: [String], _ directory: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0" // never wait for a password prompt
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            log("$ \(executable) \(arguments.joined(separator: " "))\n无法运行：\(error.localizedDescription)")
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        log("$ \(executable) \(arguments.joined(separator: " "))\n\(output)(退出码 \(process.terminationStatus))")
        return (process.terminationStatus, output)
    }

    private func log(_ text: String) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    private func set(_ change: @escaping (inout State) -> Void) {
        DispatchQueue.main.async {
            var next = self.state
            change(&next)
            if next != self.state {
                self.state = next
                self.onChange?()
            }
        }
    }
}

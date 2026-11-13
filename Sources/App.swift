import AppKit
import ApplicationServices

@main
final class App: NSObject, NSApplicationDelegate {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false
    )
    private let output = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private var actionButtons: [NSButton] = []
    private var logLines: [String] = []
    private var busy = false
    private let worker = DispatchQueue(label: "com.gavzen.storeswitch.poc.ax")
    private let clock = ISO8601DateFormatter()

    static func main() {
        if CommandLine.arguments.dropFirst() == ["--self-check"] {
            let checks: [(String, Bool)] = [
                ("Store menu localized", ["Store", "商店", "Mağaza"].allSatisfy(StoreLabel.store.matches)),
                ("Sign Out aliases", ["Sign Out…", "退出登录", "登出", "Oturumu Kapat"].allSatisfy(StoreLabel.signOut.matches)),
                ("Sign Out exact", !StoreLabel.signOut.matches("Sign Out of All Accounts")),
                ("Sign In aliases", ["Sign In", "登录", "登入", "Oturum Aç"].allSatisfy(StoreLabel.signIn.matches)),
                ("signed out", StoreState(signIn: 1, signOut: 0, complete: true) == .signedOut),
                ("signed in", StoreState(signIn: 0, signOut: 1, complete: true) == .signedIn),
                ("missing, duplicate, contradictory, incomplete menu",
                 [(0, 0, true), (0, 2, true), (1, 1, true), (0, 1, false)].allSatisfy {
                     StoreState(signIn: $0.0, signOut: $0.1, complete: $0.2) == .unknown
                 }),
                ("exact account field", acceptsAccountField(role: kAXTextFieldRole, subrole: nil, labels: ["Email or Phone Number"])),
                ("secure field rejected", !acceptsAccountField(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, labels: ["Apple ID"])),
                ("generic field rejected", !acceptsAccountField(role: kAXTextFieldRole, subrole: nil, labels: ["Email"])),
                ("non-text control rejected", !acceptsAccountField(role: kAXButtonRole, subrole: nil, labels: ["Apple ID"]))
            ]
            for (name, passed) in checks { print("\(passed ? "PASS" : "FAIL") · \(name)") }
            exit(checks.allSatisfy(\.1) ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "App Store 账号切换验证"
        window.minSize = NSSize(width: 750, height: 430)
        window.isReleasedWhenClosed = false

        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出验证工具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = menu

        let instructions = NSTextField(wrappingLabelWithString: "先开启辅助功能授权，再打开 App Store 并运行只读检查。退出和预填各需单独确认。")
        status.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        let controls = NSStackView(views: [
            button("检查授权", #selector(checkTrust)), button("请求授权", #selector(requestTrust)),
            button("打开 App Store", #selector(openStore)), button("只读检查", #selector(inspect)),
            button("展开 Store 菜单", #selector(revealMenu))
        ])
        controls.spacing = 8
        let operations = NSStackView(views: [
            button("退出当前账号…", #selector(signOut)), button("打开原生登录", #selector(openSignIn)),
            button("预填测试邮箱…", #selector(fill)), button("保存日志…", #selector(saveLog))
        ])
        operations.spacing = 8
        output.isEditable = false
        output.isRichText = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.textContainerInset = NSSize(width: 10, height: 10)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = output

        let content = NSView()
        let stack = NSStackView(views: [instructions, status, controls, operations, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        let storeVersion = Bundle(url: storeURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let pocVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let languages = Locale.preferredLanguages.prefix(3).joined(separator: ", ")
        append("启动 · POC \(pocVersion) · \(ProcessInfo.processInfo.operatingSystemVersionString) · App Store \(storeVersion) · 首选语言 \(languages)")
        checkTrust()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        actionButtons.append(button)
        return button
    }

    private func append(_ message: String) {
        let line = "\(clock.string(from: Date()))  \(message)"
        logLines.append(line)
        output.textStorage?.append(NSAttributedString(
            string: line + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        ))
        output.scrollToEndOfDocument(nil)
    }

    private func setBusy(_ value: Bool) {
        busy = value
        actionButtons.forEach { $0.isEnabled = !value }
    }

    @objc private func checkTrust() {
        let trusted = AXIsProcessTrusted()
        status.stringValue = trusted ? "辅助功能：已授权" : "辅助功能：未授权"
        append("AXIsProcessTrusted=\(trusted)")
    }

    @objc private func requestTrust() {
        if AXIsProcessTrusted() {
            checkTrust()
            return
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        append("已请求 macOS 辅助功能提示 · 返回时 trusted=\(trusted)。在系统设置授权后点击「检查授权」。")
    }

    @objc private func openStore() {
        guard !busy else { return }
        setBusy(true)
        activateStore { [weak self] app in
            guard let self else { return }
            if let app {
                self.append("App Store 已启动或已运行 · bundle=\(storeBundleID) · PID=\(app.processIdentifier)")
            }
            self.append("启动后前台 App Store=\(app != nil)")
            self.setBusy(false)
        }
    }

    private func activateStore(
        expectedPID: pid_t? = nil, completion: @escaping (NSRunningApplication?) -> Void
    ) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: storeURL, configuration: config) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let app, isSystemStore(app) else {
                    let failure = error.map { ($0 as NSError).code }
                    self.append("打开系统 App Store 失败 · 错误码 \(failure.map(String.init) ?? "未知")")
                    completion(nil)
                    return
                }
                guard expectedPID == nil || expectedPID == app.processIdentifier else {
                    self.append("App Store 进程已变更，停止当前操作。")
                    completion(nil)
                    return
                }
                self.waitForFrontmost(app, attempts: 15) { active in
                    if !active { self.append("App Store 未成为前台，已停止。") }
                    completion(active ? app : nil)
                }
            }
        }
    }

    @objc private func inspect() { run(.inspect) }
    @objc private func revealMenu() { run(.revealMenu) }
    @objc private func openSignIn() { run(.openSignIn) }

    @objc private func signOut() {
        confirm(.signOut, detail: "工具会检查「商店」菜单，确认「退出登录」可用后执行一次。当前 App Store 会话可能退出。")
    }

    @objc private func fill() {
        confirm(.fill, detail: "仅向识别到的 App Store Apple Account 文本框写入 \(testEmail)，可能覆盖框内文字。测试后请在原生界面关闭或取消。")
    }

    private func confirm(_ operation: StoreOperation, detail: String) {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = operation.rawValue
        alert.informativeText = detail
        alert.addButton(withTitle: "取消").keyEquivalent = "\r"
        alert.addButton(withTitle: operation.rawValue).keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                self.append("用户已确认 · \(operation.rawValue)")
                self.run(operation)
            } else {
                self.append("用户已取消 · \(operation.rawValue)")
            }
        }
    }

    private func run(_ operation: StoreOperation) {
        guard !busy else { return }
        append("开始 · \(operation.rawValue)")
        guard AXIsProcessTrusted() else {
            checkTrust()
            append("请授权后重试。")
            return
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: storeBundleID).filter(isSystemStore)
        guard apps.count == 1, let app = apps.first else {
            append("未找到唯一的系统 App Store 进程。请先点击「打开 App Store」。")
            return
        }

        setBusy(true)
        if operation.needsFrontmost {
            activateStore(expectedPID: app.processIdentifier) { [weak self] activeApp in
                guard let self else { return }
                guard let activeApp else {
                    self.setBusy(false)
                    return
                }
                self.append("已确认 App Store 在前台 · PID=\(activeApp.processIdentifier)")
                self.scan(operation, pid: activeApp.processIdentifier)
            }
        } else {
            scan(operation, pid: app.processIdentifier)
        }
    }

    private func waitForFrontmost(
        _ app: NSRunningApplication, attempts: Int, completion: @escaping (Bool) -> Void
    ) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            completion(true)
        } else if attempts == 0 || app.isTerminated {
            completion(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForFrontmost(app, attempts: attempts - 1, completion: completion)
            }
        }
    }

    private func scan(_ operation: StoreOperation, pid: pid_t) {
        worker.async { [weak self] in
            StoreAX(pid: pid) { line in
                DispatchQueue.main.async { self?.append(line) }
            }.run(operation)
            DispatchQueue.main.async { self?.setBusy(false) }
        }
    }

    @objc private func saveLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StoreSwitchPOC.log"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                try (self.logLines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                self.append("日志已保存。")
            } catch {
                self.append("日志保存失败 · 错误码 \((error as NSError).code)")
            }
        }
    }
}

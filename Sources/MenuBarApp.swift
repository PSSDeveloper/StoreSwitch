import AppKit
import ApplicationServices
import CoreServices
import Security
import SwiftUI
import Carbon.HIToolbox

@main
@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let preferences = UserDefaults.standard
    private let passwords = PasswordKeychain()
    private let clock = ISO8601DateFormatter()
    private let shortcut = MenuShortcut()
    private var accounts: [StoreAccount] = []
    private var lastSelected: UUID?
    private let logHistory = LogHistory()
    private let loginReadout = LoginReadout()
    private var checkWindow: NSWindow?
    private var checkingFromMenu = false
    private var accountWindow: NSWindow?
    private var savingPassword = false
    private var logWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var menuIsOpen = false
    private lazy var automation = AppStoreAutomation { [weak self] in self?.append($0) }
    private lazy var coordinator = AccountSwitchCoordinator(service: automation) { [weak self] in self?.append([$0]) }

    static func main() {
        let application = NSApplication.shared
        let delegate = MenuBarApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = preferences.data(forKey: "accounts"),
           let saved = try? JSONDecoder().decode([StoreAccount].self, from: data) {
            var seen = Set<UUID>()
            persistAccounts(saved.filter { StoreAccount.validEmail($0.email) && seen.insert($0.id).inserted })
        }
        if let stored = preferences.string(forKey: "lastSelectedAccountID") {
            lastSelected = UUID(uuidString: stored)
        } else if let previousRegion = preferences.string(forKey: "lastSelected"),
                  let previous = accounts.first(where: { $0.region.rawValue == previousRegion }) {
            lastSelected = previous.id
            preferences.set(previous.id.uuidString, forKey: "lastSelectedAccountID")
            preferences.removeObject(forKey: "lastSelected")
        }
        logHistory.lines = Array((preferences.stringArray(forKey: "operationLog") ?? []).suffix(300))
        statusItem.button?.image = NSImage(named: "AccountSwitchTemplate")
        statusItem.button?.setAccessibilityLabel("App Store 账号切换")
        statusItem.button?.toolTip = "App Store 账号切换"
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        buildApplicationMenu()
        updateShortcut()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        append(["StoreSwitch \(version) · \(ProcessInfo.processInfo.operatingSystemVersionString)"])
        // Xcode can launch the executable directly. Refresh the app bundle's registration
        // so macOS can look up its icon by bundle identifier.
        let registration = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        if registration != noErr {
            append(["应用包登记失败 · \(registration)"])
        }
        if CommandLine.arguments.contains("--manage-accounts") {
            Task { showAccounts() }
        } else if accounts.isEmpty {
            showAccounts()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if accounts.isEmpty { showAccounts() }
        else { showMenu() }
        return false
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let step = coordinator.step
        let trusted = AXIsProcessTrusted()
        add("App Store 账号切换")
        add(step.title)
        if let state = coordinator.storeState {
            add("上次检查：\(state.menuTitle)")
        } else if let error = coordinator.checkError, step.canSelect {
            add("上次检查：\(error)")
        }
        if let target = coordinator.target, !step.canSelect {
            add("目标：\(target.label)")
        } else if let lastSelected, let account = accounts.first(where: { $0.id == lastSelected }) {
            add("上次选择：\(account.label)")
        }
        if case let .needsSignOut(detail) = step { add(detail) }
        if case let .needsSignIn(detail) = step { add(detail) }
        if case let .needsInitialCheck(detail) = step { add(detail) }
        menu.addItem(.separator())

        if accounts.isEmpty {
            add("添加账号…", #selector(showAccounts), enabled: step.canSelect)
        }
        for (index, account) in accounts.enumerated() {
            let mode = account.passwordID == nil ? "" : " · 自动登录"
            let key = index < 9 ? String(index + 1) : ""
            let item = add("切换到 \(account.label)\(mode)…", #selector(selectAccount(_:)),
                           key: key, enabled: step.canSelect && !savingPassword)
            item.representedObject = account.id.uuidString
        }

        if !step.canSelect && !step.isWorking {
            menu.addItem(.separator())
            if case .needsSignOut = step {
                add("退出后继续登录准备", #selector(continueAfterSignOut))
            }
            if case .needsInitialCheck = step {
                add("重新检查并继续切换", #selector(retryInitialCheck))
            }
            if coordinator.isWaitingForLogin,
               step != .awaitingAuthentication(.submitted), step != .awaitingAuthentication(.submissionUncertain) {
                add("重新打开原生登录", #selector(retryOpenSignIn))
                add("重试预填已打开的表单", #selector(retryPrefill))
            }
            add("复制目标邮箱", #selector(copyTarget), key: "c")
            add("结束本次切换", #selector(endSwitch))
        }

        menu.addItem(.separator())
        if !trusted {
            add("辅助功能未授权")
            add("辅助功能授权…", #selector(showPermissionGuide), enabled: !step.isWorking)
        }
        add("打开 App Store", #selector(openStore), enabled: !step.isWorking)
        add("检查 App Store 登录状态", #selector(checkLogin), key: "r", enabled: !step.isWorking)
        add("管理账号…", #selector(showAccounts), key: ",", enabled: step.canSelect)
        let hotkey = add("全局菜单快捷键（⌃⌥S）", #selector(toggleShortcut))
        hotkey.state = shortcut.isRegistered ? .on : .off
        add("操作日志…", #selector(showLog), key: "l")
        menu.addItem(.separator())
        add("关于 StoreSwitch", #selector(showAbout), enabled: !step.isWorking)
        add("退出 StoreSwitch", #selector(quit), key: "q", enabled: !step.isWorking && !savingPassword)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == nil ? nil : self
        item.isEnabled = action != nil && enabled
        menu.addItem(item)
        return item
    }

    @objc private func selectAccount(_ sender: NSMenuItem) {
        guard NSApp.modalWindow == nil, coordinator.step.canSelect, !savingPassword,
              let id = sender.representedObject as? String,
              let account = accounts.first(where: { $0.id.uuidString == id }) else { return }
        guard AXIsProcessTrusted() else {
            showPermissionGuide()
            return
        }
        lastSelected = account.id
        preferences.set(id, forKey: "lastSelectedAccountID")
        accountWindow?.close()
        Task {
            await coordinator.start(account) { [weak self] account in
                self?.confirmExit(account) == true
            }
        }
    }

    private func confirmExit(_ account: StoreAccount) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "切换 App Store 账号？"
        let login = account.passwordID == nil ? "预填目标邮箱" : "使用钥匙串中的密码在 App Store 提交登录"
        alert.informativeText = "目标：\(account.email)\n\nStoreSwitch 将退出当前 App Store 账号，然后尝试\(login)。请在 App Store 完成 Apple 要求的验证。"
        alert.addButton(withTitle: "取消").keyEquivalent = "\r"
        alert.addButton(withTitle: "退出并继续").keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func continueAfterSignOut() { Task { await coordinator.continueAfterSignOut() } }
    @objc private func retryInitialCheck() {
        Task { await coordinator.retryInitialCheck { [weak self] in self?.confirmExit($0) == true } }
    }
    @objc private func retryOpenSignIn() { Task { await coordinator.retryLogin(openIfNeeded: true) } }
    @objc private func retryPrefill() { Task { await coordinator.retryLogin(openIfNeeded: false) } }
    @objc private func checkLogin() {
        if checkingFromMenu {
            checkWindow?.makeKeyAndOrderFront(nil)
            return
        }
        // A manual check shouldn't take focus away from a running sign-in or sign-out.
        if coordinator.step.isWorking {
            Task { await coordinator.checkLogin() }
            return
        }
        checkingFromMenu = true
        loginReadout.message = nil
        if let checkWindow, checkWindow.isVisible {
            NSApp.activate()
            checkWindow.makeKeyAndOrderFront(nil)
        } else {
            checkWindow = showWindow("App Store 登录状态", content: LoginStatusView(readout: loginReadout) { [weak self] in
                self?.checkWindow?.close()
            })
        }
        Task {
            let result = await coordinator.checkLogin()
            loginReadout.message = result.message
            checkingFromMenu = false
        }
    }

    @objc private func endSwitch() { coordinator.end() }

    @objc private func copyTarget() {
        guard let target = coordinator.target else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target.email, forType: .string)
    }

    @objc private func openStore() {
        Task {
            do { _ = try await automation.openStore() }
            catch { showMessage("无法打开 App Store", (error as? StoreAutomationError)?.message ?? "") }
        }
    }

    @objc private func showPermissionGuide() {
        NSApp.activate()
        let settingsPage = if #available(macOS 27, *) {
            "隐私与安全 → 设备控制和数据访问"
        } else {
            "隐私与安全性 → 辅助功能"
        }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "开启辅助功能"
        alert.informativeText = "在系统设置的「\(settingsPage)」中开启 StoreSwitch。如果旧条目仍显示默认图标，请移除该条目，再添加当前的 StoreSwitch.app。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "在访达中显示当前 App")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            append(["用户打开辅助功能设置"])
        case .alertThirdButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default:
            break
        }
    }

    @objc private func showAccounts() {
        guard coordinator.step.canSelect else { return }
        if let accountWindow, accountWindow.isVisible || savingPassword {
            NSApp.activate()
            accountWindow.makeKeyAndOrderFront(nil)
            return
        }
        let form = AccountDrafts(accounts)
        let editor = AccountEditor(form: form, save: { [weak self, weak form] entries in
            self?.saveAccounts(entries, form: form)
        }, close: { [weak self] in self?.accountWindow?.close() }, editPassword: { [weak self, weak form] id in
            self?.editPassword(id, form: form)
        }, removePassword: { [weak self, weak form] id in
            self?.removePassword(id, form: form)
        })
        accountWindow = showWindow("管理 App Store 账号", content: editor)
    }

    private func saveAccounts(_ entries: [StoreAccount], form: AccountDrafts?) {
        guard coordinator.step.canSelect, !savingPassword,
              entries.allSatisfy({ StoreAccount.validEmail($0.email) }) else { return }
        let newEmails = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.email) })
        for account in accounts where newEmails[account.id] != account.email {
            guard removePassword(account.id, form: form) else { return }
        }
        let savedPasswords = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            account.passwordID.map { (account.id, $0) }
        })
        let updates = entries.map { entry in
            StoreAccount(id: entry.id, region: entry.region, email: entry.email, passwordID: savedPasswords[entry.id])
        }
        persistAccounts(updates)
        if let lastSelected, !updates.contains(where: { $0.id == lastSelected }) {
            self.lastSelected = nil
            preferences.removeObject(forKey: "lastSelectedAccountID")
        }
        form?.didSave(updates)
    }

    private func persistAccounts(_ updates: [StoreAccount]) {
        guard let data = try? JSONEncoder().encode(updates) else { return }
        preferences.set(data, forKey: "accounts")
        accounts = updates
    }

    private func editPassword(_ accountID: UUID, form: AccountDrafts?) {
        guard coordinator.step.canSelect, !savingPassword,
              let account = accounts.first(where: { $0.id == accountID }) else { return }
        do {
            try LocalPasswordItems.checkForRebuild()
        } catch {
            showKeychainFailure("无法保存密码", error)
            return
        }
        let alert = NSAlert()
        alert.messageText = "设置自动登录密码"
        alert.informativeText = "账号：\(account.email)\n密码仅存于本机钥匙串。以后从菜单选择此账号时，StoreSwitch 会尝试在系统 App Store 中提交登录。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Apple Account 密码"
        field.setAccessibilityLabel("Apple Account 密码")
        alert.accessoryView = field
        alert.addButton(withTitle: "存入钥匙串并启用")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        defer { field.stringValue = "" }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = field.stringValue
        guard !password.isEmpty else {
            showMessage("请输入密码", "密码留空时不会保存。")
            return
        }
        let id = account.passwordID ?? UUID()
        savingPassword = true
        form?.isSavingPassword = true
        Task {
            defer {
                savingPassword = false
                form?.isSavingPassword = false
            }
            do {
                // macOS can ask for authorization while the vault is read or updated.
                try await Task.detached(priority: .userInitiated) {
                    try PasswordKeychain().save(password, id: id)
                }.value
                var updates = accounts
                if let index = updates.firstIndex(where: { $0.id == accountID }) {
                    updates[index].passwordID = id
                    persistAccounts(updates)
                    form?.updatePassword(id, for: accountID)
                }
            } catch {
                showKeychainFailure("无法保存密码", error)
            }
        }
    }

    @discardableResult
    private func removePassword(_ accountID: UUID, form: AccountDrafts?) -> Bool {
        guard coordinator.step.canSelect, !savingPassword else { return false }
        guard let index = accounts.firstIndex(where: { $0.id == accountID }),
              let id = accounts[index].passwordID else { return true }
        do {
            try passwords.remove(id)
            var updates = accounts
            updates[index].passwordID = nil
            persistAccounts(updates)
            form?.updatePassword(nil, for: accountID)
            return true
        } catch {
            showKeychainFailure("无法移除账号密码", error)
            return false
        }
    }

    private func showKeychainFailure(_ title: String, _ error: Error) {
        let failure = error as? KeychainFailure
        append([failure?.logMessage ?? "钥匙串 · 密码操作失败"])
        guard failure?.status == errSecCSStaticCodeChanged else {
            showMessage(title, failure?.userMessage ?? "请查看 StoreSwitch 的操作日志后重试。")
            return
        }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "需要重新打开 StoreSwitch"
        alert.informativeText = "磁盘上的 StoreSwitch 已更新。请重新打开应用，再访问钥匙串。账号列表中未保存的修改需要重新填写。"
        alert.addButton(withTitle: "重新打开")
        alert.addButton(withTitle: "稍后")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        shortcut.stop()
        Task {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = true
            config.arguments = ["--manage-accounts"]
            do {
                _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
                NSApp.terminate(nil)
            } catch {
                updateShortcut()
                showMessage("无法重新打开 StoreSwitch", "请在构建完成后退出 StoreSwitch，再从访达打开新构建。")
            }
        }
    }

    @objc private func showLog() {
        if let logWindow, logWindow.isVisible {
            NSApp.activate()
            logWindow.makeKeyAndOrderFront(nil)
            return
        }
        logWindow = showWindow("StoreSwitch 操作日志", content: OperationLogView(history: logHistory) { [weak self] in
            self?.exportLog()
        })
    }

    private func exportLog() {
        guard let logWindow else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StoreSwitch.log"
        panel.beginSheetModal(for: logWindow) { [weak self] result in
            guard result == .OK, let self, let url = panel.url else { return }
            do {
                try (self.logHistory.lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.showMessage("无法保存日志", "请检查目标位置后再试。")
            }
        }
    }

    private func append(_ messages: [String]) {
        guard !messages.isEmpty else { return }
        let now = clock.string(from: Date())
        logHistory.lines = Array((logHistory.lines + messages.map { "\(now)  \($0)" }).suffix(300))
        preferences.set(logHistory.lines, forKey: "operationLog")
    }

    private func showWindow<V: View>(_ title: String, content: V) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask.insert(.closable)
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func showMessage(_ title: String, _ detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showMenu() {
        guard NSApp.modalWindow == nil, !menuIsOpen, let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
    }

    @objc private func toggleShortcut() {
        preferences.set(!shortcut.isRegistered, forKey: "menuShortcut")
        updateShortcut()
        if preferences.bool(forKey: "menuShortcut"), !shortcut.isRegistered {
            showMessage("快捷键不可用", "⌃⌥S 可能已被其他应用使用。你仍可以点击菜单栏图标。")
        }
    }

    private func updateShortcut() {
        let enabled = preferences.object(forKey: "menuShortcut") as? Bool ?? true
        shortcut.stop()
        if enabled, !shortcut.start({ [weak self] in self?.showMenu() }) {
            append(["全局菜单快捷键注册失败"])
        }
    }

    @objc private func showAbout() {
        guard !coordinator.step.isWorking, NSApp.modalWindow == nil else { return }
        if let aboutWindow, aboutWindow.isVisible {
            NSApp.activate()
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "StoreSwitch"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        aboutWindow = showWindow("关于 \(name)", content: AboutView(name: name, version: version))
    }

    @objc private func quit() {
        guard !coordinator.step.isWorking, !savingPassword else { return }
        NSApp.terminate(nil)
    }

    private func buildApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "关于 StoreSwitch", action: #selector(showAbout), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "管理账号…", action: #selector(showAccounts), keyEquivalent: ",").target = self
        app.addItem(withTitle: "检查 App Store 登录状态", action: #selector(checkLogin), keyEquivalent: "r").target = self
        app.addItem(withTitle: "操作日志…", action: #selector(showLog), keyEquivalent: "l").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "退出 StoreSwitch", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windows = NSMenu(title: "窗口")
        windows.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windows
        main.addItem(windowItem)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }
}

private struct AboutView: View {
    let name: String
    let version: String

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(name).font(.title2.bold())
            Text("版本 \(version)").foregroundStyle(.secondary)
            Text("在 macOS 菜单栏快速切换 App Store 账号。")
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 360)
    }
}

private final class LoginReadout: ObservableObject {
    @Published var message: String?
}

private struct LoginStatusView: View {
    @ObservedObject var readout: LoginReadout
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let message = readout.message {
                    Text(message).textSelection(.enabled)
                } else {
                    ProgressView().controlSize(.small)
                    Text("正在检查 App Store…")
                }
            }
            Button("关闭", action: close)
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
    }
}

private final class LogHistory: ObservableObject {
    @Published var lines: [String] = []
}

private struct OperationLogView: View {
    @ObservedObject var history: LogHistory
    let export: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近 \(history.lines.count) 条 · UTC")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("导出日志…", action: export)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    Text(history.lines.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("log-end")
                }
                .onAppear { scroll.scrollTo("log-end", anchor: .bottom) }
                .onChange(of: history.lines) { _, _ in scroll.scrollTo("log-end", anchor: .bottom) }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 390)
    }
}

private final class AccountDrafts: ObservableObject {
    @Published var entries: [StoreAccount]
    @Published var isSavingPassword = false
    private(set) var saved: [StoreAccount]

    init(_ entries: [StoreAccount]) {
        self.entries = entries
        saved = entries
    }

    func didSave(_ entries: [StoreAccount]) {
        saved = entries
        self.entries = entries
    }

    func updatePassword(_ id: UUID?, for accountID: UUID) {
        if let index = saved.firstIndex(where: { $0.id == accountID }) {
            saved[index].passwordID = id
        }
        if let index = entries.firstIndex(where: { $0.id == accountID }) {
            entries[index].passwordID = id
        }
    }
}

private struct AccountEditor: View {
    @ObservedObject var form: AccountDrafts
    let save: ([StoreAccount]) -> Void
    let close: () -> Void
    let editPassword: (UUID) -> Void
    let removePassword: (UUID) -> Void

    private var normalized: [StoreAccount] {
        form.entries.map { entry in
            var trimmed = entry
            trimmed.email = entry.email.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed
        }
    }

    private var hasInvalidEmail: Bool { normalized.contains { !StoreAccount.validEmail($0.email) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("账号列表").font(.title2.bold())
                Spacer()
                Button {
                    form.entries.append(StoreAccount())
                } label: {
                    Label("添加账号", systemImage: "plus")
                }
            }
            if form.entries.isEmpty {
                ContentUnavailableView("还没有账号", systemImage: "person.crop.circle",
                                       description: Text("点「添加账号」填写 Apple Account 邮箱。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("地区")
                            Text("Apple Account 邮箱")
                            Text("自动登录")
                            Color.clear.frame(width: 28, height: 1)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        ForEach($form.entries) { $entry in
                            GridRow {
                                Picker("地区", selection: $entry.region) {
                                    ForEach(StoreRegion.choices) { region in
                                        Text(region.label).tag(region)
                                    }
                                }
                                .labelsHidden()
                                .accessibilityLabel("账号地区")
                                .frame(width: 148)
                                TextField("Apple Account 邮箱", text: $entry.email,
                                          prompt: Text("name@example.com"))
                                    .labelsHidden()
                                    .accessibilityLabel("Apple Account 邮箱")
                                    .frame(minWidth: 240, maxWidth: .infinity)
                                HStack(spacing: 6) {
                                    Button(entry.passwordID == nil ? "设置密码…" : "更改密码…") {
                                        editPassword(entry.id)
                                    }
                                    .disabled(!canEditPassword(for: entry))
                                    if entry.passwordID != nil {
                                        Button("移除密码") { removePassword(entry.id) }
                                    }
                                }
                                .frame(width: 154, alignment: .leading)
                                Button {
                                    let id = entry.id
                                    form.entries.removeAll { $0.id == id }
                                } label: {
                                    Image(systemName: "trash").frame(width: 22)
                                }
                                .accessibilityLabel("删除账号")
                                .help("保存时删除账号")
                            }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                if form.isSavingPassword {
                    Text("正在保存密码…").foregroundStyle(.secondary)
                } else if hasInvalidEmail {
                    Text("请输入有效的账号邮箱。").foregroundStyle(.red)
                } else {
                    Text("保存邮箱后可设置自动登录。").foregroundStyle(.secondary)
                }
                Spacer()
                if normalized == form.saved {
                    Button("完成", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("取消", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                    Button("保存") { save(normalized) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(hasInvalidEmail)
                }
            }
        }
        .padding(24)
        .frame(width: 750, height: 430)
        .disabled(form.isSavingPassword)
    }

    private func canEditPassword(for entry: StoreAccount) -> Bool {
        let email = entry.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return !email.isEmpty && form.saved.contains { $0.id == entry.id && $0.email == email }
    }
}

@MainActor
private final class MenuShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    var isRegistered: Bool { hotKey != nil }

    func start(_ action: @escaping () -> Void) -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        let signature: OSType = 0x53745377 // StSw
        let installed = InstallEventHandler(target, { _, event, context in
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x53745377, id.id == 1, let context else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<MenuShortcut>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.action?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: signature, id: 1), target, 0, &hotKey)
        guard result == noErr else {
            stop()
            return false
        }
        self.action = action
        return true
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
    }
}

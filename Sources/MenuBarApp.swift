import AppKit
import ApplicationServices
import CoreServices
import Security
import SwiftUI
import Carbon.HIToolbox

@main
@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let preferences = UserDefaults.standard
    private let passwords = PasswordKeychain()
    private let clock = ISO8601DateFormatter()
    private let shortcut = MenuShortcut()
    private var accounts: [StoreAccount] = []
    private let logHistory = LogHistory()
    private let loginReadout = LoginReadout()
    private var permissionWindow: NSWindow?
    private var permissionGuide: PermissionGuide?
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
        logHistory.lines = Array((preferences.stringArray(forKey: "operationLog") ?? []).suffix(300))
        statusItem.button?.image = NSImage(named: "AccountSwitchTemplate")
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        updateInterfaceLanguage()
        updateShortcut()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        append(["StoreSwitch \(version) · \(ProcessInfo.processInfo.operatingSystemVersionString)"])
        // Xcode can launch the executable directly. Refresh the app bundle's registration
        // so macOS can look up its icon by bundle identifier.
        let registration = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        if registration != noErr {
            append([tr(.init("log.registrationFailed", defaultValue: "应用包登记失败 · \(registration)"))])
        }
        if CommandLine.arguments.contains("--manage-accounts") {
            Task { showAccounts() }
        } else if accounts.isEmpty {
            showAccounts()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if permissionWindow != nil {
            showPermissionGuide()
        } else if accounts.isEmpty {
            showAccounts()
        } else {
            showMenu()
        }
        return false
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === permissionWindow else { return }
        permissionGuide?.refresh(trusted: AXIsProcessTrusted())
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === permissionWindow else { return }
        permissionWindow = nil
        permissionGuide = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let step = coordinator.step
        let trusted = AXIsProcessTrusted()
        if !step.canSelect {
            add(tr(step.title)).toolTip = step.guidance.map(tr)
            if let target = coordinator.target {
                let label = "\(target.region.flag) \(shortEmail(target.email))"
                let item = add(tr(.init("menu.target", defaultValue: "目标 · \(label)")))
                item.toolTip = target.email
                item.setAccessibilityLabel(tr(.init("menu.target", defaultValue: "目标 · \(target.email)")))
            }
            menu.addItem(.separator())
        } else if let state = coordinator.storeState {
            add(tr(.init("menu.lastCheck", defaultValue: "上次检查 · \(tr(state.summary))"))).toolTip = tr(state.details)
            menu.addItem(.separator())
        } else if let error = coordinator.checkError {
            add(tr(.init("menu.checkFailed", defaultValue: "上次检查失败"))).toolTip = tr(error)
            menu.addItem(.separator())
        }

        if accounts.isEmpty {
            add(tr(.init("menu.addAccount", defaultValue: "添加账号…")), #selector(showAccounts),
                key: ",", enabled: step.canSelect)
        } else {
            menu.addItem(.sectionHeader(title: tr(.init("menu.switchAccounts", defaultValue: "切换账号"))))
        }
        let titles = accounts.map { accountTitle($0, address: "\($0.region.flag) \(shortEmail($0.email))") }
        let counts = Dictionary(grouping: titles, by: { $0 }).mapValues(\.count)
        for (index, account) in accounts.enumerated() {
            let key = index < 9 ? String(index + 1) : ""
            let title = titles[index]
            // Show the full address if two shortened labels would look identical.
            let item = add(counts[title] == 1 ? title : accountTitle(account, address: account.label),
                           #selector(selectAccount(_:)), key: key, enabled: step.canSelect && !savingPassword)
            item.representedObject = account.id.uuidString
            let region = account.region.title(in: .current)
            let accessibleAddress = tr(.init("menu.accountAddress", defaultValue: "\(region)，\(account.email)"))
            let accessibleTitle = accountTitle(account, address: accessibleAddress)
            item.toolTip = accessibleTitle
            item.setAccessibilityLabel(accessibleTitle)
        }

        if !step.canSelect && !step.isWorking {
            menu.addItem(.separator())
            if case .needsSignOut = step {
                add(tr(.init("menu.continueSignIn", defaultValue: "继续登录")), #selector(continueAfterSignOut))
            }
            if case .needsInitialCheck = step {
                add(tr(.init("menu.checkAgain", defaultValue: "重新检查")), #selector(retryInitialCheck))
            }
            if coordinator.isWaitingForLogin,
               step != .awaitingAuthentication(.submitted), step != .awaitingAuthentication(.submissionUncertain) {
                add(tr(.init("menu.openSignIn", defaultValue: "打开登录窗口")), #selector(retryOpenSignIn))
                add(tr(.init("menu.refillEmail", defaultValue: "重填邮箱")), #selector(retryPrefill))
            }
            if step.guidance != nil {
                add(tr(.init("menu.switchDetails", defaultValue: "查看切换详情")), #selector(showSwitchDetails))
            }
            add(tr(.init("menu.copyEmail", defaultValue: "复制邮箱")), #selector(copyTarget), key: "c")
            add(tr(.init("menu.endSwitch", defaultValue: "结束切换")), #selector(endSwitch))
        }

        menu.addItem(.separator())
        if !trusted || permissionWindow != nil {
            let title: LocalizedStringResource = trusted
                ? .init("menu.accessibilitySetup", defaultValue: "授权引导")
                : .init("menu.grantAccessibility", defaultValue: "开启辅助功能权限…")
            add(tr(title), #selector(showPermissionGuide), enabled: !step.isWorking)
        }
        add(tr(.init("menu.openStore", defaultValue: "打开 App Store")), #selector(openStore), enabled: !step.isWorking)
        add(tr(.init("menu.checkSignIn", defaultValue: "检查登录状态")), #selector(checkLogin), key: "r", enabled: !step.isWorking)
        if !accounts.isEmpty {
            add(tr(.init("menu.manageAccounts", defaultValue: "管理账号…")), #selector(showAccounts), key: ",", enabled: step.canSelect)
        }
        let hotkey = add(tr(.init("menu.shortcut", defaultValue: "菜单快捷键（⌃⌥S）")), #selector(toggleShortcut))
        hotkey.state = shortcut.isRegistered ? .on : .off
#if DEBUG
        add(tr(.init("menu.viewLog", defaultValue: "查看日志")), #selector(showLog), key: "l")
#endif
        menu.addItem(languageMenuItem())
        menu.addItem(.separator())
        add(tr(.init("menu.about", defaultValue: "关于 StoreSwitch")), #selector(showAbout), enabled: !step.isWorking)
        add(tr(.init("menu.quit", defaultValue: "退出 StoreSwitch")), #selector(quit), key: "q", enabled: !step.isWorking && !savingPassword)
    }

    private func accountTitle(_ account: StoreAccount, address: String) -> String {
        guard account.passwordID != nil else { return address }
        return tr(.init("menu.autoSignInAccount", defaultValue: "\(address) · 自动登录"))
    }

    private func shortEmail(_ email: String) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        let maxWidth: CGFloat = 220
        guard email.size(withAttributes: attributes).width > maxWidth else { return email }
        for count in stride(from: email.count - 1, through: 2, by: -1) {
            let candidate = "\(email.prefix((count + 1) / 2))…\(email.suffix(count / 2))"
            if candidate.size(withAttributes: attributes).width <= maxWidth { return candidate }
        }
        return email
    }

    private func languageMenuItem() -> NSMenuItem {
        let title = tr(.init("menu.language", defaultValue: "语言"))
        let languages = NSMenu(title: title)
        let current = AppLanguage.current
        for language in AppLanguage.allCases {
            let item = languages.addItem(withTitle: language.name, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == current ? .on : .off
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = languages
        item.isEnabled = NSApp.modalWindow == nil
        return item
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard NSApp.modalWindow == nil, let code = sender.representedObject as? String,
              let language = AppLanguage(rawValue: code), language != AppLanguage.current else { return }
        preferences.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        updateInterfaceLanguage()
    }

    private func updateInterfaceLanguage() {
        let label = tr(.init("app.statusItem", defaultValue: "App Store 账号切换"))
        statusItem.button?.setAccessibilityLabel(label)
        statusItem.button?.toolTip = label
        accountWindow?.title = tr(.init("window.manageAccounts", defaultValue: "管理 App Store 账号"))
        checkWindow?.title = tr(.init("window.loginStatus", defaultValue: "App Store 登录状态"))
        logWindow?.title = tr(.init("window.log", defaultValue: "StoreSwitch 操作日志"))
        aboutWindow?.title = tr(.init("menu.about", defaultValue: "关于 StoreSwitch"))
        buildApplicationMenu()
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
        guard let id = sender.representedObject as? String,
              let account = accounts.first(where: { $0.id.uuidString == id }) else { return }
        startSwitch(to: account)
    }

    private func startSwitch(to account: StoreAccount) {
        guard NSApp.modalWindow == nil, coordinator.step.canSelect, !savingPassword else { return }
        guard AXIsProcessTrusted() else {
            presentPermissionGuide(for: .switchAccount(account))
            return
        }
        permissionWindow?.close()
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
        alert.messageText = tr(.init("switch.confirm.title", defaultValue: "切换 App Store 账号？"))
        let detail: LocalizedStringResource = account.passwordID == nil
            ? .init("switch.confirm.manual", defaultValue: "目标：\(account.email)\n\nStoreSwitch 将退出当前 App Store 账号，然后尝试预填目标邮箱。请在 App Store 完成 Apple 要求的验证。")
            : .init("switch.confirm.automatic", defaultValue: "目标：\(account.email)\n\nStoreSwitch 将退出当前 App Store 账号，然后尝试使用钥匙串中的密码在 App Store 提交登录。请在 App Store 完成 Apple 要求的验证。")
        alert.informativeText = tr(detail)
        alert.addButton(withTitle: tr(.init("common.cancel", defaultValue: "取消"))).keyEquivalent = "\r"
        alert.addButton(withTitle: tr(.init("switch.confirm.continue", defaultValue: "退出并继续"))).keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func continueAfterSignOut() { Task { await coordinator.continueAfterSignOut() } }
    @objc private func retryInitialCheck() {
        Task { await coordinator.retryInitialCheck { [weak self] in self?.confirmExit($0) == true } }
    }
    @objc private func retryOpenSignIn() { Task { await coordinator.retryLogin(openIfNeeded: true) } }
    @objc private func retryPrefill() { Task { await coordinator.retryLogin(openIfNeeded: false) } }
    @objc private func checkLogin() {
        guard NSApp.modalWindow == nil else { return }
        if checkingFromMenu {
            checkWindow?.makeKeyAndOrderFront(nil)
            return
        }
        // A manual check shouldn't take focus away from a running sign-in or sign-out.
        if coordinator.step.isWorking {
            Task { await coordinator.checkLogin() }
            return
        }
        guard AXIsProcessTrusted() else {
            presentPermissionGuide(for: .checkLogin)
            return
        }
        permissionWindow?.close()
        checkingFromMenu = true
        loginReadout.message = nil
        if let checkWindow, checkWindow.isVisible {
            NSApp.activate()
            checkWindow.makeKeyAndOrderFront(nil)
        } else {
            checkWindow = showWindow(tr(.init("window.loginStatus", defaultValue: "App Store 登录状态")), content: LoginStatusView(readout: loginReadout) { [weak self] in
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

    @objc private func showSwitchDetails() {
        let step = coordinator.step
        guard NSApp.modalWindow == nil, let guidance = step.guidance else { return }
        showMessage(tr(step.title), tr(guidance))
    }

    @objc private func copyTarget() {
        guard let target = coordinator.target else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target.email, forType: .string)
    }

    @objc private func openStore() {
        Task {
            do { _ = try await automation.openStore() }
            catch { showMessage(tr(.init("store.openFailed", defaultValue: "无法打开 App Store")), (error as? StoreAutomationError).map { tr($0.message) } ?? "") }
        }
    }

    @objc private func showPermissionGuide() { presentPermissionGuide(for: .standalone) }

    private func presentPermissionGuide(for request: PermissionGuide.Request) {
        guard NSApp.modalWindow == nil else { return }
        let trusted = AXIsProcessTrusted()
        if let window = permissionWindow, let guide = permissionGuide {
            // The menu also serves as a way back to an authorization already in progress.
            switch request {
            case .standalone: break
            case .switchAccount, .checkLogin: guide.request = request
            }
            guide.refresh(trusted: trusted)
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let guide = PermissionGuide(request: request, trusted: trusted)
        permissionGuide = guide
        let window = showWindow("StoreSwitch", content: PermissionGuideView(
            guide: guide,
            openSettings: { [weak self] in self?.openPermissionSettings() },
            cancel: { [weak self] in self?.permissionWindow?.close() },
            finish: { [weak self] in self?.finishPermissionGuide() }
        ))
        permissionWindow = window
        window.delegate = self
    }

    private func openPermissionSettings() {
        guard let guide = permissionGuide else { return }
        guide.refresh(trusted: AXIsProcessTrusted())
        guard guide.page != .granted else { return }
        let firstRequest = guide.page == .introduction
        guide.waitForPermission()
        if firstRequest {
            // Ask macOS to list this app on the first Settings launch.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
           NSWorkspace.shared.open(url) {
            append([tr(.init("log.openedAccessibilitySettings", defaultValue: "用户打开辅助功能设置"))])
        } else {
            guide.settingsDidNotOpen()
        }
    }

    private func finishPermissionGuide() {
        guard NSApp.modalWindow == nil, let guide = permissionGuide, guide.page == .granted else { return }
        guide.refresh(trusted: AXIsProcessTrusted())
        guard guide.page == .granted else { return }
        let request = guide.request
        permissionWindow?.close()
        switch request {
        case .standalone:
            break
        case .switchAccount(let selected):
            // Account management stays available while the user is in System Settings.
            guard accounts.contains(selected) else {
                showMessage(tr(.init("switch.accountChanged", defaultValue: "账号配置已更改")), tr(.init("switch.selectAgain", defaultValue: "请在菜单中重新选择要切换的账号。")))
                return
            }
            startSwitch(to: selected)
        case .checkLogin:
            checkLogin()
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
        accountWindow = showWindow(tr(.init("window.manageAccounts", defaultValue: "管理 App Store 账号")), content: editor)
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
            showKeychainFailure(tr(.init("keychain.saveFailed", defaultValue: "无法保存密码")), error)
            return
        }
        let alert = NSAlert()
        alert.messageText = tr(.init("keychain.setup", defaultValue: "设置自动登录密码"))
        alert.informativeText = tr(.init("keychain.setupDetails", defaultValue: "账号：\(account.email)\n密码仅存于本机钥匙串。以后从菜单选择此账号时，StoreSwitch 会尝试在系统 App Store 中提交登录。"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = tr(.init("keychain.password", defaultValue: "Apple Account 密码"))
        field.setAccessibilityLabel(tr(.init("keychain.password", defaultValue: "Apple Account 密码")))
        alert.accessoryView = field
        alert.addButton(withTitle: tr(.init("keychain.enable", defaultValue: "存入钥匙串并启用")))
        alert.addButton(withTitle: tr(.init("common.cancel", defaultValue: "取消")))
        alert.window.initialFirstResponder = field
        defer { field.stringValue = "" }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = field.stringValue
        guard !password.isEmpty else {
            showMessage(tr(.init("keychain.enterPassword", defaultValue: "请输入密码")), tr(.init("keychain.emptyPassword", defaultValue: "密码留空时不会保存。")))
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
                showKeychainFailure(tr(.init("keychain.saveFailed", defaultValue: "无法保存密码")), error)
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
            showKeychainFailure(tr(.init("keychain.removeFailed", defaultValue: "无法移除账号密码")), error)
            return false
        }
    }

    private func showKeychainFailure(_ title: String, _ error: Error) {
        let failure = error as? KeychainFailure
        append([failure?.logMessage ?? tr(.init("log.keychainFailed", defaultValue: "钥匙串 · 密码操作失败"))])
        guard failure?.status == errSecCSStaticCodeChanged else {
            showMessage(title, failure?.userMessage ?? tr(.init("common.tryAgain", defaultValue: "请稍后重试。")))
            return
        }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = tr(.init("keychain.reopen", defaultValue: "需要重新打开 StoreSwitch"))
        alert.informativeText = tr(.init("keychain.reopenDetails", defaultValue: "磁盘上的 StoreSwitch 已更新。请重新打开应用，再访问钥匙串。账号列表中未保存的修改需要重新填写。"))
        alert.addButton(withTitle: tr(.init("common.reopen", defaultValue: "重新打开")))
        alert.addButton(withTitle: tr(.init("common.later", defaultValue: "稍后")))
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
                showMessage(tr(.init("keychain.reopenFailed", defaultValue: "无法重新打开 StoreSwitch")), tr(.init("keychain.reopenFailedDetails", defaultValue: "请在构建完成后退出 StoreSwitch，再从访达打开新构建。")))
            }
        }
    }

    @objc private func showLog() {
        if let logWindow, logWindow.isVisible {
            NSApp.activate()
            logWindow.makeKeyAndOrderFront(nil)
            return
        }
        logWindow = showWindow(tr(.init("window.log", defaultValue: "StoreSwitch 操作日志")), content: OperationLogView(history: logHistory) { [weak self] in
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
                self.showMessage(tr(.init("log.exportFailed", defaultValue: "无法保存日志")), tr(.init("log.exportFailedDetails", defaultValue: "请检查目标位置后再试。")))
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
        alert.addButton(withTitle: tr(.init("common.ok", defaultValue: "好")))
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
            showMessage(tr(.init("shortcut.unavailable", defaultValue: "快捷键不可用")), tr(.init("shortcut.conflict", defaultValue: "⌃⌥S 可能已被其他应用使用。你仍可以点击菜单栏图标。")))
        }
    }

    private func updateShortcut() {
        let enabled = preferences.object(forKey: "menuShortcut") as? Bool ?? true
        shortcut.stop()
        if enabled, !shortcut.start({ [weak self] in self?.showMenu() }) {
            append([tr(.init("log.shortcutFailed", defaultValue: "全局菜单快捷键注册失败"))])
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? tr(.init("common.unknown", defaultValue: "未知"))
        aboutWindow = showWindow(tr(.init("menu.about", defaultValue: "关于 StoreSwitch")), content: AboutView(name: name, version: version) { [weak self] in
            self?.showLog()
        })
    }

    @objc private func quit() {
        guard !coordinator.step.isWorking, !savingPassword else { return }
        NSApp.terminate(nil)
    }

    private func buildApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: tr(.init("menu.about", defaultValue: "关于 StoreSwitch")), action: #selector(showAbout), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: tr(.init("menu.manageAccounts", defaultValue: "管理账号…")), action: #selector(showAccounts), keyEquivalent: ",").target = self
        app.addItem(withTitle: tr(.init("menu.checkSignIn", defaultValue: "检查登录状态")), action: #selector(checkLogin), keyEquivalent: "r").target = self
#if DEBUG
        app.addItem(withTitle: tr(.init("menu.viewLog", defaultValue: "查看日志")), action: #selector(showLog), keyEquivalent: "l").target = self
#endif
        app.addItem(languageMenuItem())
        app.addItem(.separator())
        app.addItem(withTitle: tr(.init("menu.quit", defaultValue: "退出 StoreSwitch")), action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr(.init("native.edit", defaultValue: "编辑")))
        edit.addItem(withTitle: tr(.init("native.undo", defaultValue: "撤销")), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: tr(.init("native.cut", defaultValue: "剪切")), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr(.init("native.copy", defaultValue: "复制")), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr(.init("native.paste", defaultValue: "粘贴")), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr(.init("native.selectAll", defaultValue: "全选")), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windows = NSMenu(title: tr(.init("native.window", defaultValue: "窗口")))
        windows.addItem(withTitle: tr(.init("native.closeWindow", defaultValue: "关闭窗口")), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windows
        main.addItem(windowItem)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }
}

private struct AboutView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .preferred
    let name: String
    let version: String
    let showLog: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(name).font(.title2.bold())
            Text(language.text(.init("about.version", defaultValue: "版本 \(version)"))).foregroundStyle(.secondary)
            Text(language.text(.init("about.description", defaultValue: "在 macOS 菜单栏快速切换 App Store 账号。")))
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Button(language.text(.init("about.diagnosticLog", defaultValue: "诊断日志")), action: showLog)
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 360)
    }
}

private final class LoginReadout: ObservableObject {
    @Published var message: LocalizedStringResource?
}

private struct LoginStatusView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .preferred
    @ObservedObject var readout: LoginReadout
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let message = readout.message {
                    Text(language.text(message)).textSelection(.enabled)
                } else {
                    ProgressView().controlSize(.small)
                    Text(language.text(.init("login.checkingStore", defaultValue: "正在检查 App Store…")))
                }
            }
            Button(language.text(.init("common.close", defaultValue: "关闭")), action: close)
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
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .preferred
    @ObservedObject var history: LogHistory
    let export: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(language.text(.init("log.count", defaultValue: "最近 \(history.lines.count) 条 · UTC")))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(language.text(.init("log.export", defaultValue: "导出日志…")), action: export)
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
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .preferred
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
                Text(language.text(.init("accounts.list", defaultValue: "账号列表"))).font(.title2.bold())
                Spacer()
                Button {
                    form.entries.append(StoreAccount())
                } label: {
                    Label(language.text(.init("accounts.add", defaultValue: "添加账号")), systemImage: "plus")
                }
            }
            if form.entries.isEmpty {
                ContentUnavailableView(language.text(.init("accounts.empty", defaultValue: "还没有账号")), systemImage: "person.crop.circle",
                                       description: Text(language.text(.init("accounts.emptyDetails", defaultValue: "点「添加账号」填写 Apple Account 邮箱。"))))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text(language.text(.init("accounts.region", defaultValue: "地区")))
                            Text(language.text(.init("accounts.email", defaultValue: "Apple Account 邮箱")))
                            Text(language.text(.init("accounts.autoSignIn", defaultValue: "自动登录")))
                            Color.clear.frame(width: 28, height: 1)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        ForEach($form.entries) { $entry in
                            GridRow {
                                Picker(language.text(.init("accounts.region", defaultValue: "地区")), selection: $entry.region) {
                                    ForEach(StoreRegion.choices(in: language)) { region in
                                        Text(region.label(in: language)).tag(region)
                                    }
                                }
                                .labelsHidden()
                                .accessibilityLabel(language.text(.init("accounts.accountRegion", defaultValue: "账号地区")))
                                .frame(width: 148)
                                TextField(language.text(.init("accounts.email", defaultValue: "Apple Account 邮箱")), text: $entry.email,
                                          prompt: Text(verbatim: "name@example.com"))
                                    .labelsHidden()
                                    .accessibilityLabel(language.text(.init("accounts.email", defaultValue: "Apple Account 邮箱")))
                                    .frame(minWidth: 240, maxWidth: .infinity)
                                HStack(spacing: 6) {
                                    Button(entry.passwordID == nil ? language.text(.init("accounts.setPassword", defaultValue: "设置密码…")) : language.text(.init("accounts.changePassword", defaultValue: "更改密码…"))) {
                                        editPassword(entry.id)
                                    }
                                    .disabled(!canEditPassword(for: entry))
                                    if entry.passwordID != nil {
                                        Button(language.text(.init("accounts.removePassword", defaultValue: "移除密码"))) { removePassword(entry.id) }
                                    }
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                Button {
                                    let id = entry.id
                                    form.entries.removeAll { $0.id == id }
                                } label: {
                                    Image(systemName: "trash").frame(width: 22)
                                }
                                .accessibilityLabel(language.text(.init("accounts.delete", defaultValue: "删除账号")))
                                .help(language.text(.init("accounts.deleteHint", defaultValue: "保存时删除账号")))
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
                    Text(language.text(.init("accounts.savingPassword", defaultValue: "正在保存密码…"))).foregroundStyle(.secondary)
                } else if hasInvalidEmail {
                    Text(language.text(.init("accounts.invalidEmail", defaultValue: "请输入有效的账号邮箱。"))).foregroundStyle(.red)
                } else {
                    Text(language.text(.init("accounts.autoSignInHint", defaultValue: "保存邮箱后可设置自动登录。"))).foregroundStyle(.secondary)
                }
                Spacer()
                if normalized == form.saved {
                    Button(language.text(.init("common.done", defaultValue: "完成")), action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button(language.text(.init("common.cancel", defaultValue: "取消")), role: .cancel, action: close).keyboardShortcut(.cancelAction)
                    Button(language.text(.init("common.save", defaultValue: "保存"))) { save(normalized) }
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

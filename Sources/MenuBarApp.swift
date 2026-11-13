import AppKit
import ApplicationServices
import CoreServices
import Security
import Sparkle
import SwiftUI
import Carbon.HIToolbox

@main
@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSWindowDelegate {
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
    private var accountDrafts: AccountDrafts?
    private var savingPassword = false
    private var manualLoginWindow: NSWindow?
    private var logWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var updaterController: SPUStandardUpdaterController?
    private var menuIsOpen = false
    private lazy var automation = AppStoreAutomation { [weak self] in self?.append($0) }
    private lazy var coordinator = AccountSwitchCoordinator(
        service: automation,
        confirmManualFallback: { [weak self] in self?.confirmManualFallback($0) == true },
        updateManualLoginRecovery: { [weak self] account in
            if let account {
                self?.showManualLoginRecovery(for: account, activate: false)
            } else {
                self?.manualLoginWindow?.close()
            }
        }
    ) { [weak self] in self?.append([$0]) }

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard NSApp.modalWindow == nil, !coordinator.step.isWorking, !savingPassword else { return .terminateCancel }
        guard let form = accountDrafts, form.hasChanges else { return .terminateNow }
        switch confirmDiscardOrSave(form) {
        case .alertFirstButtonReturn:
            saveAccounts(form) { sender.reply(toApplicationShouldTerminate: $0) }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

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
        guard let window = notification.object as? NSWindow else { return }
        if window === permissionWindow {
            permissionWindow = nil
            permissionGuide = nil
        } else if window === accountWindow {
            accountDrafts?.discardPasswordEdits()
            accountWindow = nil
            accountDrafts = nil
        } else if window === manualLoginWindow {
            manualLoginWindow = nil
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === accountWindow else { return true }
        guard NSApp.modalWindow == nil, !savingPassword else { return false }
        guard accountDrafts?.hasChanges == true else { return true }
        closeAccountEditor { }
        return false
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
                           #selector(selectAccount(_:)), key: key, enabled: canStartSwitch)
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
                if step != .needsManualLogin {
                    add(tr(.init("menu.refillEmail", defaultValue: "重填邮箱")), #selector(retryPrefill))
                }
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
        add(tr(.init("menu.checkUpdates", defaultValue: "检查更新…")), #selector(checkForUpdates), enabled: canCheckForUpdates)
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
        manualLoginWindow?.title = tr(.init("switch.manual.title", defaultValue: "需要手动登录"))
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
        guard NSApp.modalWindow == nil, canStartSwitch else { return }
        guard AXIsProcessTrusted() else {
            presentPermissionGuide(for: .switchAccount(account))
            return
        }
        closeAccountEditor { [weak self] in
            guard let self else { return }
            guard let current = self.accounts.first(where: { $0.id == account.id }), current.email == account.email else {
                self.showMessage(tr(.init("switch.accountChanged", defaultValue: "账号配置已更改")), tr(.init("switch.selectAgain", defaultValue: "请在菜单中重新选择要切换的账号。")))
                return
            }
            self.permissionWindow?.close()
            Task {
                guard self.canStartSwitch else { return }
                await self.coordinator.start(current) { [weak self] in self?.confirmExit($0) == true }
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

    private func confirmManualFallback(_ account: StoreAccount) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = tr(.init("switch.manual.title", defaultValue: "需要手动登录"))
        alert.informativeText = tr(.init("switch.manual.beforeSignOut", defaultValue: "无法读取已保存的密码，当前账号仍保持登录。继续将退出当前账号，你需要在 App Store 手动登录 \(account.email)。"))
        alert.addButton(withTitle: tr(.init("switch.manual.cancel", defaultValue: "取消切换"))).keyEquivalent = "\r"
        alert.addButton(withTitle: tr(.init("switch.manual.continue", defaultValue: "继续手动登录"))).keyEquivalent = ""
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
        if step == .needsManualLogin, let target = coordinator.target {
            showManualLoginRecovery(for: target)
            return
        }
        showMessage(tr(step.title), tr(guidance))
    }

    private func showManualLoginRecovery(for account: StoreAccount, activate: Bool = true) {
        if let manualLoginWindow {
            if activate { NSApp.activate() }
            manualLoginWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = ManualLoginRecoveryView(target: account, close: { [weak self] in
            self?.manualLoginWindow?.close()
        }, openSignIn: { [weak self] in
            self?.retryOpenSignIn()
        })
        let window = showWindow(tr(.init("switch.manual.title", defaultValue: "需要手动登录")), activate: activate, content: view)
        manualLoginWindow = window
        window.delegate = self
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
        if case .switchAccount = request, !canStartSwitch { return }
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
        guard NSApp.modalWindow == nil, coordinator.step.canSelect else { return }
        if let accountWindow {
            NSApp.activate()
            accountWindow.makeKeyAndOrderFront(nil)
            return
        }
        let form = AccountDrafts(accounts)
        accountDrafts = form
        let editor = AccountEditor(form: form, save: { [weak self, weak form] in
            if let form { self?.saveAccounts(form) }
        }, close: { [weak self] in
            self?.accountWindow?.close()
        }, editPassword: { [weak self, weak form] id in
            if let form { self?.editPassword(id, form: form) }
        })
        let window = showWindow(tr(.init("window.manageAccounts", defaultValue: "管理 App Store 账号")), content: editor)
        accountWindow = window
        window.delegate = self
    }

    private func closeAccountEditor(then action: @escaping () -> Void) {
        guard !savingPassword else { return }
        let close = { [weak self] in
            self?.accountWindow?.close()
            action()
        }
        guard let form = accountDrafts, form.hasChanges else {
            close()
            return
        }
        switch confirmDiscardOrSave(form) {
        case .alertFirstButtonReturn:
            saveAccounts(form) { if $0 { close() } }
        case .alertSecondButtonReturn:
            close()
        default:
            break
        }
    }

    private func confirmDiscardOrSave(_ form: AccountDrafts) -> NSApplication.ModalResponse {
        NSApp.activate()
        accountWindow?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = tr(.init("accounts.unsaved.title", defaultValue: "要保存账号修改吗？"))
        let emailIssue = form.emailValidationMessage
        alert.informativeText = emailIssue.map(tr)
            ?? tr(.init("accounts.unsaved.details", defaultValue: "尚未保存的账号和密码修改将在关闭窗口时丢失。"))
        let save = alert.addButton(withTitle: tr(.init("common.save", defaultValue: "保存")))
        save.isEnabled = emailIssue == nil
        save.keyEquivalent = ""
        alert.addButton(withTitle: tr(.init("accounts.unsaved.discard", defaultValue: "放弃修改"))).keyEquivalent = ""
        alert.addButton(withTitle: tr(.init("accounts.unsaved.keepEditing", defaultValue: "继续编辑"))).keyEquivalent = "\r"
        return alert.runModal()
    }

    private func saveAccounts(_ form: AccountDrafts, completion: @escaping (Bool) -> Void = { _ in }) {
        guard coordinator.step.canSelect, !savingPassword, form.emailValidationMessage == nil else {
            Task { completion(false) }
            return
        }
        let plan = form.savePlan()
        savingPassword = true
        form.isSavingPassword = true
        Task {
            let succeeded: Bool
            do {
                if !plan.affected.isEmpty {
                    try await Task.detached(priority: .userInitiated) {
                        try PasswordKeychain().updateVault(setting: plan.setting, removing: plan.removing)
                    }.value
                }
                persistAccounts(plan.accounts)
                form.didSave(plan.accounts)
                // Account references now point to the committed vault, even if
                // macOS doesn't allow us to remove an old copy.
                if !plan.affected.isEmpty { await cleanLegacyPasswords(affected: plan.affected) }
                succeeded = true
            } catch {
                let failure = error as? KeychainFailure
                logKeychainFailure(error)
                let reason = failure?.status == errSecCSStaticCodeChanged
                    ? tr(.init("accounts.save.reopen", defaultValue: "磁盘上的 StoreSwitch 已更新。请重新打开应用后重试。"))
                    : failure?.userMessage ?? tr(.init("common.tryAgain", defaultValue: "请稍后重试。"))
                let labels = plan.affected.values.map(\.label).sorted().joined(separator: "\n")
                showMessage(tr(.init("accounts.save.failed", defaultValue: "无法保存账号修改")),
                            tr(.init("accounts.save.failedDetails", defaultValue: "没有应用本次修改，草稿仍在。以下账号的密码需要更新：\n\(labels)\n\n\(reason)")))
                succeeded = false
            }
            savingPassword = false
            form.isSavingPassword = false
            completion(succeeded)
        }
    }

    private func cleanLegacyPasswords(affected: [UUID: StoreAccount]) async {
        var pending = Set(affected.keys)
        while !pending.isEmpty {
            let ids = pending
            let failures = await Task.detached(priority: .userInitiated) {
                PasswordKeychain().removeLegacyCopies(ids)
            }.value
            guard !failures.isEmpty else { return }
            for error in failures.values { logKeychainFailure(error) }
            let labels = failures.keys.compactMap { affected[$0]?.label }.sorted().joined(separator: "\n")
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = tr(.init("accounts.save.cleanupTitle", defaultValue: "部分旧密码未清理"))
            alert.informativeText = tr(.init("accounts.save.cleanupDetails", defaultValue: "账号修改已保存。以下账号的旧密码副本未能从本机钥匙串移除，StoreSwitch 不会再使用这些副本：\n\(labels)"))
            alert.addButton(withTitle: tr(.init("common.done", defaultValue: "完成")))
            alert.addButton(withTitle: tr(.init("accounts.save.retryCleanup", defaultValue: "重试清理")))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            pending = Set(failures.keys)
        }
    }

    private func logKeychainFailure(_ error: Error) {
        append([(error as? KeychainFailure)?.logMessage ?? tr(.init("log.keychainFailed", defaultValue: "钥匙串 · 密码操作失败"))])
    }

    private func persistAccounts(_ updates: [StoreAccount]) {
        guard let data = try? JSONEncoder().encode(updates) else { return }
        preferences.set(data, forKey: "accounts")
        accounts = updates
    }

    private func editPassword(_ accountID: UUID, form: AccountDrafts) {
        guard NSApp.modalWindow == nil, coordinator.step.canSelect, !savingPassword,
              let account = form.saved.first(where: { $0.id == accountID }) else { return }
        let alert = NSAlert()
        alert.messageText = tr(.init("keychain.setup", defaultValue: "设置自动登录密码"))
        alert.informativeText = tr(.init("accounts.password.draftDetails", defaultValue: "账号：\(account.email)\n点击账号列表的「保存」后，密码才会存入本机钥匙串，并启用自动登录。"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = tr(.init("keychain.password", defaultValue: "Apple Account 密码"))
        field.setAccessibilityLabel(tr(.init("keychain.password", defaultValue: "Apple Account 密码")))
        alert.accessoryView = field
        alert.addButton(withTitle: tr(.init("common.confirm", defaultValue: "确定")))
        alert.addButton(withTitle: tr(.init("common.cancel", defaultValue: "取消")))
        alert.window.initialFirstResponder = field
        defer { field.stringValue = "" }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = field.stringValue
        guard !password.isEmpty else {
            showMessage(tr(.init("keychain.enterPassword", defaultValue: "请输入密码")), tr(.init("keychain.emptyPassword", defaultValue: "密码留空时不会保存。")))
            return
        }
        form.setPassword(password, for: accountID)
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

    private func showWindow<V: View>(_ title: String, activate: Bool = true, content: V) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask.insert(.closable)
        window.isReleasedWhenClosed = false
        window.center()
        if activate || NSApp.isActive {
            if activate { NSApp.activate() }
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
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

    // Updating can quit and relaunch StoreSwitch. Keep a switch from starting
    // while Sparkle is presenting or installing an update.
    private var canStartSwitch: Bool {
        coordinator.step.canSelect && !savingPassword && updaterController?.updater.sessionInProgress != true
    }

    private var canCheckForUpdates: Bool {
        NSApp.modalWindow == nil && coordinator.step.canSelect && !savingPassword
            && updaterController?.updater.canCheckForUpdates != false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates) || canCheckForUpdates
    }

    @objc private func checkForUpdates() {
        guard canCheckForUpdates else { return }
        if let updaterController {
            updaterController.checkForUpdates(nil)
            return
        }

        // Local builds can omit the release feed and public key. Start Sparkle
        // only on demand so those builds still launch normally and never poll.
        let bundle = Bundle.main
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URLComponents(string: feed), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            showMessage(tr(.init("update.title", defaultValue: "软件更新")),
                        tr(.init("update.unconfigured", defaultValue: "当前构建尚未配置更新地址或签名公钥。")))
            return
        }

        // Retain one controller so repeated menu clicks reopen Sparkle's
        // existing update UI. Sparkle handles checking, verification and install.
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do {
            try controller.updater.start()
        } catch {
            let failure = error as NSError
            append([tr(.init("log.updaterStartFailed", defaultValue: "Sparkle 启动失败 · \(failure.domain) (\(failure.code))"))])
            showMessage(tr(.init("update.title", defaultValue: "软件更新")),
                        tr(.init("update.failed", defaultValue: "暂时无法检查更新，请稍后重试。")))
            return
        }
        updaterController = controller
        NSApp.activate()
        controller.checkForUpdates(nil)
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
        app.addItem(withTitle: tr(.init("menu.checkUpdates", defaultValue: "检查更新…")), action: #selector(checkForUpdates), keyEquivalent: "").target = self
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

private struct ManualLoginRecoveryView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .preferred
    let target: StoreAccount
    let close: () -> Void
    let openSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(language.text(.init("switch.manual.title", defaultValue: "需要手动登录")), systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.title2.bold())
            Text(language.text(.init("switch.manual.signedOut", defaultValue: "App Store 当前未登录，且无法读取已保存的密码。请在 App Store 手动登录目标账号。")))
            Text(language.text(.init("switch.notice.target", defaultValue: "目标账号：\(target.email)")))
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
            HStack {
                Button(language.text(.init("common.done", defaultValue: "完成")), action: close)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(language.text(.init("menu.copyEmail", defaultValue: "复制邮箱"))) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target.email, forType: .string)
                }
                Button(language.text(.init("menu.openSignIn", defaultValue: "打开登录窗口")), action: openSignIn)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private final class AccountDrafts: ObservableObject {
    private enum PasswordEdit {
        case set(String), remove
    }

    struct SavePlan {
        let accounts: [StoreAccount]
        let setting: [UUID: String]
        let removing: Set<UUID>
        let affected: [UUID: StoreAccount]
    }

    @Published var entries: [StoreAccount]
    @Published var isSavingPassword = false
    @Published private var passwordEdits: [UUID: PasswordEdit] = [:]
    private(set) var saved: [StoreAccount]
    private let starterAccount: StoreAccount?

    init(_ entries: [StoreAccount]) {
        let starter = entries.isEmpty ? StoreAccount() : nil
        starterAccount = starter
        self.entries = starter.map { [$0] } ?? entries
        saved = entries
    }

    var initialEmailFocus: UUID? { starterAccount?.id }

    func addAccount() -> UUID {
        if let starterAccount, entries.first?.id == starterAccount.id, normalized.isEmpty {
            return starterAccount.id
        }
        let account = StoreAccount()
        entries.append(account)
        return account.id
    }

    func didSave(_ entries: [StoreAccount]) {
        saved = entries
        self.entries = entries
        discardPasswordEdits()
    }

    func discardPasswordEdits() { passwordEdits.removeAll() }

    private var normalized: [StoreAccount] {
        let trimmed = entries.map { entry in
            var normalized = entry
            normalized.email = entry.email.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized
        }
        // An untouched first row is ready for typing without counting as an edit.
        if let starterAccount, trimmed == [starterAccount] { return [] }
        return trimmed
    }

    var hasChanges: Bool { normalized != saved || !passwordEdits.isEmpty }

    var emailValidationMessage: LocalizedStringResource? {
        let emails = normalized.map(\.email)
        let validEmails = emails.filter(StoreAccount.validEmail)
        if Set(validEmails.map { $0.lowercased() }).count != validEmails.count {
            return .init("accounts.duplicateEmail", defaultValue: "该 Apple Account 邮箱已存在。")
        }
        if validEmails.count != emails.count {
            return .init("accounts.invalidEmail", defaultValue: "请输入有效的账号邮箱。")
        }
        return nil
    }

    private func matchingSavedAccount(for entry: StoreAccount) -> StoreAccount? {
        let email = entry.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.first { $0.id == entry.id && $0.email == email }
    }

    func canEditPassword(for entry: StoreAccount) -> Bool { matchingSavedAccount(for: entry) != nil }

    func passwordEnabled(for entry: StoreAccount) -> Bool {
        guard let original = matchingSavedAccount(for: entry) else { return false }
        switch passwordEdits[entry.id] {
        case .set: return true
        case .remove: return false
        case nil: return original.passwordID != nil
        }
    }

    func setPassword(_ password: String, for id: UUID) {
        passwordEdits[id] = .set(password)
    }

    func removePassword(for id: UUID) {
        passwordEdits[id] = saved.first(where: { $0.id == id })?.passwordID == nil ? nil : .remove
    }

    func delete(_ id: UUID) {
        passwordEdits[id] = nil
        entries.removeAll { $0.id == id }
    }

    func savePlan() -> SavePlan {
        var setting: [UUID: String] = [:]
        var affected: [UUID: StoreAccount] = [:]
        let updates = normalized.map { entry in
            var update = entry
            let original = matchingSavedAccount(for: entry)
            // An address change must never carry over a password for the old address.
            update.passwordID = original?.passwordID
            if let original {
                switch passwordEdits[entry.id] {
                case .set(let password):
                    let id = original.passwordID ?? UUID()
                    update.passwordID = id
                    setting[id] = password
                    affected[id] = update
                case .remove:
                    update.passwordID = nil
                case nil:
                    break
                }
            }
            return update
        }
        let retained = Set(updates.compactMap(\.passwordID))
        var removing = Set<UUID>()
        for original in saved {
            guard let id = original.passwordID, !retained.contains(id) else { continue }
            removing.insert(id)
            affected[id] = original
        }
        return SavePlan(accounts: updates, setting: setting, removing: removing, affected: affected)
    }
}

private struct AccountEditor: View {
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .preferred
    @FocusState private var focusedEmail: UUID?
    @ObservedObject var form: AccountDrafts
    let save: () -> Void
    let close: () -> Void
    let editPassword: (UUID) -> Void

    var body: some View {
        let emailIssue = form.emailValidationMessage
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(language.text(.init("accounts.list", defaultValue: "账号列表"))).font(.title2.bold())
                Spacer()
                Button {
                    focusedEmail = form.addAccount()
                } label: {
                    Label(language.text(.init("accounts.add", defaultValue: "添加账号")), systemImage: "plus")
                }
            }
            if form.entries.isEmpty {
                ContentUnavailableView(language.text(.init("accounts.empty", defaultValue: "还没有账号")), systemImage: "person.crop.circle",
                                       description: Text(language.text(.init("accounts.emptyDetails", defaultValue: "点「添加账号」填写 Apple Account 邮箱。"))))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    accountRows.onChange(of: focusedEmail) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack {
                if form.isSavingPassword {
                    Text(language.text(.init("accounts.save.inProgress", defaultValue: "正在保存账号修改…"))).foregroundStyle(.secondary)
                } else if let emailIssue {
                    Text(language.text(emailIssue)).foregroundStyle(.red)
                } else if form.hasChanges {
                    Text(language.text(.init("accounts.save.hint", defaultValue: "账号和密码修改在保存后生效。"))).foregroundStyle(.secondary)
                } else {
                    Text(language.text(.init("accounts.autoSignInHint", defaultValue: "保存邮箱后可设置自动登录。"))).foregroundStyle(.secondary)
                }
                Spacer()
                if !form.hasChanges {
                    Button(language.text(.init("common.done", defaultValue: "完成")), action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button(language.text(.init("common.cancel", defaultValue: "取消")), role: .cancel, action: close).keyboardShortcut(.cancelAction)
                    Button(language.text(.init("common.save", defaultValue: "保存")), action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(emailIssue != nil)
                }
            }
        }
        .padding(24)
        .frame(width: 750, height: 430)
        .disabled(form.isSavingPassword)
        .task {
            if focusedEmail == nil { focusedEmail = form.initialEmailFocus }
        }
    }

    private var accountRows: some View {
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
                            .focused($focusedEmail, equals: entry.id)
                            .id(entry.id)
                            .labelsHidden()
                            .accessibilityLabel(language.text(.init("accounts.email", defaultValue: "Apple Account 邮箱")))
                            .frame(minWidth: 240, maxWidth: .infinity)
                        HStack(spacing: 6) {
                            Button(form.passwordEnabled(for: entry) ? language.text(.init("accounts.changePassword", defaultValue: "更改密码…")) : language.text(.init("accounts.setPassword", defaultValue: "设置密码…"))) {
                                editPassword(entry.id)
                            }
                            .disabled(!form.canEditPassword(for: entry))
                            if form.passwordEnabled(for: entry) {
                                Button(language.text(.init("accounts.removePassword", defaultValue: "移除密码"))) {
                                    form.removePassword(for: entry.id)
                                }
                                .help(language.text(.init("accounts.password.removeHint", defaultValue: "点击「保存」后关闭自动登录并移除密码。")))
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        Button {
                            form.delete(entry.id)
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

import AppKit
import ApplicationServices

let storeBundleID = "com.apple.AppStore"
let storeURL = URL(fileURLWithPath: "/System/Applications/App Store.app", isDirectory: true)
let testEmail = "poc-test@example.com"

func isSystemStore(_ app: NSRunningApplication) -> Bool {
    app.bundleIdentifier == storeBundleID && !app.isTerminated
        && app.bundleURL?.standardizedFileURL.path == storeURL.standardizedFileURL.path
}

enum StoreLabel: String, CaseIterable {
    case store = "Store"
    case signIn = "Sign In"
    case signOut = "Sign Out"
    case accountField = "Apple Account input"
    case passwordField = "Password input"
    case next = "Continue"

    private var aliases: [String] {
        switch self {
        case .store:
            return ["Store", "商店", "Mağaza"]
        case .signIn:
            return ["Sign In", "登录", "登入", "Giriş Yap", "Oturum Aç"]
        case .signOut:
            return ["Sign Out", "退出登录", "登出", "Oturumu Kapat", "Çıkış Yap"]
        case .next:
            return ["Continue", "Next", "继续", "下一步", "繼續", "Devam", "Devam Et", "İleri"]
        case .passwordField:
            return ["Password", "Apple Account Password", "Apple ID Password", "密码", "密碼",
                    "Apple 账户密码", "Apple 帐户密码", "Apple 帳號密碼", "Apple 帳戶密碼",
                    "Parola", "Şifre", "Apple Hesabı Parolası"]
        case .accountField:
            return [
                "Apple Account", "Apple Account Email or Phone Number", "Apple ID",
                "Email or Phone Number", "Email Address or Phone Number", "电子邮件或电话号码",
                "电子邮件地址或电话号码", "电子邮件或手机号", "电子邮件地址或手机号",
                "Apple 账户", "Apple 帐户", "Apple 帳號", "Apple 帳戶",
                "電子郵件或電話號碼", "電子郵件地址或電話號碼", "電子郵件或手機號碼",
                "Apple Hesabı", "E-posta veya Telefon Numarası",
                "E-posta Adresi veya Telefon Numarası"
            ]
        }
    }

    func matches(_ value: String) -> Bool {
        let punctuation = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".…:："))
        let normalized = value.trimmingCharacters(in: punctuation)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return aliases.contains { $0.localizedCaseInsensitiveCompare(normalized) == .orderedSame }
    }
}

enum StoreState: String {
    case signedIn = "疑似已登录（Store 菜单中有 Sign Out）"
    case signedOut = "疑似已退出（Store 菜单中有 Sign In）"
    case unknown = "未知（菜单不可读、匹配不唯一，或缺少明确状态）"

    var menuTitle: String {
        switch self {
        case .signedIn: return "已登录 · 商店菜单显示「退出登录」"
        case .signedOut: return "未登录 · 商店菜单显示「登录」"
        case .unknown: return "无法从商店菜单判断"
        }
    }

    init(signIn: Int, signOut: Int, complete: Bool) {
        switch (complete, signIn, signOut) {
        case (true, 0, 1): self = .signedIn
        case (true, 1, 0): self = .signedOut
        default: self = .unknown
        }
    }
}

enum LoginPreparation: Equatable {
    case filled
    case writeUncertain
    case manual
    case finishManually
    case submitted
    case submissionUncertain
}

func acceptsAccountField(role: String, subrole: String?, labels: [String]) -> Bool {
    role == kAXTextFieldRole && (subrole == nil || subrole == "AXUnknown")
        && labels.contains(where: StoreLabel.accountField.matches)
}

func acceptsPasswordField(role: String, subrole: String?, labels: [String]) -> Bool {
    role == kAXTextFieldRole && subrole == kAXSecureTextFieldSubrole
        && labels.contains(where: StoreLabel.passwordField.matches)
}

enum NativeLoginStage: Equatable {
    case email, emailAndPassword, password

    init?(inSheet: Bool, complete: Bool, emailFields: Int, passwordFields: Int, otherInputs: Int) {
        guard inSheet, complete, otherInputs == 0 else { return nil }
        switch (emailFields, passwordFields) {
        case (1, 0): self = .email
        case (1, 1): self = .emailAndPassword
        case (0, 1): self = .password
        default: return nil
        }
    }
}

enum StoreOperation: String {
    case inspect = "只读检查"
    case revealMenu = "展开 Store 菜单"
    case signOut = "退出当前账号"
    case openSignIn = "打开原生登录"
    case fill = "预填测试邮箱"

    var needsFrontmost: Bool { self != .inspect }
}

private func axResult(_ error: AXError) -> String {
    "\(error) (\(error.rawValue))"
}

private struct Node {
    let element: AXUIElement
    let role: String
    let subrole: String?
    let labels: [String]

    func matches(_ label: StoreLabel, role expectedRole: String) -> Bool {
        role == expectedRole && labels.contains(where: label.matches)
    }
}

private struct Menu {
    let store: Node?
    let entries: [Node]
    let complete: Bool

    var signOut: [Node] { entries.filter { $0.matches(.signOut, role: kAXMenuItemRole) } }
    var signIn: [Node] { entries.filter { $0.matches(.signIn, role: kAXMenuItemRole) } }
    var state: StoreState {
        StoreState(signIn: signIn.count, signOut: signOut.count, complete: complete)
    }

    var accountItem: Node? {
        switch state {
        case .signedIn: return signOut.first
        case .signedOut: return signIn.first
        case .unknown: return nil
        }
    }
}

private struct WindowTree {
    var fields: [Node] = []
    var signIn: [Node] = []
    var lines: [String] = []
    var sheet: AXUIElement?
    var passwords: [Node] = []
    var submitButtons: [Node] = []
    var otherInputs = 0
    var displayedEmails: Set<String> = []
    var hasSheet = false
    var complete = true

    var loginStage: NativeLoginStage? {
        NativeLoginStage(inSheet: sheet != nil, complete: complete, emailFields: fields.count,
                         passwordFields: passwords.count, otherInputs: otherInputs)
    }

    var submitButton: Node? {
        guard submitButtons.count == 1, let button = submitButtons.first, let loginStage else { return nil }
        if button.matches(.signIn, role: kAXButtonRole) || loginStage == .email { return button }
        return nil
    }
}

final class StoreAX {
    private let pid: pid_t
    private let root: AXUIElement
    private let log: (String) -> Void
    private var faults: [String: Int] = [:]
    private var faultCount = 0

    init(pid: pid_t, log: @escaping (String) -> Void) {
        self.pid = pid
        self.root = AXUIElementCreateApplication(pid)
        self.log = log
    }

    func run(_ operation: StoreOperation) {
        guard AXIsProcessTrusted() else {
            log("辅助功能未授权，停止。")
            return
        }
        let timeout = AXUIElementSetMessagingTimeout(root, 0.4)
        log("AX root PID=\(pid) · 消息超时设置 \(axResult(timeout))")
        defer { reportFaults() }

        let menu = readMenu(report: true)
        switch operation {
        case .inspect:
            if let store = menu.store { reportAction(store, name: "Store") }
            for item in menu.signOut { reportAction(item, name: "Sign Out") }
            for item in menu.signIn { reportAction(item, name: "Sign In") }
            let tree = readWindows()
            report(tree)
            for item in tree.signIn { reportAction(item, name: "窗口 Sign In") }
            for field in tree.fields { _ = reportWritability(field) }
            log("只读检查完成。账号身份需在 App Store 内人工核对。")
        case .revealMenu:
            let checked = menu.accountItem.map(enabled) == true ? menu : revealMenu(menu)
            if let item = checked?.accountItem {
                reportAction(item, name: checked?.state == .signedIn ? "Sign Out" : "Sign In")
            }
            log("菜单检查完成。")
        case .signOut:
            guard menu.state != .signedOut else {
                log("当前菜单显示 Sign In，已停止退出。")
                return
            }
            let checked = menu.accountItem.map(enabled) == true ? menu : revealMenu(menu)
            guard let checked, checked.state == .signedIn, let item = checked.accountItem else {
                log("未确认唯一的 Sign Out，停止。")
                return
            }
            reportAction(item, name: "Sign Out")
            let result = press(item)
            if result == .success || result == .cannotComplete {
                verifySignedOut()
            }
        case .openSignIn:
            if !loginFormIsShowing() {
                let result = pressSignIn(in: menu)
                guard result == .success || result == .cannotComplete else { return }
            }
            Thread.sleep(forTimeInterval: 0.35)
            report(readWindows())
        case .fill:
            let tree = readWindows()
            report(tree)
            guard tree.complete, tree.fields.count == 1, let field = tree.fields.first else {
                log("未找到唯一且可安全识别的 Apple Account 文本框，停止。")
                return
            }
            let result = fill(field, email: testEmail)
            if result == .filled || result == .writeUncertain {
                log("请在原生界面核对是否显示 \(testEmail)。用关闭或取消结束测试。")
            }
        }
    }

    func reportFaults() {
        for key in faults.keys.sorted() {
            log("AX 读取诊断 · \(key) ×\(faults[key, default: 0])")
        }
    }

    // The menu bar app uses these results to decide which step can safely follow.
    func sessionState(waitForMenu: Bool = true) -> StoreState {
        guard configure() else { return .unknown }
        return waitForMenu ? readSettledMenu().state : readMenu(report: false).state
    }

    func signOutForSwitch() -> StoreState {
        guard configure() else { return .unknown }
        let initial = readSettledMenu()
        guard initial.state == .signedIn, let item = initial.accountItem else { return initial.state }
        let ready = enabled(item) ? initial : revealMenu(initial)
        guard let ready else { return .unknown }
        guard ready.state == .signedIn, let target = ready.accountItem else { return ready.state }
        let result = press(target)
        guard result == .success || result == .cannotComplete else { return .unknown }
        return verifySignedOut()
    }

    func prepareLogin(email: String, openIfNeeded: Bool, password: String? = nil) -> LoginPreparation {
        guard configure() else { return .manual }
        let menu = readSettledMenu()
        guard menu.state == .signedOut, isFrontmost else { return .manual }
        // The Store menu is independent of page content. Invalid page nodes must not
        // prevent an already identified menu item from opening the native sign-in UI.
        if openIfNeeded, !loginFormIsShowing() {
            let result = pressSignIn(in: menu)
            if result == .success || result == .cannotComplete {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while ProcessInfo.processInfo.systemUptime < deadline, isFrontmost {
            let tree = readWindows()
            if tree.complete, tree.fields.count == 1, let field = tree.fields.first {
                let state = readMenu(report: false).state
                // A native sheet can temporarily hide the menu. The session was confirmed
                // signed out above; only a unique field inside that sheet can use this path.
                guard state == .signedOut || (state == .unknown && tree.hasSheet) else { return .manual }
                let filled = fill(field, email: email)
                guard filled == .filled, let password, let sheet = tree.sheet else { return filled }
                return submitCredentials(email: email, sheet: sheet, password: password)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        log("未找到可安全预填的账号输入框，请在 App Store 手动继续。")
        return .manual
    }

    private func submitCredentials(email: String, sheet: AXUIElement, password: String) -> LoginPreparation {
        let initial = waitForLoginForm(timeout: 2) { form in
            form.sheet == sheet && (form.loginStage == .email || form.loginStage == .emailAndPassword)
                && self.matchesLoginAccount(form, email: email, submittedIn: nil)
                && form.submitButton.map { form.loginStage == .emailAndPassword || self.enabled($0) } == true
        }
        guard let initial, let firstButton = initial.submitButton else {
            log("自动登录 · 无法确认已填写邮箱的原生表单")
            return .finishManually
        }

        let submittedIn: AXUIElement?
        if initial.loginStage == .email {
            let result = press(firstButton)
            guard result == .success else {
                if result == .cannotComplete { log("自动登录 · 邮箱步骤提交结果待确认") }
                return .finishManually
            }
            log("自动登录 · 已提交邮箱步骤")
            submittedIn = sheet
        } else {
            submittedIn = nil
        }

        let passwordForm = waitForLoginForm(timeout: 6) { form in
            form.passwords.count == 1 && form.submitButton != nil
                && self.matchesLoginAccount(form, email: email, submittedIn: submittedIn)
        }
        guard let passwordForm, let field = passwordForm.passwords.first,
              let button = passwordForm.submitButton, enabled(field), reportWritability(field),
              safeToAct(on: field) else {
            log("自动登录 · 未找到可写且匹配账号的安全密码框")
            return .finishManually
        }

        let write = AXUIElementSetAttributeValue(field.element, kAXValueAttribute as CFString, password as CFString)
        log("自动登录 · 密码框写入 \(axResult(write))")
        guard write == .success else { return .finishManually }
        let ready = waitForLoginForm(timeout: 2) { form in
            form.sheet == passwordForm.sheet && form.passwords.first?.element == field.element
                && form.submitButton?.element == button.element
                && self.matchesLoginAccount(form, email: email, submittedIn: submittedIn)
                && self.enabled(button)
        }
        guard let submit = ready?.submitButton else { return .finishManually }
        switch press(submit) {
        case .success:
            log("自动登录 · 已提交密码步骤")
            return .submitted
        case .cannotComplete:
            log("自动登录 · 密码步骤提交结果待确认")
            return .submissionUncertain
        default:
            return .finishManually
        }
    }

    private func waitForLoginForm(timeout: TimeInterval, where matches: (WindowTree) -> Bool) -> WindowTree? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while isFrontmost && ProcessInfo.processInfo.systemUptime < deadline {
            let form = readWindows(authentication: true)
            if matches(form) { return form }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func matchesLoginAccount(_ form: WindowTree, email: String, submittedIn: AXUIElement?) -> Bool {
        guard form.loginStage != nil, let sheet = form.sheet else { return false }
        let expected = email.lowercased()
        guard form.displayedEmails.allSatisfy({ $0 == expected }) else { return false }
        if let field = form.fields.first {
            // Read back only the known ordinary account field. Never read a secure input's value.
            return (attribute(field.element, kAXValueAttribute) as? String)?.lowercased() == expected
        }
        // A password-only step must follow our successful email step. If Apple
        // replaces the sheet, require the new sheet to show the chosen account.
        guard let submittedIn else { return false }
        return sheet == submittedIn || form.displayedEmails.contains(expected)
    }

    private func pressSignIn(in menu: Menu) -> AXError? {
        guard menu.state == .signedOut, isFrontmost, let item = menu.accountItem else {
            log("未确认唯一的「登录」菜单项，未打开登录窗口。")
            return nil
        }
        // A nil result means no AXPress was sent. Once sent, even a timeout can
        // open the form, so do not try another entry in the same operation.
        if let result = press(item) {
            log("登录入口 · 商店菜单")
            return result
        }
        guard isFrontmost else { return nil }
        let tree = readWindows()
        guard !tree.hasSheet, tree.fields.isEmpty else { return nil }
        if tree.complete, tree.signIn.count == 1, let button = tree.signIn.first,
           readMenu(report: false).state == .signedOut, let result = press(button) {
            log("登录入口 · App Store 窗口")
            return result
        }
        // Some versions only enable the menu item after the Store menu is expanded.
        let current = readMenu(report: false)
        guard current.state == .signedOut, let refreshed = revealMenu(current),
              refreshed.state == .signedOut, let signIn = refreshed.accountItem else { return nil }
        log("登录入口 · 展开后的商店菜单")
        return press(signIn)
    }

    private func loginFormIsShowing() -> Bool {
        let focused = element(root, kAXFocusedWindowAttribute)
        let windows = focused.map { [$0] } ?? children(root, kAXWindowsAttribute, limit: 16)
        guard windows.count == 1, let window = windows.first, owns(window) else { return false }
        if (attribute(window, kAXModalAttribute) as? Bool) == true { return true }
        return !sheets(in: window).isEmpty
    }

    private func sheets(in window: AXUIElement) -> [AXUIElement] {
        if (attribute(window, kAXRoleAttribute) as? String) == kAXSheetRole { return [window] }
        return children(window, kAXChildrenAttribute, limit: 80).filter {
            owns($0) && (attribute($0, kAXRoleAttribute) as? String) == kAXSheetRole
        }
    }

    private func configure() -> Bool {
        guard AXIsProcessTrusted() else {
            log("辅助功能未授权，停止。")
            return false
        }
        let result = AXUIElementSetMessagingTimeout(root, 0.4)
        guard result == .success else {
            log("AX 消息超时设置失败 · \(axResult(result))")
            return false
        }
        return true
    }

    private func owns(_ element: AXUIElement) -> Bool {
        var owner: pid_t = 0
        return AXUIElementGetPid(element, &owner) == .success && owner == pid
    }

    private func record(_ diagnostic: String) {
        faults[diagnostic, default: 0] += 1
        faultCount += 1
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        switch error {
        case .success: return value
        case .attributeUnsupported, .noValue: return nil
        default:
            record("\(key) \(axResult(error))")
            return nil
        }
    }

    private func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func children(_ element: AXUIElement, _ key: String, limit: Int) -> [AXUIElement] {
        var count: CFIndex = 0
        let countError = AXUIElementGetAttributeValueCount(element, key as CFString, &count)
        switch countError {
        case .attributeUnsupported, .noValue: return []
        case .success: break
        default:
            record("\(key) count \(axResult(countError))")
            return []
        }
        guard count > 0 else { return [] }
        if count > limit {
            record("\(key) 超过单层扫描上限")
        }
        var values: CFArray?
        let error = AXUIElementCopyAttributeValues(element, key as CFString, 0, min(count, limit), &values)
        guard error == .success, let items = values as? [AXUIElement] else {
            record("\(key) items \(axResult(error))")
            return []
        }
        if items.count != min(count, limit) {
            record("\(key) 数量在读取时变化")
        }
        return items
    }

    private func node(_ element: AXUIElement, authentication: Bool = false) -> Node? {
        guard owns(element) else {
            record("跳过非 App Store 或归属不明的 AX 元素")
            return nil
        }
        guard let role = attribute(element, kAXRoleAttribute) as? String else {
            record("元素缺少 AXRole")
            return nil
        }
        var subrole: String?
        var keys: [String] = []
        switch role {
        case kAXMenuBarItemRole, kAXMenuItemRole:
            keys = [kAXTitleAttribute]
        case kAXButtonRole, NSAccessibility.Role.link.rawValue:
            keys = [kAXTitleAttribute, kAXDescriptionAttribute]
        case kAXTextFieldRole:
            subrole = attribute(element, kAXSubroleAttribute) as? String
            if subrole == nil || subrole == "AXUnknown" {
                keys = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
            } else if authentication && subrole == kAXSecureTextFieldSubrole {
                keys = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXIdentifierAttribute]
            }
        default: break
        }
        let labels = keys.compactMap { attribute(element, $0) as? String }
        return Node(element: element, role: role, subrole: subrole, labels: labels)
    }

    private func readSettledMenu() -> Menu {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var menu = readMenu(report: true)
        guard menu.state == .unknown else { return menu }
        var retries = 0
        while ProcessInfo.processInfo.systemUptime < deadline, AXIsProcessTrusted() {
            Thread.sleep(forTimeInterval: 0.25)
            retries += 1
            menu = readMenu(report: false)
            if menu.state != .unknown { break }
        }
        log("商店菜单重读 \(retries) 次 · \(menu.state.rawValue)")
        return menu
    }

    private func readMenu(report: Bool) -> Menu {
        let initialFaults = faultCount
        guard let bar = element(root, kAXMenuBarAttribute), owns(bar) else {
            if report { log("AXMenuBar 不可读或归属不明。") }
            return Menu(store: nil, entries: [], complete: false)
        }
        let items = children(bar, kAXChildrenAttribute, limit: 32).compactMap { node($0) }
        let stores = items.filter { $0.matches(.store, role: kAXMenuBarItemRole) }
        guard faultCount == initialFaults, stores.count == 1, let store = stores.first else {
            if report { log("AXMenuBar · 顶层元素 \(items.count) 个 · Store 匹配 \(stores.count) 个 · 状态未知") }
            return Menu(store: nil, entries: [], complete: false)
        }
        let groups = children(store.element, kAXChildrenAttribute, limit: 40).compactMap { node($0) }
        // AppKit normally exposes a single AXMenu under AXMenuBarItem.
        // Also accept direct AXMenuItem children if that is the only structure exposed.
        let containers = groups.filter { $0.role == kAXMenuRole }
        let directItems = groups.filter { $0.role == kAXMenuItemRole }
        let validShape = (containers.count == 1 && directItems.isEmpty)
            || (containers.isEmpty && !directItems.isEmpty)
        let entries = containers.first.map { container in
            children(container.element, kAXChildrenAttribute, limit: 64).compactMap { node($0) }
        } ?? directItems
        let menu = Menu(
            store: store, entries: entries,
            complete: validShape && !entries.isEmpty && faultCount == initialFaults
        )
        if report {
            log("AXMenuBar → AXMenuBarItem[Store] · 子菜单 \(containers.count) 个 · 条目 \(entries.count) 个 · 完整=\(menu.complete)")
            log("Sign Out 匹配 \(menu.signOut.count) 个 · Sign In 匹配 \(menu.signIn.count) 个")
            log("状态 · \(menu.state.rawValue)")
        }
        return menu
    }

    private func readWindows(authentication: Bool = false) -> WindowTree {
        let initialFaults = faultCount
        var tree = WindowTree()
        let windows = children(root, kAXWindowsAttribute, limit: 16)
        let focused = element(root, kAXFocusedWindowAttribute)
        let scope = focused.map { [$0] } ?? windows
        guard scope.count == 1, let window = scope.first, owns(window) else {
            log("窗口范围不唯一或不可读 · App Store AXWindows=\(windows.count)")
            tree.complete = false
            return tree
        }

        let sheets = sheets(in: window)
        tree.hasSheet = !sheets.isEmpty
        guard sheets.count <= 1 else {
            log("窗口存在多个原生表单，停止自动识别。")
            tree.complete = false
            return tree
        }
        tree.sheet = sheets.first
        if authentication && tree.sheet == nil {
            tree.complete = false
            return tree
        }
        // A native sheet takes precedence over the content below it.
        let seeds = sheets.isEmpty ? [window] : sheets
        var queue = seeds.map { ($0, 0) }
        var seen: Set<AXUIElement> = []
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var index = 0
        while index < queue.count {
            guard index < 280, ProcessInfo.processInfo.systemUptime < deadline else {
                record("窗口扫描达到时间或节点上限")
                break
            }
            let (element, depth) = queue[index]
            index += 1
            guard seen.insert(element).inserted, let item = node(element, authentication: authentication) else { continue }
            if authentication && (attribute(element, kAXHiddenAttribute) as? Bool) == true { continue }
            let accountField = acceptsAccountField(role: item.role, subrole: item.subrole, labels: item.labels)
            if accountField {
                tree.fields.append(item)
            }
            if authentication {
                if acceptsPasswordField(role: item.role, subrole: item.subrole, labels: item.labels) {
                    tree.passwords.append(item)
                } else if !accountField && [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(item.role) {
                    tree.otherInputs += 1
                }
                if item.matches(.signIn, role: kAXButtonRole) || item.matches(.next, role: kAXButtonRole) {
                    tree.submitButtons.append(item)
                }
                if item.role == kAXStaticTextRole {
                    for key in [kAXTitleAttribute, kAXValueAttribute] {
                        if let text = attribute(element, key) as? String {
                            tree.displayedEmails.formUnion(Self.emailAddresses(in: text))
                        }
                    }
                }
            }
            if item.matches(.signIn, role: kAXButtonRole)
                || item.matches(.signIn, role: NSAccessibility.Role.link.rawValue) {
                tree.signIn.append(item)
            }
            let knownLabels = [StoreLabel.signIn, .accountField].filter { label in
                item.labels.contains(where: label.matches)
            }.map(\.rawValue)
            if tree.lines.count < 45 || !knownLabels.isEmpty {
                // Record only structure and fixed labels. Never print arbitrary AX strings.
                let labels = knownLabels.map { " [\($0)]" }.joined()
                let role = item.role.hasPrefix("AX") && item.role.count < 50
                    && item.role.allSatisfy { $0.isASCII && $0.isLetter } ? item.role : "其他角色"
                let secure = item.subrole == kAXSecureTextFieldSubrole ? " [secure]" : ""
                tree.lines.append("\(String(repeating: "  ", count: depth))\(role)\(secure)\(labels)")
            }
            if item.subrole == kAXSecureTextFieldSubrole { continue }
            let next = children(element, kAXChildrenAttribute, limit: 80)
            if depth == 16, !next.isEmpty {
                record("窗口扫描达到深度上限")
            } else {
                queue.append(contentsOf: next.map { ($0, depth + 1) })
            }
        }
        tree.complete = faultCount == initialFaults
        if !authentication {
            log("窗口范围 · App Store AXWindows=\(windows.count) · AXSheet=\(sheets.count) · 已扫描 \(seen.count) 节点")
        }
        return tree
    }

    private static let emailDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func emailAddresses(in text: String) -> [String] {
        guard text.contains("@"), text.utf16.count <= 1_000, let emailDetector else { return [] }
        return emailDetector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.url?.scheme == "mailto", let range = Range(match.range, in: text) else { return nil }
            return text[range].lowercased()
        }
    }

    private func report(_ tree: WindowTree) {
        log("窗口 AX 树（最多 45 个普通节点，另列已匹配节点）")
        for line in tree.lines { log(line) }
        log("登录入口 \(tree.signIn.count) 个 · Apple Account 文本框 \(tree.fields.count) 个 · 完整=\(tree.complete)")
    }

    private func enabled(_ node: Node) -> Bool {
        (attribute(node.element, kAXEnabledAttribute) as? Bool) == true
    }

    private func pressCapability(_ node: Node) -> (supported: Bool, result: AXError) {
        var names: CFArray?
        let result = AXUIElementCopyActionNames(node.element, &names)
        return (result == .success && (names as? [String])?.contains(kAXPressAction) == true, result)
    }

    private func reportAction(_ node: Node, name: String) {
        let isEnabled = attribute(node.element, kAXEnabledAttribute) as? Bool
        let capability = pressCapability(node)
        log("\(name) · AXEnabled=\(isEnabled.map(String.init) ?? "未知") · AXPress=\(capability.supported) · \(axResult(capability.result))")
    }

    private func revealMenu(_ menu: Menu) -> Menu? {
        guard let store = menu.store else {
            log("缺少唯一的 Store 菜单，停止。")
            return nil
        }
        log("展开顶层 Store 菜单，等待菜单项更新。")
        // Native menu tracking can keep AXPress waiting while the menu is open.
        let timeout = AXUIElementSetMessagingTimeout(store.element, 0.4)
        log("Store 菜单消息超时设置 · \(axResult(timeout))")
        let result = press(store)
        guard result == .success || result == .cannotComplete else { return nil }

        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        repeat {
            guard safeToAct(on: store) else { return nil }
            let refreshed = readMenu(report: false)
            if let item = refreshed.accountItem, enabled(item) {
                log("菜单刷新后 · \(refreshed.state.rawValue)")
                return refreshed
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        log("展开后未确认唯一且启用的账号菜单项。")
        _ = readMenu(report: true)
        return nil
    }

    private var isFrontmost: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        return app.processIdentifier == pid && isSystemStore(app) && AXIsProcessTrusted()
    }

    private func safeToAct(on node: Node) -> Bool {
        guard owns(node.element), isFrontmost else {
            log("目标已变更、未在前台，或授权已撤回，停止。")
            return false
        }
        return true
    }

    @discardableResult
    private func press(_ node: Node) -> AXError? {
        guard enabled(node) else {
            log("AXEnabled 未明确为 true，停止。")
            return nil
        }
        let capability = pressCapability(node)
        guard capability.supported else {
            log("元素未公开 AXPress · AXCopyActionNames \(axResult(capability.result))")
            return nil
        }
        guard safeToAct(on: node) else { return nil }
        let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
        log("AXPress · \(axResult(result))")
        if result == .cannotComplete {
            log("App Store 未及时响应。动作可能已生效，请核对界面。")
        }
        return result
    }

    @discardableResult
    private func verifySignedOut() -> StoreState {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var state: StoreState = .unknown
        repeat {
            Thread.sleep(forTimeInterval: 0.25)
            state = readMenu(report: false).state
        } while state != .signedOut && ProcessInfo.processInfo.systemUptime < deadline
        log("退出后检查 · \(state.rawValue)。如 App Store 显示确认框，由你在原生界面处理后重新检查。")
        return state
    }

    private func fill(_ field: Node, email: String) -> LoginPreparation {
        let initialFaults = faultCount
        guard let current = node(field.element), faultCount == initialFaults,
              acceptsAccountField(role: current.role, subrole: current.subrole, labels: current.labels),
              enabled(current) else {
            log("文本框已变化或禁用，停止。")
            return .manual
        }
        guard reportWritability(current), safeToAct(on: current) else { return .manual }
        let result = AXUIElementSetAttributeValue(field.element, kAXValueAttribute as CFString, email as CFString)
        log("AXSetValue · \(axResult(result))")
        switch result {
        case .success: return .filled
        case .cannotComplete: return .writeUncertain
        default: return .manual
        }
    }

    private func reportWritability(_ field: Node) -> Bool {
        var settable = DarwinBoolean(false)
        let checked = AXUIElementIsAttributeSettable(field.element, kAXValueAttribute as CFString, &settable)
        log("AXValue 可写检查 · \(axResult(checked)) · settable=\(settable.boolValue)")
        return checked == .success && settable.boolValue
    }
}

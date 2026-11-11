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

    private var aliases: [String] {
        switch self {
        case .store:
            return ["Store", "商店", "Mağaza"]
        case .signIn:
            return ["Sign In", "登录", "登入", "Giriş Yap", "Oturum Aç"]
        case .signOut:
            return ["Sign Out", "退出登录", "登出", "Oturumu Kapat", "Çıkış Yap"]
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

    init(signIn: Int, signOut: Int, complete: Bool) {
        switch (complete, signIn, signOut) {
        case (true, 0, 1): self = .signedIn
        case (true, 1, 0): self = .signedOut
        default: self = .unknown
        }
    }
}

func acceptsAccountField(role: String, subrole: String?, labels: [String]) -> Bool {
    role == kAXTextFieldRole && (subrole == nil || subrole == "AXUnknown")
        && labels.contains(where: StoreLabel.accountField.matches)
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
    var complete = true
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
        defer {
            for key in faults.keys.sorted() {
                log("AX 读取诊断 · \(key) ×\(faults[key, default: 0])")
            }
        }

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
            guard menu.state != .signedIn else {
                log("Store 菜单提示已有账号登录，停止。")
                return
            }
            if menu.state == .signedOut, let item = menu.signIn.first, enabled(item) {
                openSignIn(item)
                return
            }
            let tree = readWindows()
            report(tree)
            guard menu.complete, menu.signOut.isEmpty, tree.complete, tree.fields.isEmpty,
                  tree.signIn.count == 1, let item = tree.signIn.first else {
                log("登录入口或窗口状态无法唯一确认。可手动点击 App Store 左下角的登录。")
                return
            }
            openSignIn(item)
        case .fill:
            let tree = readWindows()
            report(tree)
            guard tree.complete, tree.fields.count == 1, let field = tree.fields.first else {
                log("未找到唯一且可安全识别的 Apple Account 文本框，停止。")
                return
            }
            fill(field)
        }
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

    private func node(_ element: AXUIElement) -> Node? {
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
            }
        default: break
        }
        let labels = keys.compactMap { attribute(element, $0) as? String }
        return Node(element: element, role: role, subrole: subrole, labels: labels)
    }

    private func readMenu(report: Bool) -> Menu {
        let initialFaults = faultCount
        guard let bar = element(root, kAXMenuBarAttribute), owns(bar) else {
            if report { log("AXMenuBar 不可读或归属不明。") }
            return Menu(store: nil, entries: [], complete: false)
        }
        let items = children(bar, kAXChildrenAttribute, limit: 32).compactMap(node)
        let stores = items.filter { $0.matches(.store, role: kAXMenuBarItemRole) }
        guard faultCount == initialFaults, stores.count == 1, let store = stores.first else {
            if report { log("AXMenuBar · 顶层元素 \(items.count) 个 · Store 匹配 \(stores.count) 个 · 状态未知") }
            return Menu(store: nil, entries: [], complete: false)
        }
        let groups = children(store.element, kAXChildrenAttribute, limit: 40).compactMap(node)
        // AppKit normally exposes a single AXMenu under AXMenuBarItem.
        // Also accept direct AXMenuItem children if that is the only structure exposed.
        let containers = groups.filter { $0.role == kAXMenuRole }
        let directItems = groups.filter { $0.role == kAXMenuItemRole }
        let validShape = (containers.count == 1 && directItems.isEmpty)
            || (containers.isEmpty && !directItems.isEmpty)
        let entries = containers.first.map {
            children($0.element, kAXChildrenAttribute, limit: 64).compactMap(node)
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

    private func readWindows() -> WindowTree {
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

        let sheets = children(window, kAXChildrenAttribute, limit: 80).filter {
            owns($0) && (attribute($0, kAXRoleAttribute) as? String) == kAXSheetRole
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
            guard seen.insert(element).inserted, let item = node(element) else { continue }
            if acceptsAccountField(role: item.role, subrole: item.subrole, labels: item.labels) {
                tree.fields.append(item)
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
        log("窗口范围 · App Store AXWindows=\(windows.count) · AXSheet=\(sheets.count) · 已扫描 \(seen.count) 节点")
        return tree
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

    private func safeToAct(on node: Node) -> Bool {
        guard owns(node.element), AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
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

    private func verifySignedOut() {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var state: StoreState = .unknown
        repeat {
            Thread.sleep(forTimeInterval: 0.25)
            state = readMenu(report: false).state
        } while state != .signedOut && ProcessInfo.processInfo.systemUptime < deadline
        log("退出后检查 · \(state.rawValue)。如 App Store 显示确认框，由你在原生界面处理后重新检查。")
    }

    private func openSignIn(_ item: Node) {
        let result = press(item)
        guard result == .success || result == .cannotComplete else { return }
        Thread.sleep(forTimeInterval: 0.35)
        let tree = readWindows()
        report(tree)
        if tree.fields.isEmpty {
            log("App Store 进程内暂未看到支持的输入框。等待登录界面加载后重试只读检查；独立认证界面由你操作。")
        }
    }

    private func fill(_ field: Node) {
        let initialFaults = faultCount
        guard let current = node(field.element), faultCount == initialFaults,
              acceptsAccountField(role: current.role, subrole: current.subrole, labels: current.labels),
              enabled(current) else {
            log("文本框已变化或禁用，停止。")
            return
        }
        guard reportWritability(current), safeToAct(on: current) else { return }
        let result = AXUIElementSetAttributeValue(field.element, kAXValueAttribute as CFString, testEmail as CFString)
        log("AXSetValue · \(axResult(result))")
        if result == .success || result == .cannotComplete {
            log("请在原生界面核对是否显示 \(testEmail)。用关闭或取消结束测试。")
        }
    }

    private func reportWritability(_ field: Node) -> Bool {
        var settable = DarwinBoolean(false)
        let checked = AXUIElementIsAttributeSettable(field.element, kAXValueAttribute as CFString, &settable)
        log("AXValue 可写检查 · \(axResult(checked)) · settable=\(settable.boolValue)")
        return checked == .success && settable.boolValue
    }
}

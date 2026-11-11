import Foundation

struct StoreRegion: RawRepresentable, Codable, Identifiable, Hashable {
    let rawValue: String

    static let unspecified = StoreRegion(rawValue: "")
    static let china = StoreRegion(rawValue: "CN")
    static let unitedStates = StoreRegion(rawValue: "US")
    static let turkey = StoreRegion(rawValue: "TR")
    private static let displayLocale = Locale(identifier: "zh_Hans")

    static let choices: [StoreRegion] = {
        let common = [china, unitedStates, turkey]
        let others = Set(Locale.Region.isoRegions.map { StoreRegion(rawValue: $0.identifier) })
            .subtracting(common + [unspecified])
            .filter { $0.flag != "🌐" }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return [unspecified] + common + others
    }()

    var id: String { rawValue }

    var title: String {
        if self == .unspecified { return "未指定" }
        if self == .china { return "中国大陆" }
        return Self.displayLocale.localizedString(forRegionCode: rawValue) ?? rawValue
    }

    var flag: String {
        let letters = rawValue.utf8
        guard letters.count == 2, letters.allSatisfy({ (65...90).contains($0) }) else { return "🌐" }
        return letters.compactMap { UnicodeScalar(0x1F1E6 + Int($0) - 65) }.map(String.init).joined()
    }

    var label: String { "\(flag) \(title)" }

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

struct StoreAccount: Equatable, Codable, Identifiable {
    let id: UUID
    var region: StoreRegion
    var email: String
    var passwordID: UUID?

    var label: String { "\(region.flag) \(email)" }

    init(id: UUID = UUID(), region: StoreRegion = .unspecified, email: String = "", passwordID: UUID? = nil) {
        self.id = id
        self.region = region
        self.email = email
        self.passwordID = passwordID
    }

    private enum CodingKeys: String, CodingKey { case id, region, email, passwordID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        region = try values.decodeIfPresent(StoreRegion.self, forKey: .region) ?? .unspecified
        email = try values.decode(String.self, forKey: .email)
        passwordID = try values.decodeIfPresent(UUID.self, forKey: .passwordID)
    }

    static func validEmail(_ email: String) -> Bool {
        guard email.count <= 254, !email.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
    }
}

struct StoreSnapshot {
    let pid: pid_t
    let state: StoreState
}

enum StoreAutomationError: Error {
    case permission, unavailable, processChanged, notFrontmost

    var message: String {
        switch self {
        case .permission: return "请在系统设置开启辅助功能，再继续。"
        case .unavailable: return "系统 App Store 未打开或无法读取。"
        case .processChanged: return "App Store 已重新启动，请检查原生界面后继续。"
        case .notFrontmost: return "App Store 未能成为前台，请打开它后重试。"
        }
    }
}

@MainActor
protocol StoreAutomating {
    func inspect(open: Bool) async throws -> StoreSnapshot
    func observeLogin() async throws -> StoreState
    func signOut(pid: pid_t) async throws -> StoreState
    func readSavedPassword(id: UUID) async throws -> String
    func prepareLogin(pid: pid_t, email: String, openIfNeeded: Bool, password: String?,
                      restoreFocus: Bool) async throws -> LoginPreparation
}

@MainActor
final class AccountSwitchCoordinator {
    enum LoginCheck: Equatable {
        case state(StoreState)
        case unavailable(String)

        var message: String {
            switch self {
            case .state(let state): return state.menuTitle
            case .unavailable(let reason): return reason
            }
        }
    }

    enum Step: Equatable {
        case idle, checking, confirmExit, readingKeychain, signingOut, preparing
        case awaitingAuthentication(LoginPreparation)
        case verifying, cancelled
        case needsInitialCheck(String)
        case needsSignOut(String)
        case needsSignIn(String)

        var isWorking: Bool {
            switch self {
            case .checking, .confirmExit, .readingKeychain, .signingOut, .preparing, .verifying: return true
            default: return false
            }
        }

        var canSelect: Bool {
            switch self {
            case .idle, .cancelled: return true
            default: return false
            }
        }

        var title: String {
            switch self {
            case .idle: return "就绪"
            case .checking: return "正在检查 App Store…"
            case .confirmExit: return "等待确认退出"
            case .readingKeychain: return "正在读取钥匙串 · 如有提示，请在系统窗口确认"
            case .signingOut: return "正在退出当前账号…"
            case .preparing: return "正在准备登录…"
            case .awaitingAuthentication(.filled): return "已尝试预填 · 请在 App Store 登录"
            case .awaitingAuthentication(.writeUncertain): return "预填结果未确认 · 请核对邮箱后登录"
            case .awaitingAuthentication(.manual): return "请在 App Store 手动登录"
            case .awaitingAuthentication(.finishManually): return "请在 App Store 继续登录"
            case .awaitingAuthentication(.submitted): return "已提交登录 · 请处理 Apple 验证（如有）"
            case .awaitingAuthentication(.submissionUncertain): return "提交结果待确认 · 请查看 App Store"
            case .verifying: return "正在检查登录状态…"
            case .cancelled: return "切换已结束"
            case .needsInitialCheck: return "未能确认当前登录状态"
            case .needsSignOut: return "需要检查退出状态"
            case .needsSignIn: return "需要检查登录状态"
            }
        }
    }

    private(set) var step: Step = .idle
    private(set) var target: StoreAccount?
    private(set) var storeState: StoreState?
    private(set) var checkError: String?
    private let service: any StoreAutomating
    private let log: (String) -> Void

    private let observationInterval: Duration
    private var loginMonitor: Task<Void, Never>?

    init(service: any StoreAutomating, observationInterval: Duration = .seconds(2), log: @escaping (String) -> Void) {
        self.service = service
        self.observationInterval = observationInterval
        self.log = log
    }

    func start(_ account: StoreAccount, confirmExit: (StoreAccount) -> Bool) async {
        guard step.canSelect, StoreAccount.validEmail(account.email) else { return }
        target = account
        log("开始切换 · 地区 \(account.region.title)")
        await checkBeforeSwitch(account, confirmExit: confirmExit)
    }

    func retryInitialCheck(confirmExit: (StoreAccount) -> Bool) async {
        guard case .needsInitialCheck = step, let target else { return }
        await checkBeforeSwitch(target, confirmExit: confirmExit)
    }

    private func checkBeforeSwitch(_ account: StoreAccount, confirmExit: (StoreAccount) -> Bool) async {
        transition(.checking)
        do {
            let snapshot = try await inspect(open: true)
            guard snapshot.state != .unknown else {
                transition(.needsInitialCheck("等 App Store 加载后，可以重新检查并继续。"))
                return
            }
            if snapshot.state == .signedIn {
                transition(.confirmExit)
                guard confirmExit(account) else {
                    target = nil
                    transition(.cancelled)
                    return
                }
            }
            let password = await savedPassword(for: account)
            if snapshot.state == .signedIn {
                transition(.signingOut)
                storeState = nil
                let afterExit = try await service.signOut(pid: snapshot.pid)
                storeState = afterExit
                guard afterExit == .signedOut else {
                    transition(.needsSignOut("请处理 App Store 的退出提示，或手动退出后再继续。"))
                    return
                }
            }
            await prepare(account, pid: snapshot.pid, openIfNeeded: true, password: password,
                          restoreFocus: snapshot.state == .signedOut && account.passwordID != nil)
        } catch {
            transition(step == .signingOut ? .needsSignOut(message(for: error)) : .needsInitialCheck(message(for: error)))
        }
    }

    func continueAfterSignOut() async {
        guard case .needsSignOut = step, let target else { return }
        transition(.checking)
        do {
            let snapshot = try await inspect(open: true)
            guard snapshot.state == .signedOut else {
                transition(.needsSignOut("尚未检测到退出。请在 App Store 检查退出状态后再继续。"))
                return
            }
            let password = await savedPassword(for: target)
            await prepare(target, pid: snapshot.pid, openIfNeeded: true, password: password,
                          restoreFocus: target.passwordID != nil)
        } catch {
            transition(.needsSignOut(message(for: error)))
        }
    }

    func retryLogin(openIfNeeded: Bool) async {
        guard let target, isWaitingForLogin else { return }
        stopMonitoringLogin()
        transition(.checking)
        do {
            let snapshot = try await inspect(open: true)
            switch snapshot.state {
            case .signedIn:
                finishLogin()
            case .signedOut:
                await prepare(target, pid: snapshot.pid, openIfNeeded: openIfNeeded)
            case .unknown:
                transition(.needsSignIn("请打开 Apple 的登录表单，或在完成登录后检查状态。"))
                monitorLogin()
            }
        } catch {
            transition(.needsSignIn(message(for: error)))
            monitorLogin()
        }
    }

    var isWaitingForLogin: Bool {
        switch step {
        case .awaitingAuthentication, .needsSignIn: return true
        default: return false
        }
    }

    @discardableResult
    func checkLogin() async -> LoginCheck {
        log("手动检查 App Store 登录状态")
        guard !step.isWorking else {
            let result = LoginCheck.unavailable("正在处理 App Store，请稍后再试。")
            log("检查结果 · \(result.message)")
            return result
        }
        let previous = step
        let pendingLogin = isWaitingForLogin
        transition(.verifying)
        let result: LoginCheck
        do {
            let snapshot = try await inspect(open: false)
            result = .state(snapshot.state)
            if pendingLogin && snapshot.state == .signedIn {
                finishLogin()
            } else {
                step = previous
            }
        } catch {
            result = .unavailable(message(for: error))
            step = previous
        }
        log("检查结果 · \(result.message)")
        return result
    }

    func end() {
        guard !step.isWorking, !step.canSelect else { return }
        stopMonitoringLogin()
        target = nil
        transition(.cancelled)
    }

    private func savedPassword(for account: StoreAccount) async -> String? {
        guard let id = account.passwordID else { return nil }
        transition(.readingKeychain)
        do {
            let password = try await service.readSavedPassword(id: id)
            log("自动登录 · 已读取本机钥匙串")
            return password
        } catch {
            log("自动登录 · 无法读取本机钥匙串，将尝试仅预填邮箱")
            return nil
        }
    }

    private func prepare(_ account: StoreAccount, pid: pid_t, openIfNeeded: Bool,
                         password: String? = nil, restoreFocus: Bool = false) async {
        transition(.preparing)
        do {
            let result = try await service.prepareLogin(pid: pid, email: account.email, openIfNeeded: openIfNeeded,
                                                        password: password, restoreFocus: restoreFocus)
            transition(.awaitingAuthentication(result))
        } catch {
            transition(.needsSignIn(message(for: error)))
        }
        monitorLogin()
    }

    private func monitorLogin() {
        stopMonitoringLogin()
        let interval = observationInterval
        loginMonitor = Task { [weak self] in
            var attempts = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: attempts < 20 ? interval : .seconds(10))
                } catch { return }
                guard let self else { return }
                guard self.isWaitingForLogin else { continue }
                attempts += 1
                let state = try? await self.service.observeLogin()
                guard !Task.isCancelled else { return }
                if state == .signedIn && self.isWaitingForLogin {
                    self.finishLogin()
                    return
                }
            }
        }
    }

    private func stopMonitoringLogin() {
        loginMonitor?.cancel()
        loginMonitor = nil
    }

    private func finishLogin() {
        stopMonitoringLogin()
        target = nil
        storeState = .signedIn
        checkError = nil
        log("检测到 App Store 已登录 · 本次切换结束")
        transition(.idle)
    }

    private func inspect(open: Bool) async throws -> StoreSnapshot {
        storeState = nil
        checkError = nil
        do {
            let snapshot = try await service.inspect(open: open)
            storeState = snapshot.state
            return snapshot
        } catch {
            checkError = message(for: error)
            throw error
        }
    }

    private func transition(_ step: Step) {
        self.step = step
        log("状态 · \(step.title)")
    }

    private func message(for error: Error) -> String {
        (error as? StoreAutomationError)?.message ?? "操作未能完成，请在 App Store 检查后重试。"
    }
}

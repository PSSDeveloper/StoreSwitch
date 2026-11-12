import Foundation

struct StoreRegion: RawRepresentable, Codable, Identifiable, Hashable {
    let rawValue: String

    static let unspecified = StoreRegion(rawValue: "")
    static let china = StoreRegion(rawValue: "CN")
    static let unitedStates = StoreRegion(rawValue: "US")
    static let turkey = StoreRegion(rawValue: "TR")
    private static let localizedChoices: [AppLanguage: [StoreRegion]] = {
        let common = [china, unitedStates, turkey]
        let others = Set(Locale.Region.isoRegions.map { StoreRegion(rawValue: $0.identifier) })
            .subtracting(common + [unspecified])
            .filter { $0.flag != "🌐" }
        return Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map { language in
            let sorted = others.map { ($0, $0.title(in: language)) }.sorted {
                $0.1.compare($1.1, options: [.numeric], locale: language.locale) == .orderedAscending
            }.map { $0.0 }
            return (language, [unspecified] + common + sorted)
        })
    }()

    static func choices(in language: AppLanguage) -> [StoreRegion] { localizedChoices[language] ?? [] }

    var id: String { rawValue }

    func title(in language: AppLanguage) -> String {
        if self == .unspecified { return language.text(.init("region.unspecified", defaultValue: "未指定")) }
        if self == .china { return language.text(.init("region.china", defaultValue: "中国大陆")) }
        return language.locale.localizedString(forRegionCode: rawValue) ?? rawValue
    }

    var flag: String {
        let letters = rawValue.utf8
        guard letters.count == 2, letters.allSatisfy({ (65...90).contains($0) }) else { return "🌐" }
        return letters.compactMap { UnicodeScalar(0x1F1E6 + Int($0) - 65) }.map(String.init).joined()
    }

    func label(in language: AppLanguage) -> String { "\(flag) \(title(in: language))" }

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

    var message: LocalizedStringResource {
        switch self {
        case .permission: return .init("error.permission", defaultValue: "请在系统设置开启辅助功能，再继续。")
        case .unavailable: return .init("error.storeUnavailable", defaultValue: "系统 App Store 未打开或无法读取。")
        case .processChanged: return .init("error.processChanged", defaultValue: "App Store 已重新启动，请检查原生界面后继续。")
        case .notFrontmost: return .init("error.notFrontmost", defaultValue: "App Store 未能成为前台，请打开它后重试。")
        }
    }
}

@MainActor
protocol StoreAutomating {
    func inspect(activate: Bool) async throws -> StoreSnapshot
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
        case unavailable(LocalizedStringResource)

        var message: LocalizedStringResource {
            switch self {
            case .state(let state): return state.details
            case .unavailable(let reason): return reason
            }
        }
    }

    enum Step: Equatable {
        case idle, checking, confirmExit, readingKeychain, confirmManualFallback, signingOut, preparing
        case awaitingAuthentication(LoginPreparation)
        case verifying, cancelled, needsManualLogin
        case needsInitialCheck(LocalizedStringResource)
        case needsSignOut(LocalizedStringResource)
        case needsSignIn(LocalizedStringResource)

        var isWorking: Bool {
            switch self {
            case .checking, .confirmExit, .readingKeychain, .confirmManualFallback, .signingOut, .preparing, .verifying: return true
            default: return false
            }
        }

        var canSelect: Bool {
            switch self {
            case .idle, .cancelled: return true
            default: return false
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .idle: return .init("state.ready", defaultValue: "就绪")
            case .checking, .verifying: return .init("state.checking", defaultValue: "正在检查登录状态…")
            case .confirmExit: return .init("state.confirmExit", defaultValue: "等待确认退出")
            case .readingKeychain: return .init("state.readingKeychain", defaultValue: "正在读取钥匙串…")
            case .confirmManualFallback, .needsManualLogin:
                return .init("switch.manual.title", defaultValue: "需要手动登录")
            case .signingOut: return .init("state.signingOut", defaultValue: "正在退出登录…")
            case .preparing: return .init("state.preparing", defaultValue: "正在准备登录…")
            case .awaitingAuthentication(.filled), .awaitingAuthentication(.manual), .awaitingAuthentication(.finishManually):
                return .init("state.finishSignIn", defaultValue: "请在 App Store 完成登录")
            case .awaitingAuthentication(.writeUncertain): return .init("state.verifyEmail", defaultValue: "请核对邮箱后登录")
            case .awaitingAuthentication(.submitted): return .init("state.waitingForSignIn", defaultValue: "等待登录完成")
            case .awaitingAuthentication(.submissionUncertain): return .init("state.submissionUnconfirmed", defaultValue: "登录提交待确认")
            case .cancelled: return .init("state.cancelled", defaultValue: "切换已结束")
            case .needsInitialCheck, .needsSignIn: return .init("state.needsSignInCheck", defaultValue: "需要检查登录状态")
            case .needsSignOut: return .init("state.needsSignOutCheck", defaultValue: "需要检查退出状态")
            }
        }

        var guidance: LocalizedStringResource? {
            switch self {
            case .needsInitialCheck(let detail), .needsSignOut(let detail), .needsSignIn(let detail): return detail
            case .readingKeychain:
                return .init("guidance.keychain", defaultValue: "如果 macOS 请求访问钥匙串，请在系统提示中确认。")
            case .needsManualLogin:
                return .init("switch.manual.signedOut", defaultValue: "App Store 当前未登录，且无法读取已保存的密码。请在 App Store 手动登录目标账号。")
            case .awaitingAuthentication(.filled):
                return .init("guidance.filled", defaultValue: "已尝试预填邮箱。请核对后在 App Store 登录。")
            case .awaitingAuthentication(.writeUncertain):
                return .init("guidance.writeUncertain", defaultValue: "尚未确认邮箱是否填入。请在 App Store 核对后登录。")
            case .awaitingAuthentication(.submitted):
                return .init("guidance.submitted", defaultValue: "已提交登录。如有 Apple 验证提示，请在 App Store 完成。")
            case .awaitingAuthentication(.submissionUncertain):
                return .init("guidance.submissionUncertain", defaultValue: "请在 App Store 查看登录是否已提交，并完成 Apple 要求的验证。")
            default: return nil
            }
        }
    }

    private(set) var step: Step = .idle
    private(set) var target: StoreAccount?
    private(set) var storeState: StoreState?
    private(set) var checkError: LocalizedStringResource?
    private let service: any StoreAutomating
    private let log: (String) -> Void
    private let confirmManualFallback: (StoreAccount) -> Bool
    private let updateManualLoginRecovery: (StoreAccount?) -> Void

    private let observationInterval: Duration
    private var loginMonitor: Task<Void, Never>?
    private var choseManualLogin = false

    init(service: any StoreAutomating, observationInterval: Duration = .seconds(2),
         confirmManualFallback: @escaping (StoreAccount) -> Bool = { _ in false },
         updateManualLoginRecovery: @escaping (StoreAccount?) -> Void = { _ in }, log: @escaping (String) -> Void) {
        self.service = service
        self.observationInterval = observationInterval
        self.confirmManualFallback = confirmManualFallback
        self.updateManualLoginRecovery = updateManualLoginRecovery
        self.log = log
    }

    func start(_ account: StoreAccount, confirmExit: (StoreAccount) -> Bool) async {
        guard step.canSelect, StoreAccount.validEmail(account.email) else { return }
        target = account
        choseManualLogin = false
        log(tr(.init("log.switchStarted", defaultValue: "开始切换 · 地区 \(account.region.title(in: .current))")))
        await checkBeforeSwitch(account, confirmExit: confirmExit)
    }

    func retryInitialCheck(confirmExit: (StoreAccount) -> Bool) async {
        guard case .needsInitialCheck = step, let target else { return }
        await checkBeforeSwitch(target, confirmExit: confirmExit)
    }

    private func checkBeforeSwitch(_ account: StoreAccount, confirmExit: (StoreAccount) -> Bool) async {
        transition(.checking)
        do {
            let snapshot = try await inspect(activate: true)
            guard snapshot.state != .unknown else {
                transition(.needsInitialCheck(.init("guidance.initialCheck", defaultValue: "等 App Store 加载后，可以重新检查并继续。")))
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
            let password: String?
            do {
                password = try await savedPassword(for: account)
            } catch {
                guard snapshot.state == .signedIn else {
                    offerManualLogin(for: account)
                    return
                }
                transition(.confirmManualFallback)
                guard confirmManualFallback(account) else {
                    target = nil
                    transition(.cancelled)
                    return
                }
                choseManualLogin = true
                password = nil
            }
            if snapshot.state == .signedIn {
                transition(.signingOut)
                storeState = nil
                let afterExit = try await service.signOut(pid: snapshot.pid)
                storeState = afterExit
                guard afterExit == .signedOut else {
                    transition(.needsSignOut(.init("guidance.finishSignOut", defaultValue: "请处理 App Store 的退出提示，或手动退出后再继续。")))
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
            let snapshot = try await inspect(activate: true)
            guard snapshot.state == .signedOut else {
                transition(.needsSignOut(.init("guidance.signOutUnconfirmed", defaultValue: "尚未检测到退出。请在 App Store 检查退出状态后再继续。")))
                return
            }
            let password: String?
            do {
                password = try await savedPassword(for: target)
            } catch {
                offerManualLogin(for: target)
                return
            }
            await prepare(target, pid: snapshot.pid, openIfNeeded: true, password: password,
                          restoreFocus: password != nil)
        } catch {
            transition(.needsSignOut(message(for: error)))
        }
    }

    func retryLogin(openIfNeeded: Bool) async {
        guard let target, isWaitingForLogin else { return }
        if step == .needsManualLogin { updateManualLoginRecovery(nil) }
        stopMonitoringLogin()
        transition(.checking)
        do {
            let snapshot = try await inspect(activate: true)
            switch snapshot.state {
            case .signedIn:
                finishLogin()
            case .signedOut:
                await prepare(target, pid: snapshot.pid, openIfNeeded: openIfNeeded)
            case .unknown:
                transition(.needsSignIn(.init("guidance.openSignIn", defaultValue: "请打开 Apple 的登录表单，或在完成登录后检查状态。")))
                monitorLogin()
            }
        } catch {
            transition(.needsSignIn(message(for: error)))
            monitorLogin()
        }
    }

    var isWaitingForLogin: Bool {
        switch step {
        case .awaitingAuthentication, .needsSignIn, .needsManualLogin: return true
        default: return false
        }
    }

    @discardableResult
    func checkLogin() async -> LoginCheck {
        log(tr(.init("log.manualCheck", defaultValue: "手动检查 App Store 登录状态")))
        guard !step.isWorking else {
            let result = LoginCheck.unavailable(.init("error.busy", defaultValue: "正在处理 App Store，请稍后再试。"))
            log(tr(.init("log.checkResult", defaultValue: "检查结果 · \(tr(result.message))")))
            return result
        }
        let previous = step
        let pendingLogin = isWaitingForLogin
        transition(.verifying)
        let result: LoginCheck
        do {
            let snapshot = try await inspect(activate: false)
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
        log(tr(.init("log.checkResult", defaultValue: "检查结果 · \(tr(result.message))")))
        return result
    }

    func end() {
        guard !step.isWorking, !step.canSelect else { return }
        if step == .needsManualLogin { updateManualLoginRecovery(nil) }
        stopMonitoringLogin()
        target = nil
        transition(.cancelled)
    }

    private func savedPassword(for account: StoreAccount) async throws -> String? {
        guard !choseManualLogin, let id = account.passwordID else { return nil }
        transition(.readingKeychain)
        do {
            let password = try await service.readSavedPassword(id: id)
            log(tr(.init("log.keychainRead", defaultValue: "自动登录 · 已读取本机钥匙串")))
            return password
        } catch {
            log(tr(.init("log.keychainReadFailed", defaultValue: "自动登录 · 无法读取本机钥匙串")))
            throw error
        }
    }

    private func offerManualLogin(for account: StoreAccount) {
        transition(.needsManualLogin)
        monitorLogin()
        updateManualLoginRecovery(account)
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
        log(tr(.init("log.switchFinished", defaultValue: "检测到 App Store 已登录 · 本次切换结束")))
        transition(.idle)
        updateManualLoginRecovery(nil)
    }

    private func inspect(activate: Bool) async throws -> StoreSnapshot {
        storeState = nil
        checkError = nil
        do {
            let snapshot = try await service.inspect(activate: activate)
            storeState = snapshot.state
            return snapshot
        } catch {
            checkError = message(for: error)
            throw error
        }
    }

    private func transition(_ step: Step) {
        self.step = step
        log(tr(.init("log.state", defaultValue: "状态 · \(tr(step.title))")))
        if let guidance = step.guidance { log(tr(guidance)) }
    }

    private func message(for error: Error) -> LocalizedStringResource {
        (error as? StoreAutomationError)?.message ?? .init("error.operationFailed", defaultValue: "操作未能完成，请在 App Store 检查后重试。")
    }
}

import Foundation
import ApplicationServices

private final class MemoryPasswordItems: PasswordItemStoring {
    enum Failure: Error { case denied, writeFailed }

    var values: [PasswordItem: Data] = [:]
    var reads: [PasswordItem] = []
    var deniedItem: PasswordItem?
    var failWrite = false
    var failRemoval: PasswordItem?
    var writes = 0

    func read(_ item: PasswordItem) throws -> Data? {
        reads.append(item)
        if item == deniedItem { throw Failure.denied }
        return values[item]
    }

    func write(_ data: Data, to item: PasswordItem) throws {
        if failWrite { throw Failure.writeFailed }
        writes += 1
        values[item] = data
    }

    func remove(_ item: PasswordItem) throws {
        if item == failRemoval { throw Failure.denied }
        values.removeValue(forKey: item)
    }
}

@MainActor
private final class FakeStore: StoreAutomating {
    enum Call: Equatable {
        case inspect(activate: Bool)
        case observeLogin
        case signOut(pid_t)
        case readSavedPassword(UUID)
        case prepare(pid_t, String, openIfNeeded: Bool)
        case prepareAfterKeychain(pid_t, String, hasPassword: Bool, restoreFocus: Bool)
    }

    var calls: [Call] = []
    var snapshots: [StoreState]
    var afterSignOut: StoreState
    var preparation: LoginPreparation
    var inspectionError: StoreAutomationError?
    var observations: [StoreState] = []
    var passwordRead: (() async throws -> String)?

    init(_ snapshots: [StoreState], afterSignOut: StoreState = .signedOut,
         preparation: LoginPreparation = .filled) {
        self.snapshots = snapshots
        self.afterSignOut = afterSignOut
        self.preparation = preparation
    }

    func inspect(activate: Bool) async throws -> StoreSnapshot {
        calls.append(.inspect(activate: activate))
        if let inspectionError { throw inspectionError }
        return StoreSnapshot(pid: 42, state: snapshots.removeFirst())
    }

    func signOut(pid: pid_t) async throws -> StoreState {
        calls.append(.signOut(pid))
        return afterSignOut
    }

    func observeLogin() async throws -> StoreState {
        calls.append(.observeLogin)
        return observations.isEmpty ? .unknown : observations.removeFirst()
    }

    func readSavedPassword(id: UUID) async throws -> String {
        calls.append(.readSavedPassword(id))
        if let passwordRead { return try await passwordRead() }
        return "synthetic-test-password"
    }

    func prepareLogin(pid: pid_t, email: String, openIfNeeded: Bool, password: String?,
                      restoreFocus: Bool) async throws -> LoginPreparation {
        if password != nil || restoreFocus {
            calls.append(.prepareAfterKeychain(pid, email, hasPassword: password != nil, restoreFocus: restoreFocus))
        } else {
            calls.append(.prepare(pid, email, openIfNeeded: openIfNeeded))
        }
        return preparation
    }
}

@main
@MainActor
enum CoordinatorChecks {
    static func main() async {
        let account = StoreAccount(region: .turkey, email: "sample@example.com")
        let inspect = FakeStore.Call.inspect(activate: true)
        let prepare = FakeStore.Call.prepare(42, account.email, openIfNeeded: true)
        var passed = true

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            let result = condition()
            print("\(result ? "PASS" : "FAIL") · \(name)")
            passed = passed && result
        }

        do {
            let store = FakeStore([.signedIn])
            let flow = AccountSwitchCoordinator(service: store) { _ in }
            var confirmedTarget = false
            var automatic = account
            automatic.passwordID = UUID()
            await flow.start(automatic) { target in
                confirmedTarget = target == automatic && flow.step == .confirmExit && store.calls == [inspect]
                return false
            }
            check("cancelling confirmation never reads Keychain, signs out, or prepares login",
                  confirmedTarget && flow.step == .cancelled && store.calls == [inspect])
        }

        do {
            let store = FakeStore([.signedIn, .signedIn, .signedOut], afterSignOut: .signedIn)
            let flow = AccountSwitchCoordinator(service: store) { _ in }
            await flow.start(account) { _ in true }
            await flow.continueAfterSignOut()
            check("unsettled exit neither retries the exit nor opens login",
                  store.calls == [inspect, .signOut(42), inspect])
            await flow.continueAfterSignOut()
            check("observed exit resumes with the original target", store.calls == [inspect, .signOut(42), inspect, inspect, prepare])
        }

        do {
            let store = FakeStore([.unknown, .unknown, .signedOut])
            let flow = AccountSwitchCoordinator(service: store) { _ in }
            var asked = false
            await flow.start(account) { _ in asked = true; return true }
            await flow.checkLogin()
            let waiting: Bool
            if case .needsInitialCheck = flow.step { waiting = true } else { waiting = false }
            check("reading an ambiguous session keeps the switch pending without acting",
                  !asked && store.calls == [inspect, .inspect(activate: false)] && waiting && flow.storeState == .unknown)
            await flow.retryInitialCheck { _ in asked = true; return true }
            check("retry after menu loads proceeds directly to login when signed out",
                  !asked && flow.storeState == .signedOut && store.calls == [inspect, .inspect(activate: false), inspect, prepare])
        }

        do {
            let store = FakeStore([.signedOut, .signedOut, .signedIn], preparation: .writeUncertain)
            var log: [String] = []
            let flow = AccountSwitchCoordinator(service: store) { log.append($0) }
            var asked = false
            await flow.start(account) { _ in asked = true; return true }
            check("signed-out path skips exit; uncertain write waits for the user",
                  !asked && flow.step == .awaitingAuthentication(.writeUncertain) && store.calls == [inspect, prepare])
            await flow.start(StoreAccount(region: .china, email: "other@example.com")) { _ in true }
            await flow.retryLogin(openIfNeeded: false)
            check("second selection is blocked and retry only fills an existing form",
                  flow.target == account && store.calls == [inspect, prepare, inspect, .prepare(42, account.email, openIfNeeded: false)])
            let result = await flow.checkLogin()
            check("a manual check detects login and clears the pending switch",
                  result == .state(.signedIn) && store.calls.last == .inspect(activate: false)
                      && flow.step == .idle && flow.target == nil && !log.joined().contains(account.email))
        }

        do {
            let store = FakeStore([.signedIn])
            let flow = AccountSwitchCoordinator(service: store) { _ in }
            let result = await flow.checkLogin()
            check("standalone check reads the session without activating or mutating the store",
                  result == .state(.signedIn) && flow.storeState == .signedIn && flow.step == .idle && flow.target == nil
                      && store.calls == [.inspect(activate: false)])
        }

        do {
            let store = FakeStore([])
            store.inspectionError = .permission
            var log: [String] = []
            let flow = AccountSwitchCoordinator(service: store) { log.append($0) }
            let result = await flow.checkLogin()
            check("a failed manual check returns a reason and records the attempt and result",
                  result == .unavailable(StoreAutomationError.permission.message) && flow.step == .idle
                      && log.first?.contains("手动检查") == true && log.last?.contains("开启辅助功能") == true)
        }

        do {
            let store = FakeStore([.signedOut])
            store.observations = [.signedOut, .unknown, .signedIn]
            var showedRecovery = false
            let flow = AccountSwitchCoordinator(service: store, observationInterval: .milliseconds(10), updateManualLoginRecovery: {
                if $0 != nil { showedRecovery = true }
            }) { _ in }
            await flow.start(account) { _ in false }
            for _ in 0..<50 where !flow.step.canSelect {
                try? await Task.sleep(for: .milliseconds(10))
            }
            check("background checks wait for login and reset without showing a window",
                  store.calls == [inspect, prepare, .observeLogin, .observeLogin, .observeLogin]
                      && flow.step == .idle && flow.target == nil && flow.storeState == .signedIn
                      && !showedRecovery)
        }

        do {
            let store = FakeStore([.signedOut, .signedOut], preparation: .manual)
            let flow = AccountSwitchCoordinator(service: store) { _ in }
            await flow.start(account) { _ in false }
            await flow.retryLogin(openIfNeeded: true)
            check("explicit reopen retries login preparation without repeating sign-out",
                  flow.target == account && store.calls == [inspect, prepare, inspect, prepare])
        }

        do {
            let passwordID = UUID()
            let previous = Data("""
                {"region":"TR","name":"Test","email":"sample@example.com","passwordID":"\(passwordID.uuidString)"}
                """.utf8)
            let migrated = try? JSONDecoder().decode(StoreAccount.self, from: previous)
            let reloaded = migrated.flatMap { entry in
                (try? JSONEncoder().encode(entry)).flatMap { try? JSONDecoder().decode(StoreAccount.self, from: $0) }
            }
            check("existing accounts preserve their region and password reference and gain a stable ID",
                  migrated?.email == account.email && migrated?.region == .turkey && migrated?.passwordID == passwordID
                      && reloaded == migrated)
            let accounts = [StoreAccount(email: "a@example.com"), StoreAccount(email: "b@example.com")]
            check("new accounts can share an unspecified region while retaining independent identities",
                  accounts[0].id != accounts[1].id && accounts.allSatisfy { $0.region == .unspecified }
                      && AppLanguage.allCases.allSatisfy { StoreRegion.choices(in: $0).contains(StoreRegion(rawValue: "JP")) })
        }

        do {
            var automatic = account
            let passwordID = UUID()
            automatic.passwordID = passwordID
            let store = FakeStore([.signedIn, .signedOut], preparation: .submissionUncertain)
            let flow = AccountSwitchCoordinator(service: store) { _ in }
            await flow.start(automatic) { _ in true }
            check("opted-in login reads Keychain before sign-out and waits for confirmed sign-out before submitting",
                  flow.step == .awaitingAuthentication(.submissionUncertain)
                      && store.calls == [inspect, .readSavedPassword(passwordID), .signOut(42),
                                         .prepareAfterKeychain(42, account.email, hasPassword: true, restoreFocus: false)])
            await flow.retryLogin(openIfNeeded: true)
            check("recovery after an uncertain submission never resends the password",
                  store.calls.suffix(2).elementsEqual([inspect, prepare]))
        }

        do {
            let passwordID = UUID()
            var automatic = account
            automatic.passwordID = passwordID
            let store = FakeStore([.signedOut], preparation: .submitted)
            var approval: CheckedContinuation<String, Error>?
            store.passwordRead = {
                try await withCheckedThrowingContinuation { approval = $0 }
            }
            let flow = AccountSwitchCoordinator(service: store) { _ in }
            let switching = Task { await flow.start(automatic) { _ in false } }
            for _ in 0..<50 where approval == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
            check("while system approval is pending the sign-in form is not opened",
                  approval != nil && flow.step == .readingKeychain && store.calls == [inspect, .readSavedPassword(passwordID)])
            approval?.resume(returning: "synthetic-approved-password")
            await switching.value
            check("one approval restores App Store focus and proceeds with the saved password",
                  flow.step == .awaitingAuthentication(.submitted)
                      && store.calls == [inspect, .readSavedPassword(passwordID),
                                         .prepareAfterKeychain(42, account.email, hasPassword: true, restoreFocus: true)])
        }

        do {
            let passwordID = UUID()
            var automatic = account
            automatic.passwordID = passwordID
            let store = FakeStore([.signedIn])
            store.passwordRead = { throw StoreAutomationError.permission }
            var promptedFor: StoreAccount?
            let flow = AccountSwitchCoordinator(service: store, confirmManualFallback: {
                promptedFor = $0
                return false
            }) { _ in }
            await flow.start(automatic) { _ in true }
            check("cancelling manual fallback preserves the signed-in session",
                  promptedFor == automatic && flow.step == .cancelled && flow.target == nil
                      && flow.storeState == .signedIn && store.calls == [inspect, .readSavedPassword(passwordID)])
        }

        do {
            let passwordID = UUID()
            var automatic = account
            automatic.passwordID = passwordID
            let store = FakeStore([.signedIn, .signedOut], afterSignOut: .unknown)
            store.passwordRead = { throw StoreAutomationError.permission }
            var choices = 0
            let flow = AccountSwitchCoordinator(service: store, confirmManualFallback: { _ in
                choices += 1
                return true
            }) { _ in }
            await flow.start(automatic) { _ in true }
            await flow.continueAfterSignOut()
            check("accepting manual fallback signs out once and does not retry the saved password",
                  choices == 1 && flow.step == .awaitingAuthentication(.filled)
                      && store.calls == [inspect, .readSavedPassword(passwordID), .signOut(42), inspect, prepare])
        }

        do {
            let passwordID = UUID()
            var automatic = account
            automatic.passwordID = passwordID
            let store = FakeStore([.signedOut, .signedOut, .signedIn])
            store.passwordRead = { throw StoreAutomationError.permission }
            var manualTarget: StoreAccount?
            let flow = AccountSwitchCoordinator(service: store, updateManualLoginRecovery: { manualTarget = $0 }) { _ in }
            await flow.start(automatic) { _ in false }
            check("when signed out, denied Keychain access offers manual recovery before opening a form",
                  manualTarget == automatic && flow.step == .needsManualLogin && flow.isWaitingForLogin
                      && store.calls == [inspect, .readSavedPassword(passwordID)])
            await flow.retryLogin(openIfNeeded: true)
            check("opening the login window explicitly only attempts to fill the email",
                  manualTarget == nil && flow.step == .awaitingAuthentication(.filled)
                      && store.calls == [inspect, .readSavedPassword(passwordID), inspect, prepare])
            await flow.retryLogin(openIfNeeded: true)
            check("reopen after signing in quietly clears the pending switch without further writes",
                  flow.step == .idle && flow.target == nil && manualTarget == nil
                      && store.calls == [inspect, .readSavedPassword(passwordID), inspect, prepare, inspect])
        }

        do {
            let passwordID = UUID()
            var automatic = account
            automatic.passwordID = passwordID
            let store = FakeStore([.signedIn, .signedOut], afterSignOut: .unknown)
            let flow = AccountSwitchCoordinator(service: store) { _ in }
            await flow.start(automatic) { _ in true }
            store.passwordRead = { throw StoreAutomationError.permission }
            await flow.continueAfterSignOut()
            check("a failed password read after sign-out offers manual recovery",
                  flow.step == .needsManualLogin && flow.target == automatic
                      && store.calls == [inspect, .readSavedPassword(passwordID), .signOut(42),
                                         inspect, .readSavedPassword(passwordID)])
        }

        do {
            check("authentication only accepts known secure password controls",
                  acceptsPasswordField(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, labels: ["密码"])
                      && !acceptsPasswordField(role: kAXTextFieldRole, subrole: nil, labels: ["Password"])
                      && !acceptsPasswordField(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, labels: ["Verification Code"]))
            check("native form classification accepts both layouts and rejects mixed verification controls",
                  NativeLoginStage(inSheet: true, complete: true, emailFields: 1, passwordFields: 0, otherInputs: 0) == .email
                      && NativeLoginStage(inSheet: true, complete: true, emailFields: 1, passwordFields: 1, otherInputs: 0) == .emailAndPassword
                      && NativeLoginStage(inSheet: true, complete: true, emailFields: 0, passwordFields: 1, otherInputs: 0) == .password
                      && NativeLoginStage(inSheet: true, complete: true, emailFields: 0, passwordFields: 1, otherInputs: 1) == nil
                      && NativeLoginStage(inSheet: false, complete: true, emailFields: 0, passwordFields: 1, otherInputs: 0) == nil)
        }

        do {
            let store = FakeStore([])
            store.inspectionError = .permission
            let flow = AccountSwitchCoordinator(service: store) { _ in }
            await flow.start(account) { _ in true }
            check("missing permission surfaces recovery without any writes",
                  flow.step == .needsInitialCheck(StoreAutomationError.permission.message) && store.calls == [inspect])
        }

        do {
            let first = UUID()
            let second = UUID()
            let items = MemoryPasswordItems()
            let keychain = PasswordKeychain(items: items)
            try! keychain.updateVault(setting: [first: "first-test-password", second: "second-test-password"], removing: [])
            items.reads = []
            let firstRead = try! keychain.read(first)
            let secondRead = try! keychain.read(second)
            check("switching between accounts reads one shared Keychain item",
                  Set(items.values.keys) == [.vault] && items.writes == 1 && items.reads == [.vault, .vault]
                      && firstRead.password == "first-test-password" && secondRead.password == "second-test-password")
        }

        do {
            let id = UUID()
            let items = MemoryPasswordItems()
            let legacy = Data("legacy-test-password".utf8)
            items.values[.legacy(id)] = legacy
            let keychain = PasswordKeychain(items: items)
            items.failWrite = true
            let fallback = try! keychain.read(id)
            check("failed migration keeps the old password usable and intact",
                  fallback.migrationPending && items.values[.legacy(id)] == legacy && items.values[.vault] == nil)
            items.failWrite = false
            _ = try! keychain.read(id)
            items.reads = []
            let migrated = try! keychain.read(id)
            check("legacy password is imported once, then read from the shared item",
                  migrated.password == "legacy-test-password" && !migrated.migrationPending && items.reads == [.vault])
            items.deniedItem = .vault
            items.reads = []
            let denied = try? keychain.read(id)
            check("denying vault access does not trigger a second prompt for the old entry",
                  denied == nil && items.reads == [.vault])
            items.deniedItem = nil
            try! keychain.updateVault(setting: [:], removing: [id])
            let cleanup = keychain.removeLegacyCopies([id])
            let removed = try? keychain.read(id)
            check("removing a migrated password clears both copies and keeps the shared item",
                  removed == nil && cleanup.isEmpty && items.values[.vault] != nil && items.values[.legacy(id)] == nil)
        }

        do {
            let first = UUID()
            let second = UUID()
            let items = MemoryPasswordItems()
            let keychain = PasswordKeychain(items: items)
            try! keychain.updateVault(setting: [first: "old-test-password"], removing: [])
            items.values[.legacy(first)] = Data("legacy-first".utf8)
            let previous = items.values
            items.failWrite = true
            let result: Void? = try? keychain.updateVault(setting: [second: "new-test-password"], removing: [first])
            check("failed vault commit leaves both the vault and legacy passwords unchanged",
                  result == nil && items.values == previous)
            items.failWrite = false
            items.failRemoval = .legacy(first)
            try! keychain.updateVault(setting: [second: "new-test-password"], removing: [first])
            let cleanup = keychain.removeLegacyCopies([first, second])
            let updated = try! keychain.read(second)
            check("legacy cleanup failures identify the affected password after the vault commits",
                  Set(cleanup.keys) == [first] && updated.password == "new-test-password" && items.writes == 2)
            items.failRemoval = nil
            let retried = keychain.removeLegacyCopies(Set(cleanup.keys))
            let removed = try? keychain.read(first)
            check("legacy cleanup can be retried without rewriting the vault",
                  retried.isEmpty && removed == nil && items.writes == 2)
        }

        exit(passed ? 0 : 1)
    }
}

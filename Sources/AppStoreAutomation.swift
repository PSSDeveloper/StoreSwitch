import AppKit
import ApplicationServices

@MainActor
final class AppStoreAutomation: StoreAutomating {
    private let worker = DispatchQueue(label: "local.storeswitch.ax")
    private let log: ([String]) -> Void

    init(log: @escaping ([String]) -> Void) {
        self.log = log
    }

    func inspect(open: Bool) async throws -> StoreSnapshot {
        try requirePermission()
        let pid: pid_t
        if open {
            pid = try await openStore().processIdentifier
        } else {
            pid = try runningStorePID()
        }
        let state = await scan(pid: pid) { $0.sessionState() }
        return StoreSnapshot(pid: pid, state: state)
    }

    func observeLogin() async throws -> StoreState {
        try requirePermission()
        return await scan(pid: try runningStorePID(), report: false) { $0.sessionState(waitForMenu: false) }
    }

    private func runningStorePID() throws -> pid_t {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: storeBundleID).filter(isSystemStore)
        guard running.count == 1, let store = running.first else { throw StoreAutomationError.unavailable }
        return store.processIdentifier
    }

    func signOut(pid: pid_t) async throws -> StoreState {
        try await activate(pid: pid)
        return await scan(pid: pid) { $0.signOutForSwitch() }
    }

    func readSavedPassword(id: UUID) async throws -> String {
        // SecItemCopyMatching can wait for the system authorization dialog.
        let result: PasswordKeychain.ReadResult = try await withCheckedThrowingContinuation { continuation in
            worker.async {
                continuation.resume(with: Result { try PasswordKeychain().read(id) })
            }
        }
        if result.migrationPending {
            log(["钥匙串 · 旧密码可用，合并保存暂未完成"])
        }
        return result.password
    }

    func prepareLogin(pid: pid_t, email: String, openIfNeeded: Bool, password: String?,
                      restoreFocus: Bool) async throws -> LoginPreparation {
        try requirePermission()
        guard let app = NSRunningApplication(processIdentifier: pid), isSystemStore(app) else {
            throw StoreAutomationError.processChanged
        }
        if restoreFocus && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            // The Keychain dialog may have taken focus before the login form was opened.
            try await activate(pid: pid)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw StoreAutomationError.notFrontmost
        }
        return await scan(pid: pid) {
            $0.prepareLogin(email: email, openIfNeeded: openIfNeeded, password: password)
        }
    }

    func openStore() async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let app = try? await NSWorkspace.shared.openApplication(at: storeURL, configuration: config),
              isSystemStore(app) else {
            log(["无法打开系统 App Store"])
            throw StoreAutomationError.unavailable
        }
        for _ in 0..<16 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return app }
            if app.isTerminated { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        log(["App Store 未成为前台"])
        throw StoreAutomationError.notFrontmost
    }

    private func activate(pid: pid_t) async throws {
        try requirePermission()
        guard let app = NSRunningApplication(processIdentifier: pid), isSystemStore(app) else {
            throw StoreAutomationError.processChanged
        }
        guard try await openStore().processIdentifier == pid else { throw StoreAutomationError.processChanged }
    }

    private func requirePermission() throws {
        guard AXIsProcessTrusted() else { throw StoreAutomationError.permission }
    }

    private func scan<T>(pid: pid_t, report: Bool = true, _ operation: @escaping (StoreAX) -> T) async -> T {
        let (result, lines): (T, [String]) = await withCheckedContinuation { continuation in
            worker.async {
                var lines: [String] = []
                let store = StoreAX(pid: pid) { if report { lines.append($0) } }
                let result = operation(store)
                if report { store.reportFaults() }
                continuation.resume(returning: (result, lines))
            }
        }
        if report { log(lines) }
        return result
    }
}

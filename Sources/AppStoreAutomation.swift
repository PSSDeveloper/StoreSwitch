import AppKit
import ApplicationServices

@MainActor
final class AppStoreAutomation: StoreAutomating {
    private let worker = DispatchQueue(label: "com.gavzen.storeswitch.ax")
    private let log: ([String]) -> Void

    init(log: @escaping ([String]) -> Void) {
        self.log = log
    }

    func inspect(activate: Bool) async throws -> StoreSnapshot {
        try requirePermission()
        let app: NSRunningApplication
        if activate {
            app = try await openStore()
        } else if let running = try runningStore() {
            app = running
        } else {
            app = try await launchStore(activate: false)
        }
        let pid = app.processIdentifier
        let state = await scan(pid: pid) { $0.sessionState() }
        return StoreSnapshot(pid: pid, state: state)
    }

    func observeLogin() async throws -> StoreState {
        try requirePermission()
        guard let app = try runningStore() else { throw StoreAutomationError.unavailable }
        return await scan(pid: app.processIdentifier, report: false) { $0.sessionState(waitForMenu: false) }
    }

    private func runningStore() throws -> NSRunningApplication? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: storeBundleID).filter(isSystemStore)
        guard running.count <= 1 else { throw StoreAutomationError.unavailable }
        return running.first
    }

    func signOut(pid: pid_t) async throws -> StoreState {
        try await activate(pid: pid)
        return await scan(pid: pid) { $0.signOutForSwitch() }
    }

    func readSavedPassword(id: UUID) async throws -> String {
        // SecItemCopyMatching can wait for the system authorization dialog.
        do {
            return try await withCheckedThrowingContinuation { continuation in
                worker.async {
                    continuation.resume(with: Result { try PasswordKeychain().read(id) })
                }
            }
        } catch let failure as KeychainFailure {
            log([failure.logMessage])
            throw failure
        }
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
        let app = try await launchStore(activate: true)
        for _ in 0..<16 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return app }
            if app.isTerminated { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        log([tr(.init("log.storeNotFrontmost", defaultValue: "App Store 未成为前台"))])
        throw StoreAutomationError.notFrontmost
    }

    private func launchStore(activate: Bool) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        guard let app = try? await NSWorkspace.shared.openApplication(at: storeURL, configuration: config),
              isSystemStore(app) else {
            log([tr(.init("log.storeLaunchFailed", defaultValue: "无法打开系统 App Store"))])
            throw StoreAutomationError.unavailable
        }
        return app
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

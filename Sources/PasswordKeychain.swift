import Foundation
import Security

protocol PasswordVaultStoring {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

struct PasswordKeychain {
    private static let lock = NSLock()
    private let storage: any PasswordVaultStoring

    init(storage: any PasswordVaultStoring = LocalPasswordVault()) {
        self.storage = storage
    }

    func read(_ id: UUID) throws -> String {
        try Self.lock.withLock {
            let vault = try readVault()
            guard let password = vault[id.uuidString] else {
                throw KeychainFailure(operation: tr(.init("keychain.operation.findPassword", defaultValue: "查找账号密码")), status: errSecItemNotFound)
            }
            return password
        }
    }

    func updateVault(setting: [UUID: String], removing: Set<UUID>) throws {
        guard !setting.isEmpty || !removing.isEmpty else { return }
        try Self.lock.withLock {
            var vault = try readVault()
            let original = vault
            for id in removing { vault.removeValue(forKey: id.uuidString) }
            for (id, password) in setting { vault[id.uuidString] = password }
            if vault != original {
                // Commit the entire active vault in one update, preserving its ACL.
                try writeVault(vault)
            }
        }
    }

    private func readVault() throws -> [String: String] {
        guard let data = try storage.read() else { return [:] }
        guard let vault = try? JSONDecoder().decode([String: String].self, from: data),
              vault.values.allSatisfy({ !$0.isEmpty }) else {
            throw KeychainFailure(operation: tr(.init("keychain.operation.decodeVault", defaultValue: "解码密码库")), status: errSecDecode)
        }
        return vault
    }

    private func writeVault(_ vault: [String: String]) throws {
        try storage.write(JSONEncoder().encode(vault))
    }
}

struct KeychainFailure: Error {
    let operation: String
    let status: OSStatus

    var logMessage: String { tr(.init("log.keychainOperationFailed", defaultValue: "钥匙串 · \(operation)失败（\(status)）")) }

    var userMessage: String {
        switch status {
        case errSecUserCanceled:
            return tr(.init("keychain.authCancelled", defaultValue: "已取消系统钥匙串授权。重试时请在 macOS 提示中确认。"))
        case errSecAuthFailed, errSecInteractionNotAllowed:
            return tr(.init("keychain.authDenied", defaultValue: "macOS 未授权此次操作。请确认登录钥匙串已解锁，并在系统提示中允许 StoreSwitch 访问。"))
        case errSecNoDefaultKeychain, errSecNotAvailable:
            return tr(.init("keychain.unavailable", defaultValue: "macOS 无法访问默认钥匙串。请在「钥匙串访问」中确认登录钥匙串可用后重试。"))
        case errSecDecode:
            return tr(.init("keychain.decodeFailed", defaultValue: "无法读取钥匙串中的密码记录。请重新打开 StoreSwitch 后重试。"))
        default:
            return tr(.init("keychain.operationFailed", defaultValue: "钥匙串操作失败。请确认登录钥匙串已解锁，再重试。"))
        }
    }
}

struct LocalPasswordVault: PasswordVaultStoring {
    private let query: [String: Any]

    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.gavzen.storeswitch"
        // Use the local, file-based macOS keychain and its default app ACL.
        query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: bundleID + ".app-store-password.vault",
            kSecAttrAccount as String: "accounts-v1"
        ]
    }

    private static func checkForRebuild() throws {
        var runningCode: SecCode?
        guard SecCodeCopySelf([], &runningCode) == errSecSuccess, let runningCode else { return }
        let status = SecCodeCheckValidity(runningCode, [], nil)
        // Compare the running process with its current on-disk bundle. A rebuild
        // can replace it without exiting the process that macOS is authorizing.
        if status == errSecCSStaticCodeChanged {
            throw KeychainFailure(operation: tr(.init("keychain.operation.checkSignature", defaultValue: "检查正在运行的应用签名")), status: status)
        }
    }

    func read() throws -> Data? {
        try Self.checkForRebuild()
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try Self.check(status, operation: tr(.init("keychain.operation.readRecord", defaultValue: "读取密码记录")))
        guard let data = result as? Data else {
            throw KeychainFailure(operation: tr(.init("keychain.operation.readData", defaultValue: "读取密码数据")), status: errSecDecode)
        }
        return data
    }

    func write(_ data: Data) throws {
        try Self.checkForRebuild()
        var request = query
        let secret = [kSecValueData as String: data]
        let updated = SecItemUpdate(request as CFDictionary, secret as CFDictionary)
        if updated == errSecItemNotFound {
            request[kSecValueData as String] = data
            try Self.check(SecItemAdd(request as CFDictionary, nil), operation: tr(.init("keychain.operation.add", defaultValue: "新增密码记录")))
        } else {
            try Self.check(updated, operation: tr(.init("keychain.operation.update", defaultValue: "更新密码记录")))
        }
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status != errSecSuccess else { return }
        // The bundle may also have been replaced between the preflight and SecItem.
        try checkForRebuild()
        throw KeychainFailure(operation: operation, status: status)
    }
}

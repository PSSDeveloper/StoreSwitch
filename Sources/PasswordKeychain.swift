import Foundation
import Security

enum PasswordItem: Hashable {
    case vault
    case legacy(UUID)
}

protocol PasswordItemStoring {
    func read(_ item: PasswordItem) throws -> Data?
    func write(_ data: Data, to item: PasswordItem) throws
    func remove(_ item: PasswordItem) throws
}

struct PasswordKeychain {
    struct ReadResult {
        let password: String
        let migrationPending: Bool
    }

    private static let lock = NSLock()
    private let items: any PasswordItemStoring

    init(items: any PasswordItemStoring = LocalPasswordItems()) {
        self.items = items
    }

    func save(_ password: String, id: UUID) throws {
        try Self.lock.withLock {
            var vault = try readVault()
            vault[id.uuidString] = password
            try writeVault(vault)
            // A replaced legacy password is no longer needed. The new value is
            // already durable, and an explicit removal will try both entries.
            try? items.remove(.legacy(id))
        }
    }

    func read(_ id: UUID) throws -> ReadResult {
        try Self.lock.withLock {
            var vault = try readVault()
            if let password = vault[id.uuidString] {
                return ReadResult(password: password, migrationPending: false)
            }
            guard let data = try items.read(.legacy(id)) else {
                throw KeychainFailure(status: errSecItemNotFound)
            }
            guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                throw KeychainFailure(status: errSecDecode)
            }
            vault[id.uuidString] = password
            do {
                try writeVault(vault)
            } catch {
                // The system already authorized this legacy read. Keep using it
                // for this attempt if storing the migrated copy fails.
                return ReadResult(password: password, migrationPending: true)
            }
            // Don't request another operation on the old item during sign-in.
            // An explicit password replacement or removal cleans up that item.
            return ReadResult(password: password, migrationPending: false)
        }
    }

    func remove(_ id: UUID) throws {
        try Self.lock.withLock {
            var vault = try readVault()
            // Remove the fallback first so a deleted password cannot reappear.
            try items.remove(.legacy(id))
            if vault.removeValue(forKey: id.uuidString) != nil {
                // Keep the same item (even when empty) so it keeps its ACL.
                try writeVault(vault)
            }
        }
    }

    private func readVault() throws -> [String: String] {
        guard let data = try items.read(.vault) else { return [:] }
        let vault = try JSONDecoder().decode([String: String].self, from: data)
        guard vault.values.allSatisfy({ !$0.isEmpty }) else { throw KeychainFailure(status: errSecDecode) }
        return vault
    }

    private func writeVault(_ vault: [String: String]) throws {
        try items.write(JSONEncoder().encode(vault), to: .vault)
    }
}

private struct KeychainFailure: Error {
    let status: OSStatus
}

struct LocalPasswordItems: PasswordItemStoring {
    let service: String

    init(service: String? = nil) {
        let bundleID = Bundle.main.bundleIdentifier ?? "local.storeswitch"
        self.service = service ?? bundleID + ".app-store-password"
    }

    private func query(_ item: PasswordItem) -> [String: Any] {
        // Use the local, file-based macOS keychain and its default app ACL.
        // The vault has its own item so macOS grants access to it as a unit.
        let account: String
        let itemService: String
        switch item {
        case .vault:
            account = "accounts-v1"
            itemService = service + ".vault"
        case .legacy(let id):
            account = id.uuidString
            itemService = service
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: itemService,
            kSecAttrAccount as String: account
        ]
    }

    func read(_ item: PasswordItem) throws -> Data? {
        var request = query(item)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data else { throw KeychainFailure(status: errSecDecode) }
        return data
    }

    func write(_ data: Data, to item: PasswordItem) throws {
        var request = query(item)
        let secret = [kSecValueData as String: data]
        let updated = SecItemUpdate(request as CFDictionary, secret as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainFailure(status: updated) }
        request[kSecValueData as String] = data
        let added = SecItemAdd(request as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainFailure(status: added) }
    }

    func remove(_ item: PasswordItem) throws {
        let status = SecItemDelete(query(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }
}

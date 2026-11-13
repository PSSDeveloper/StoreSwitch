import Combine
import Foundation

final class AccountDrafts: ObservableObject {
    private enum PasswordEdit {
        case set(email: String, password: String)
        case remove
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
    @Published private var clearedPasswordDrafts = Set<UUID>()
    private var saved: [StoreAccount]
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

    func discardPasswordEdits() {
        passwordEdits.removeAll()
        clearedPasswordDrafts.removeAll()
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalized: [StoreAccount] {
        let trimmed = entries.map { entry in
            var normalized = entry
            normalized.email = normalizedEmail(entry.email)
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
        let email = normalizedEmail(entry.email)
        return saved.first { $0.id == entry.id && $0.email == email }
    }

    func setEmail(_ email: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // Clear the password immediately so changing the email back cannot restore it.
        if case .set(let draftEmail, _) = passwordEdits[id], draftEmail != normalizedEmail(email) {
            passwordEdits[id] = nil
            clearedPasswordDrafts.insert(id)
        }
        entries[index].email = email
    }

    func canEditPassword(for entry: StoreAccount) -> Bool {
        let email = normalizedEmail(entry.email)
        guard StoreAccount.validEmail(email) else { return false }
        return !entries.contains { $0.id != entry.id && normalizedEmail($0.email).lowercased() == email.lowercased() }
    }

    private func passwordEdit(for entry: StoreAccount) -> PasswordEdit? {
        let edit = passwordEdits[entry.id]
        // Recheck the email when creating the save plan, even though the editor clears stale drafts.
        if case .set(let email, _) = edit, email != normalizedEmail(entry.email) { return nil }
        return edit
    }

    func passwordEnabled(for entry: StoreAccount) -> Bool {
        switch passwordEdit(for: entry) {
        case .set: return true
        case .remove: return false
        case nil: return matchingSavedAccount(for: entry)?.passwordID != nil
        }
    }

    func passwordDraft(for entry: StoreAccount) -> String {
        if case .set(_, let password) = passwordEdit(for: entry) { return password }
        return ""
    }

    func passwordDraftWasCleared(for id: UUID) -> Bool {
        clearedPasswordDrafts.contains(id)
    }

    func setPassword(_ password: String, for entry: StoreAccount) {
        let email = normalizedEmail(entry.email)
        guard let current = entries.first(where: { $0.id == entry.id }),
              normalizedEmail(current.email) == email, canEditPassword(for: current) else { return }
        if password.isEmpty {
            // A blank field cancels the draft password. Removal uses its own explicit action.
            if case .set = passwordEdits[entry.id] { passwordEdits[entry.id] = nil }
        } else {
            passwordEdits[entry.id] = .set(email: email, password: password)
            clearedPasswordDrafts.remove(entry.id)
        }
    }

    func removePassword(for id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        passwordEdits[id] = matchingSavedAccount(for: entry)?.passwordID == nil ? nil : .remove
        clearedPasswordDrafts.remove(id)
    }

    func delete(_ id: UUID) {
        passwordEdits[id] = nil
        clearedPasswordDrafts.remove(id)
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
            switch passwordEdit(for: entry) {
            case .set(_, let password):
                let id = original?.passwordID ?? UUID()
                update.passwordID = id
                setting[id] = password
                affected[id] = update
            case .remove:
                update.passwordID = nil
            case nil:
                break
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

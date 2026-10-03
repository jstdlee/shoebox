import Foundation
import Security
import ShoeboxCore

/// Settings in App Group UserDefaults, access keys in the shared Keychain
/// group, so the upload extension sees exactly what the app saved.
struct SettingsRepository {
    private static let settingsKey = "settings.v1"
    private static let service = "shoebox.s3"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: AppEnvironment.appGroup)!
    }

    func loadSettings() -> BackupSettings {
        guard let data = defaults.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode(BackupSettings.self, from: data) else {
            return BackupSettings()
        }
        return settings
    }

    func saveSettings(_ settings: BackupSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
    }

    func loadCredentials() -> S3Credentials? {
        guard let id = read("accessKeyID"), let secret = read("secretAccessKey") else { return nil }
        return S3Credentials(accessKeyID: id, secretAccessKey: secret)
    }

    func saveCredentials(_ credentials: S3Credentials) throws {
        try write("accessKeyID", credentials.accessKeyID)
        try write("secretAccessKey", credentials.secretAccessKey)
    }

    // MARK: Keychain

    private func baseQuery(_ account: String, shared: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if shared { query[kSecAttrAccessGroup as String] = AppEnvironment.keychainGroup }
        return query
    }

    private func read(_ account: String) -> String? {
        for shared in [true, false] {
            var query = baseQuery(account, shared: shared)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    private func write(_ account: String, _ value: String) throws {
        do {
            try write(account, value, shared: true)
        } catch let error as NSError where error.code == Int(errSecMissingEntitlement) {
            // Unsigned Simulator build: no shared Keychain group available.
            try write(account, value, shared: false)
        }
    }

    private func write(_ account: String, _ value: String, shared: Bool) throws {
        let data = Data(value.utf8)
        // The extension runs in the background, possibly while the phone is
        // locked, so the item must be readable after first unlock.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery(account, shared: shared) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account, shared: shared)
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain error \(status)"])
        }
    }
}

import Foundation
import Security

struct KeychainStore: SecretStoreProtocol {
    private let service = "com.homecontrol.mac.credentials"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(_ account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw error(status) }
        return value
    }
    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(account)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(request as CFDictionary, nil)
            guard result == errSecSuccess else { throw error(result) }
        } else if status != errSecSuccess { throw error(status) }
    }
    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    private func error(_ status: OSStatus) -> ControlError {
        .message(String(localized: "Keychain operation failed.") + " (\(status))")
    }
}
struct FileConfigurationStore: ConfigurationStoreProtocol {
    var url: URL {
        URL.applicationSupportDirectory.appending(path: "HomeControl/configuration.json")
    }
    func load() throws -> SavedConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedConfiguration() }
        return try JSONDecoder().decode(SavedConfiguration.self, from: Data(contentsOf: url))
    }
    func save(_ configuration: SavedConfiguration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(configuration).write(to: url, options: .atomic)
    }
}

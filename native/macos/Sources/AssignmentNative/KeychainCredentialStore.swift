import Foundation
import Security


final class KeychainCredentialStore: @unchecked Sendable {
    private let servicePrefix = "com.assignmentnative.web"

    func save(url: URL, username: String, password: String) throws {
        let origin = try CredentialOrigin.value(for: url)
        let service = serviceName(origin: origin)
        try? remove(origin: origin)

        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: username,
            kSecAttrLabel: "Assignment Native · \(origin)",
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(password.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }
    }

    func retrieve(url: URL) throws -> StoredCredential? {
        let origin = try CredentialOrigin.value(for: url)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName(origin: origin),
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnAttributes: true,
            kSecReturnData: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let dictionary = result as? [CFString: Any],
              let username = dictionary[kSecAttrAccount] as? String,
              let data = dictionary[kSecValueData] as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.keychain(status)
        }

        return StoredCredential(
            origin: origin,
            username: username,
            password: password
        )
    }

    func remove(url: URL) throws {
        try remove(origin: CredentialOrigin.value(for: url))
    }

    private func remove(origin: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName(origin: origin),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func serviceName(origin: String) -> String {
        "\(servicePrefix).\(origin)"
    }
}

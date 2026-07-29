//
//  ClaudeAPIKeyStore.swift
//  ArchiverLib
//

import Foundation
import Security

/// Stores the Anthropic API key in the Keychain
///
/// The key must never be persisted in `UserDefaults` or synced via iCloud.
enum ClaudeAPIKeyStore {
    private static let service = "de.JulianKahnert.PDFArchiveViewer.claude-api-key"
    private static let account = "anthropic"

    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    static func set(_ apiKey: String?) {
        guard let apiKey,
              !apiKey.isEmpty,
              let data = apiKey.data(using: .utf8) else {
            delete()
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if get() == nil {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        } else {
            let attributes: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

//
//  ClaudeAPIKeyStore.swift
//  ArchiverLib
//

import ArchiverModels
import Foundation
import OSLog
import Security

/// Stores the Anthropic API key in the Keychain
///
/// The key must never be persisted in `UserDefaults` or synced via iCloud.
/// Items are stored in the data protection keychain; development builds without
/// an application identifier (e.g. ad-hoc signed) fall back to the legacy
/// file-based keychain on macOS.
enum ClaudeAPIKeyStore {
    private static let service = "de.JulianKahnert.PDFArchiveViewer.claude-api-key"
    private static let account = "anthropic"

    static func get() -> String? {
        // Search the data protection keychain first, then the legacy fallback
        for useDataProtection in [true, false] {
            var query = baseQuery(useDataProtection: useDataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess,
               let data = item as? Data,
               let key = String(data: data, encoding: .utf8) {
                return key
            }
        }
        return nil
    }

    @discardableResult
    static func set(_ apiKey: String?) -> Bool {
        guard let apiKey,
              !apiKey.isEmpty,
              let data = apiKey.data(using: .utf8) else {
            delete()
            return true
        }

        // Remove existing entries from both keychains to avoid divergence
        delete()

        var status = add(data, useDataProtection: true)
        if status == errSecMissingEntitlement {
            // No application identifier (e.g. unsigned development build) - use the legacy keychain
            status = add(data, useDataProtection: false)
        }

        guard status == errSecSuccess else {
            Logger.claudeExtractor.error("Failed to store the API key in the Keychain", metadata: ["status": "\(status)"])
            return false
        }
        return true
    }

    static func delete() {
        for useDataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(useDataProtection: useDataProtection) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound && status != errSecMissingEntitlement {
                Logger.claudeExtractor.error("Failed to delete the API key from the Keychain", metadata: ["status": "\(status)"])
            }
        }
    }

    private static func add(_ data: Data, useDataProtection: Bool) -> OSStatus {
        var query = baseQuery(useDataProtection: useDataProtection)
        query[kSecValueData as String] = data
        if useDataProtection {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    private static func baseQuery(useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

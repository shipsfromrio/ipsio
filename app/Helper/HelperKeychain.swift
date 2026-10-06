// HelperKeychain.swift: the user's Anthropic key, in the macOS Keychain only
// (a generic password, this app's service). Never in the conf, never logged.
import Foundation
import Security

enum HelperKeychain {
    static let service = "io.github.shipsfromrio.ipsio.helper"
    static let account = "anthropic"

    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = base()
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    static var hasKey: Bool { read() != nil }

    /// A key looks like "sk-ant-..." with no spaces.
    static func plausible(_ k: String) -> Bool {
        k.hasPrefix("sk-ant-") && k.count >= 20 && !k.contains(where: { $0.isWhitespace })
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plausible(k) else { return false }
        let data = Data(k.utf8)
        let upd = SecItemUpdate(base() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if upd == errSecSuccess { return true }
        var add = base()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(base() as CFDictionary) }
}

//
//  OttaiKeychain.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
import Security

public enum OttaiKeychain {
    // Deployed before the split: the Ottai manager used SyaiKit's keychain
    // service with a plugin-namespaced account key. Changing either string
    // would orphan the existing session and install identity, so they are
    // preserved verbatim even though the module is now OttaiKit.
    private static let service = "org.loopkit.SyaiKit"
    private static let accountSessionKey = "syai.account.session"
    private static let installDeviceIdKey = "syai.install.deviceId"

    public static func loadOrCreateInstallDeviceId() -> String {
        if let data = load(account: installDeviceIdKey),
           let existing = String(data: data, encoding: .utf8), !existing.isEmpty
        {
            return existing
        }
        let fresh = makeInstallDeviceId()
        save(Data(fresh.utf8), account: installDeviceIdKey)
        return fresh
    }

    /// `"Syai Tag:i:n:<uuid>"`, the same self-chosen shape the official app uses on
    /// iOS (Android uses `Syai Tag:a:n:…`). The UUID is v3-shaped (version 3, variant
    /// 10xx) to match the app's own MD5-derived device UUIDs rather than Foundation's
    /// v4 `UUID()`; the server accepts either, but matching the observed population
    /// costs nothing.
    static func makeInstallDeviceId() -> String {
        var bytes = (0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }
        bytes[6] = (bytes[6] & 0x0F) | 0x30 // version 3
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // variant 10xx
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        let uuid =
            "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20).prefix(12))"
        return "Syai Tag:i:n:\(uuid)"
    }

    /// The bare UUID half of the install id: `Syai Tag:i:n:<uuid>` -> `<uuid>`.
    /// The mainland identity prefix is `ottai:a:g:` followed by the UUID alone.
    public static func loadOrCreateInstallUUID() -> String {
        let full = loadOrCreateInstallDeviceId()
        return full.components(separatedBy: ":").last ?? full
    }

    /// Keychain slot for one manager type. Syai Ultra and Ottai are separate
    /// accounts on separate backends and must not overwrite each other's session.
    private static func accountKey(_ namespace: String) -> String {
        namespace.isEmpty ? accountSessionKey : "\(accountSessionKey).\(namespace)"
    }

    public static func saveAccount(_ session: OttaiAccountSession, namespace: String = "") {
        guard let data = try? JSONEncoder().encode(session) else { return }
        save(data, account: accountKey(namespace))
    }

    public static func loadAccount(namespace: String = "") -> OttaiAccountSession? {
        guard let data = load(account: accountKey(namespace)) else { return nil }
        return try? JSONDecoder().decode(OttaiAccountSession.self, from: data)
    }

    public static func deleteAccount(namespace: String = "") {
        delete(account: accountKey(namespace))
    }

    private static func save(_ data: Data, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

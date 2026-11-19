import CryptoKit
import Foundation
import Security

public enum PrivacyLockMethod: String, CaseIterable, Codable, Sendable {
    case pin, pattern

    public func accepts(_ secret: String) -> Bool {
        switch self {
        case .pin: return secret.utf8.count == 4 && secret.utf8.allSatisfy { (48 ... 57).contains($0) }
        case .pattern:
            return (4 ... 9).contains(secret.count) && secret.utf8.allSatisfy { (48 ... 56).contains($0) }
                && Set(secret).count == secret.count
        }
    }
}

struct PrivacyCredential: Codable {
    let version: Int
    let method: PrivacyLockMethod
    let salt: Data
    let digest: Data

    init(method: PrivacyLockMethod, secret: String) throws {
        guard method.accepts(secret) else { throw PrivacyVaultError.invalidCredential }
        var salt = Data(count: 24)
        let result = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard result == errSecSuccess else { throw PrivacyVaultError.storage }
        version = 1
        self.method = method
        self.salt = salt
        digest = Self.derive(secret: secret, salt: salt)
    }

    func accepts(_ secret: String) -> Bool {
        guard version == 1, salt.count == 24, digest.count == 32, method.accepts(secret) else { return false }
        let candidate = Self.derive(secret: secret, salt: salt)
        return zip(candidate, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// PBKDF2-HMAC-SHA256, one 32-byte block. The salt/digest live only in Keychain.
    private static func derive(secret: String, salt: Data) -> Data {
        let key = SymmetricKey(data: Data(secret.utf8))
        var block = Data(HMAC<SHA256>.authenticationCode(for: salt + Data([0, 0, 0, 1]), using: key))
        var output = Array(block)
        for _ in 1 ..< 20_000 {
            block = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
            for index in output.indices { output[index] ^= block[index] }
        }
        return Data(output)
    }
}

enum PrivacyVaultError: Error {
    case invalidCredential, storage
}

struct PrivacyAttemptState: Codable {
    var failures = 0
    var retryAfter = Date.distantPast

    mutating func failed(at now: Date) {
        failures = min(100, failures + 1)
        if failures >= 5 {
            retryAfter = now.addingTimeInterval(min(900, 30 * pow(2, Double(min(5, failures - 5)))))
        }
    }
}

enum PrivacyVault {
    static let configuredKey = "privacy.lock.configured"
    static let methodKey = "privacy.lock.method"
    private static let attemptsKey = "privacy.lock.attempts"

    static var configured: Bool { UserDefaults.standard.bool(forKey: configuredKey) }
    static var method: PrivacyLockMethod {
        PrivacyLockMethod(rawValue: UserDefaults.standard.string(forKey: methodKey) ?? "") ?? .pin
    }

    static var attempts: PrivacyAttemptState {
        get {
            guard let data = UserDefaults.standard.data(forKey: attemptsKey),
                  let value = try? JSONDecoder().decode(PrivacyAttemptState.self, from: data)
            else { return PrivacyAttemptState() }
            return value
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: attemptsKey) }
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Trio") + ".privacy-lock",
         kSecAttrAccount as String: "viewing-lock"]
    }

    static func configure(method: PrivacyLockMethod, secret: String) throws {
        let record = try PrivacyCredential(method: method, secret: secret)
        let data = try JSONEncoder().encode(record)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw PrivacyVaultError.storage
            }
        } else if status != errSecSuccess { throw PrivacyVaultError.storage }
        UserDefaults.standard.set(method.rawValue, forKey: methodKey)
        UserDefaults.standard.set(true, forKey: configuredKey)
        attempts = PrivacyAttemptState()
    }

    static func verify(_ secret: String, now: Date = Date()) throws -> Bool {
        guard now >= attempts.retryAfter else { return false }
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let record = try? JSONDecoder().decode(PrivacyCredential.self, from: data)
        else { throw PrivacyVaultError.storage }
        let valid = record.accepts(secret)
        var state = attempts
        if valid { state = PrivacyAttemptState() } else { state.failed(at: now) }
        attempts = state
        return valid
    }

    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PrivacyVaultError.storage }
        UserDefaults.standard.set(false, forKey: configuredKey)
        attempts = PrivacyAttemptState()
    }
}

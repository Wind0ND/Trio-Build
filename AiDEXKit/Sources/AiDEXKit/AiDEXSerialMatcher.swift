import Foundation

/// Matches the serial from the sensor box against the local name carried by an
/// advertisement. Only the two observed prefixes are accepted; the remaining
/// text must equal the serial exactly after trimming and case folding.
public struct AiDEXSerialMatcher: Equatable, Sendable {
    public static let allowedPrefixes = ["AiDEX X-", "X-"]

    public let serial: String

    public init?(serial: String) {
        guard let normalized = Self.normalizedSerial(serial) else { return nil }
        self.serial = normalized
    }

    public func matches(localName: String?) -> Bool {
        guard let candidate = Self.serial(inLocalName: localName) else { return false }
        return candidate == serial
    }

    /// Trims surrounding whitespace and case-folds. A serial pasted together
    /// with one of the allowed local-name prefixes is accepted as a convenience.
    public static func normalizedSerial(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = value.uppercased()
        for prefix in allowedPrefixes where upper.hasPrefix(prefix.uppercased()) {
            value = String(value.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        guard !value.isEmpty else { return nil }
        return value.uppercased()
    }

    /// Extracts the candidate serial only after an explicitly allowed prefix.
    /// No substring search and no "first device" fallback.
    public static func serial(inLocalName localName: String?) -> String? {
        guard let localName else { return nil }
        let trimmed = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()

        for prefix in allowedPrefixes where upper.hasPrefix(prefix.uppercased()) {
            let candidate = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return nil }
            return candidate.uppercased()
        }
        return nil
    }
}

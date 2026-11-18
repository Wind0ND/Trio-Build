import Foundation

public enum CGMPackageCode {
    public static func aiDEXSerial(from payload: String) -> String? {
        serial(in: payload, length: 10 ... 10)
    }

    public static func sibionicsIdentifier(from payload: String) -> String? {
        identifier(payload, length: 8 ... 8) ?? serial(in: payload, length: 8 ... 20)
    }

    public static func identifier(_ input: String, length: ClosedRange<Int>) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard length.contains(value.utf8.count), value.utf8.allSatisfy({ byte in
            (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
        }) else { return nil }
        return value.uppercased()
    }

    private static func serial(in input: String, length: ClosedRange<Int>) -> String? {
        let payload = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload.utf8.count <= 256 else { return nil }
        let fields = payload.hasPrefix("(") ? printedFields(payload) : compactFields(payload)
        guard let fields else { return nil }
        let serials = fields.filter { $0.code == "21" }
        guard serials.count == 1 else { return nil }
        return identifier(serials[0].value, length: length)
    }

    private typealias Field = (code: String, value: String)
    private static let fixedLengths = ["01": 14, "11": 6, "17": 6]
    private static let variableCodes: Set<String> = ["10", "21"]

    private static func printedFields(_ payload: String) -> [Field]? {
        var result: [Field] = []
        var seen: Set<String> = []
        for field in payload.dropFirst().split(separator: "(", omittingEmptySubsequences: false) {
            let parts = field.split(separator: ")", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            let code = String(parts[0])
            let value = parts[1]
            guard seen.insert(code).inserted else { return nil }
            if let length = fixedLengths[code] {
                guard value.utf8.count == length, value.utf8.allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
            } else {
                guard variableCodes.contains(code), (1 ... 20).contains(value.utf8.count) else { return nil }
            }
            result.append((code, String(value)))
        }
        return result
    }

    private static func compactFields(_ payload: String) -> [Field]? {
        var remaining = payload[...]
        if remaining.hasPrefix("]d2") || remaining.hasPrefix("]Q3") {
            remaining = remaining.dropFirst(3)
        }
        guard remaining.hasPrefix("01") else { return nil }
        var result: [Field] = []
        var seen: Set<String> = []
        while !remaining.isEmpty {
            let code = String(remaining.prefix(2))
            guard seen.insert(code).inserted else { return nil }
            remaining = remaining.dropFirst(2)
            if let length = fixedLengths[code] {
                let value = remaining.prefix(length)
                guard value.count == length, value.utf8.allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
                result.append((code, String(value)))
                remaining = remaining.dropFirst(length)
            } else if variableCodes.contains(code) {
                let end = remaining.firstIndex(of: "\u{1D}") ?? remaining.endIndex
                let value = remaining[..<end]
                guard (1 ... 20).contains(value.count) else { return nil }
                result.append((code, String(value)))
                remaining = end == remaining.endIndex ? remaining[end...] : remaining[remaining.index(after: end)...]
            } else {
                return nil
            }
        }
        return result
    }
}

//
//  OttaiBoundSensorLookup.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// A sensor already bound to the account, typically activated by the official
/// app, that OttaiKit can take over without activating it again.
public struct OttaiBoundSensor: Equatable, Sendable {
    public let deviceInfo: DeviceInfo
    public let keyGroup: OttaiKeyGroup
    /// From the server's `activeTime`; nil if it isn't reported, in which case
    /// ingest derives it from the sensor's own elapsed-seconds field.
    public let activatedAt: Date?

    public var mac: String { deviceInfo.mac }

    /// Whether the wear window has already run out by the server's account.
    public var isPastWear: Bool {
        guard let activatedAt else { return false }
        return activatedAt.addingTimeInterval(OttaiWearExtension.extendedWear(deviceInfo.activeDuration)) <= Date()
    }
}

/// Finds the sensor bound to the logged-in account, the way the official app
/// restores it: `GET deviceBind/getBindDevice` for which sensor is bound (and
/// when it started), then `device/authInfo` for that MAC for the BLE key group
/// and durations.
///
/// `getBindDevice`'s `data` parses into the app's `CgmBindDeviceModel`, the
/// same model as the calibration fetch, and for a started sensor it still
/// carries `coefficient`/`coeffUpdateTime` (`authInfo` doesn't). Those are
/// required: a sensor without its own coefficients is not taken over.
public struct OttaiBoundSensorLookup: Sendable {
    public enum LookupError: Error, CustomStringConvertible, LocalizedError {
        case notConfigured
        case noSecretKey
        case business(code: String)
        case noCalibration
        case decode(String)

        public var description: String {
            switch self {
            case .notConfigured: return String(localized: "Log in to Ottai first.", bundle: .ottaiKit)
            case .noSecretKey: return String(localized: "Missing glucoseSecretKey; log in again.", bundle: .ottaiKit)
            case let .business(code): return String(localized: "Ottai server returned '\(String(describing: code))' when looking up your sensor.", bundle: .ottaiKit)
            case .noCalibration:
                return String(localized: "Ottai didn't provide this sensor's calibration, so \(String(describing: Bundle.main.ottaiHostAppName)) can't use it. Pair a new sensor instead.", bundle: .ottaiKit)
            case let .decode(message): return String(localized: "Couldn't read your bound sensor: \(String(describing: message)).", bundle: .ottaiKit)
            }
        }

        public var errorDescription: String? { description }
    }

    private let backend: OttaiBackend
    private let client: OttaiEnvelopedClient
    private let sessionRetrying: OttaiSessionRetrying
    private let logger = OttaiLogger(category: "BoundSensorLookup")

    public init(
        backend: OttaiBackend,
        session: URLSession = .shared,
        onSessionRotated: (@Sendable(OttaiCredentials, String?) -> Void)? = nil,
        recoverSession: (@Sendable() async -> OttaiBackend?)? = nil,
        onAccountLockoutChanged: (@Sendable(Bool) -> Void)? = nil
    ) {
        self.backend = backend
        client = OttaiEnvelopedClient(backend: backend, urlSession: session)
        sessionRetrying = OttaiSessionRetrying(
            session: session, onSessionRotated: onSessionRotated, recoverSession: recoverSession,
            onAccountLockoutChanged: onAccountLockoutChanged
        )
    }

    /// The bound sensor, or nil when the account has none.
    public func boundSensor() async throws -> OttaiBoundSensor? {
        guard backend.isConfigured else { throw LookupError.notConfigured }
        return try await sessionRetrying.run(client: client, backend: backend) { client, backend in
            // The CN server scopes this lookup to the customerId header; an empty
            // value silently returns {"code":"OK","data":null}.
            let customer = backend.userId ?? "<nil>"
            logger.info("getBindDevice customerId=\(customer.count) chars, base=\(backend.baseURL.host ?? "?")")
            let bindData = try await client.getBindDevice()
            logger.info("getBindDevice response: \(String(data: bindData, encoding: .utf8) ?? "<\(bindData.count) bytes>")")
            guard var body = try Self.boundDeviceBody(bindData),
                  let mac = body["mac"] as? String else { return nil }

            // authInfo is the call the official app gets the BLE keys from, so
            // its values win; getBindDevice fills in the rest (start time,
            // firmware). If authInfo fails, the bound record alone is enough
            // when it happens to carry the keys.
            do {
                let authInfo = try await client.authInfo(mac: mac)
                logger.info("authInfo response: \(String(data: authInfo.raw, encoding: .utf8) ?? "<\(authInfo.raw.count) bytes>")")
                body = Self.merged(bound: body, authInfo: authInfo.raw)
            } catch {
                logger.warning("authInfo failed for the bound sensor: \(String(describing: error))")
                if Self.missingForAdoption(body) { throw error }
            }
            return try Self.parse(body: body, glucoseSecretKey: backend.glucoseSecretKey)
        }
    }

    // MARK: - Onboarding diagnostics

    /// Raw answers of every account-device endpoint the CN service exposes, in
    /// one text block for onboarding. Read-only: nothing is bound, unbound,
    /// activated or connected, and nothing is stored.
    public func cnAccountDiagnostics(mac: String?) async -> String {
        var lines: [String] = []
        let customer = backend.userId ?? "<nil>"
        lines.append("host=\(backend.baseURL.host ?? "?") userId=\(customer) (\(customer.count) chars)")
        func note(_ label: String, _ data: Data) {
            let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            lines.append("\(label) -> \(text.prefix(1200))")
        }
        do {
            let d = try await sessionRetrying.run(client: client, backend: backend) { c, _ in try await c.getBindDevice() }
            note("getBindDevice", d)
        } catch { lines.append("getBindDevice !! \(error)") }
        do {
            let d = try await sessionRetrying.run(client: client, backend: backend) { c, _ in
                try await c.envelopedGET(path: "deviceBind/getLastBindDevice", body: [:], authed: true)
            }
            note("getLastBindDevice", d)
        } catch { lines.append("getLastBindDevice !! \(error)") }
        do {
            let d = try await sessionRetrying.run(client: client, backend: backend) { c, _ in
                try await c.envelopedGET(
                    path: "deviceBind/list",
                    body: ["pageSize": 80, "pageNumber": 1],
                    authed: true
                )
            }
            note("deviceBind/list", d)
        } catch { lines.append("deviceBind/list !! \(error)") }
        if let mac {
            do {
                let d = try await sessionRetrying.run(client: client, backend: backend) { c, _ in
                    try await c.validateMac(mac)
                }
                note("validateV3 \(mac)", d)
            } catch { lines.append("validateV3 !! \(error)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The bound device object, or nil when the response says nothing is
    /// bound. A non-OK code is an error, not "no sensor".
    static func boundDeviceBody(_ data: Data) throws -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LookupError.decode("not a JSON object")
        }
        let code = (root["code"] as? String) ?? "OK"
        guard code == "OK" else { throw LookupError.business(code: code) }
        guard let payload = root["data"] as? [String: Any] else { return nil }
        // The mainland service nests the device under `cgmDeviceRespVO` and keeps
        // `method` / `coefficient` in a sibling `cgmDeviceMethodVO` (which can also
        // be non-empty when the device object's own fields are). Fold both into one
        // flat record so the rest of the pipeline does not care which shape it got.
        var body = (payload["cgmDeviceRespVO"] as? [String: Any]) ?? payload
        if let method = payload["cgmDeviceMethodVO"] as? [String: Any] {
            for (key, value) in method where !(value is NSNull) {
                let existing = body[key]
                if existing == nil || (existing as? String)?.isEmpty == true {
                    body[key] = value
                }
            }
        }
        guard let mac = body["mac"] as? String, !mac.isEmpty else { return nil }
        return body
    }

    /// `authInfo`'s values win over the bound record's; an explicit null in
    /// `authInfo` never erases a value the bound record has.
    static func merged(bound: [String: Any], authInfo: Data) -> [String: Any] {
        guard let auth = (try? JSONSerialization.jsonObject(with: authInfo) as? [String: Any])?["data"]
            as? [String: Any] else { return bound }
        return bound.merging(auth.filter { !($0.value is NSNull) }) { _, fromAuthInfo in fromAuthInfo }
    }

    static func missingForAdoption(_ body: [String: Any]) -> Bool {
        ["keyA", "produceTime", "activeExpireTime", "preheatPeriodTime"].contains { body[$0] == nil }
    }

    static func parse(body: [String: Any], glucoseSecretKey: String?) throws -> OttaiBoundSensor {
        guard let mac = body["mac"] as? String, !mac.isEmpty else { throw LookupError.decode("no 'mac'") }
        guard let gsk = glucoseSecretKey, !gsk.isEmpty else { throw LookupError.noSecretKey }

        let keyGroup: OttaiKeyGroup
        do {
            keyGroup = try OttaiServerCalibrationProvider.parseKeyGroup(
                body: body, respMac: mac,
                produceTimeRaw: (body["produceTime"] as? NSNumber)?.int64Value,
                glucoseSecretKey: gsk
            )
        } catch { throw LookupError.decode("\(error)") }

        guard let activeExpireTimeMs = (body["activeExpireTime"] as? NSNumber)?.doubleValue else {
            throw LookupError.decode("no 'activeExpireTime'")
        }
        guard let preheatPeriodTimeMs = (body["preheatPeriodTime"] as? NSNumber)?.doubleValue else {
            throw LookupError.decode("no 'preheatPeriodTime'")
        }

        // No default fallback: decoding a sensor on anything but its own
        // coefficients would put plausible-but-wrong glucose into the loop.
        guard let coeffB64 = body["coefficient"] as? String, !coeffB64.isEmpty,
              let coeffUpdateTime = (body["coeffUpdateTime"] as? NSNumber)?.int64Value
        else { throw LookupError.noCalibration }
        let coefficients: [Double]
        do {
            coefficients = try OttaiCoefficientDecipher.decipher(
                base64Coefficient: coeffB64, coeffUpdateTime: coeffUpdateTime,
                mac: mac, glucoseSecretKey: gsk
            )
        } catch { throw LookupError.decode("coefficient decipher: \(error)") }

        let produceTime = ((body["produceTime"] as? NSNumber)?.doubleValue)
            .map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(timeIntervalSince1970: 0)
        let activatedAt = ((body["activeTime"] as? NSNumber)?.doubleValue)
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }

        let deviceInfo = DeviceInfo(
            mac: mac,
            serialNo: body["serialNo"] as? String ?? "",
            batchNo: body["batchNo"] as? String ?? "",
            deviceType: body["deviceType"] as? String ?? "",
            deviceVersion: body["deviceVersion"] as? String ?? "",
            coefficients: coefficients,
            // K/B only feed the activation write, which this path never does.
            k: (body["calibrationValueK"] as? NSNumber)?.doubleValue ?? 1,
            b: (body["calibrationValueB"] as? NSNumber)?.doubleValue ?? 1,
            produceTime: produceTime,
            activeDuration: activeExpireTimeMs / 1000,
            preheatDuration: preheatPeriodTimeMs / 1000
        )
        return OttaiBoundSensor(
            deviceInfo: deviceInfo,
            keyGroup: keyGroup,
            activatedAt: activatedAt
        )
    }
}

public extension OttaiEnvelopedClient {
    /// GET `deviceBind/getBindDevice`: empty param map, access token required.
    func getBindDevice() async throws -> Data {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        try await ensureAccessToken()
        if backend.plainTextTransport {
            // CN service exposes this one as a genuine GET with no body.
            return try await plainGET(path: "deviceBind/getBindDevice", authed: true)
        }
        return try await envelopedGET(path: "deviceBind/getBindDevice", body: [:])
    }
}

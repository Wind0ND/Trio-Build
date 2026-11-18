//
//  OttaiBackend.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CryptoKit
import Foundation

public struct OttaiBackend: Sendable {
    public let baseURL: URL
    public let pathPrefix: String
    public let productModel: String

    /// Speak plaintext JSON + md5 signatures instead of the cipher envelope.
    ///
    /// The Ottai (global) service requires `cipherBody*` / `cipherParam*` on every
    /// request; the mainland Ottai service (`api.ottai.com`) serves the same
    /// business endpoints in the clear under a different prefix. Only the
    /// transport differs - endpoints, bodies, `cgmAuth/verify` and the bind hand
    /// out identical payloads, so the protocol layer above is shared verbatim.
    public var plainTextTransport: Bool

    /// Mainland Ottai (`api.ottai.com`). Shares the global protocol but differs in
    /// three places: the bind body, the absence of `jwt/refreshToken`, and the
    /// prefix the plaintext login calls live under.
    public let isOttaiCn: Bool

    /// JWT session credentials.
    public var credentials: OttaiCredentials

    /// Per-account KDF seed from login/refresh. Unwraps the coefficient blob and
    /// `keyA` the bind hands out; nil until login completes.
    public var glucoseSecretKey: String?

    /// Hardcoded request-signing key baked into the binary; not a per-account secret.
    public static let deviceSignKey = "dy7234hbnrnfh7q89eru8ybfn899"

    /// Pre-login app identity, used when the JWT has no `app_name` / `device_id` claims.
    /// Once logged in, `appName` / `deviceId` come from the token so signature + envelope match.
    private let fallbackAppName: String
    private let fallbackDeviceId: String

    // Identity headers sent with every request; values mirror a real iPhone running the official app.

    /// App bundle id, identical on both platforms.
    public var packageName: String
    /// App version string + build. Bump when the real app ships a new version.
    public var versionName: String
    public var versionCode: String
    /// `ua` header, `"ios"` lowercase.
    public var userAgent: String
    /// Account display unit (`mmol_L` / `mg_dL`). View-layer only; compute is canonically mmol/L.
    public var unit: String
    /// Phone model via `sysctlbyname("hw.machine")`, matching the official app.
    public var deviceModel: String
    /// Locale/timezone headers defaulted from the device.
    public var language: String
    public var country: String
    public var region: String
    public var timeZoneName: String
    /// UTC offset in **seconds**, as a string (`"7200"` = CEST).
    public var timeZoneOffsetSeconds: String

    public init(
        baseURL: URL,
        pathPrefix: String,
        productModel: String,
        credentials: OttaiCredentials,
        appName: String,
        deviceId: String,
        glucoseSecretKey: String? = nil,
        packageName: String = "com.ottai.tag",
        versionName: String = "1.35.0",
        versionCode: String = "263931",
        userAgent: String = "ios",
        unit: String = "mmol_L",
        deviceModel: String = OttaiBackend.deviceHardwareModel,
        language: String? = nil,
        country: String? = nil,
        region: String? = nil,
        timeZoneName: String? = nil,
        timeZoneOffsetSeconds: String? = nil,
        plainTextTransport: Bool = false,
        isOttaiCn: Bool = false
    ) {
        self.baseURL = baseURL
        self.pathPrefix = pathPrefix
        self.productModel = productModel
        self.credentials = credentials
        fallbackAppName = appName
        fallbackDeviceId = deviceId
        self.glucoseSecretKey = glucoseSecretKey
        self.packageName = packageName
        self.versionName = versionName
        self.versionCode = versionCode
        self.userAgent = userAgent
        self.unit = unit
        self.deviceModel = deviceModel
        self.language = language ?? Self.deviceLanguage
        self.country = country ?? Self.deviceRegion
        self.region = region ?? Self.deviceRegion
        self.timeZoneName = timeZoneName ?? Self.deviceTimeZoneName
        self.timeZoneOffsetSeconds = timeZoneOffsetSeconds ?? Self.deviceTimeZoneOffsetSeconds
        self.plainTextTransport = plainTextTransport
        self.isOttaiCn = isOttaiCn
    }

    private static var deviceLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    private static var deviceRegion: String {
        Locale.current.region?.identifier ?? "US"
    }

    private static var deviceTimeZoneName: String {
        TimeZone.current.abbreviation() ?? "UTC"
    }

    private static var deviceTimeZoneOffsetSeconds: String {
        String(TimeZone.current.secondsFromGMT())
    }

    /// This device's hardware identifier (`utsname.machine`).
    ///
    /// On the simulator `hw.machine` reports the host Mac's arch, so prefer
    /// `SIMULATOR_MODEL_IDENTIFIER`; on a real device sysctl returns the genuine model.
    public static var deviceHardwareModel: String {
        #if targetEnvironment(simulator)
            if let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
               !simModel.isEmpty
            {
                return simModel
            }
            return "iPhone15,2"
        #elseif canImport(Darwin)
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.machine", &buffer, &size, nil, 0)
            let model = String(cString: buffer)
            return model.isEmpty ? "iPhone15,2" : model
        #else
            return "iPhone15,2"
        #endif
    }

    /// From the JWT `app_name` claim, falling back to the pre-login value.
    public var appName: String { credentials.appNameClaim ?? fallbackAppName }

    /// From the JWT `device_id` claim, falling back to the pre-login value.

    public var deviceId: String { credentials.deviceIdClaim ?? fallbackDeviceId }

    /// Account id (`sub`) sent as `customerId` on gated calls.
    public var userId: String? { credentials.userId }

    /// Ottai (mainland China) backend.
    ///
    /// Captured 2026-11-17 from the shipping CN Android app (`com.ottai.tag`,
    /// Flutter, `ua: Android`, `User-Agent: Dart/3.8`). Two transports are in
    /// play and they must not be mixed up:
    ///
    /// - `user/apiToken`, `user/smsCode`, `user/smsLogin` are **plaintext** GET/POST
    ///   under `/cgm/app/server` with an md5 `signature` query/body field.
    /// - Every device endpoint (`validateDeviceByMacV3`, `cgmAuth/verify`,
    ///   `deviceBind/*`) lives under `/cgm/security/app/server` and **requires the
    ///   cipher envelope**; the plaintext route answers HTTP 403
    ///   `NET_SECURITY_PLAINTEXT_ROUTE_FORBIDDEN`.
    ///
    /// The identity strings must match the headers byte for byte: `appName` is
    /// lowercase `ottai` and the `deviceId` is `ottai:a:g:<uuid>` - signing only
    /// the `g:` suffix (as one earlier port did) fails with 签名校验失败.
    ///
    /// The fallback `deviceId` is what the signatures are computed over, so it
    /// must stay stable across launches for the JWT to remain valid.
    public static let ottaiCnTemplate = OttaiBackend(
        baseURL: URL(string: "https://api.ottai.com")!,
        pathPrefix: "cgm/security/app/server",
        productModel: "MB",
        credentials: .placeholder,
        appName: "ottai",
        deviceId: "ottai:a:g:" + OttaiKeychain.loadOrCreateInstallUUID(),
        packageName: "com.ottai.tag",
        versionName: "1.55.0",
        versionCode: "263121",
        userAgent: "Android",
        unit: "mmol_L",
        deviceModel: "SM-A205FN",
        language: "zh",
        country: "CN",
        region: "CN",
        timeZoneName: "Asia/Shanghai",
        timeZoneOffsetSeconds: "28800",
        isOttaiCn: true
    )

    /// Prefix for the CN plaintext endpoints (login only). The encrypted business
    /// endpoints use `pathPrefix`.
    public static let ottaiPlainPathPrefix = "cgm/app/server"

    public var isConfigured: Bool { credentials.isConfigured }

    /// Swap in rotated credentials without rebuilding the backend, so caller-customised identity headers are preserved.
    public func withCredentials(_ c: OttaiCredentials) -> OttaiBackend {
        var copy = self
        copy.credentials = c
        return copy
    }

    /// Keyed-MD5 signature helper shared by every signed endpoint.
    public func md5Hex(_ preimage: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(preimage.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `signValidateMac` (`validateDeviceByMacV3`): `md5(appName + deviceId + timestamp + mac + deviceSignKey)`.
    public func signValidateMac(mac: String, timestamp: String) -> String {
        md5Hex(appName + deviceId + timestamp + mac + OttaiBackend.deviceSignKey)
    }

    /// `signAuthInfo`: `md5(signKey + appName + deviceId + mac + timestamp + signKey)`.
    public func signAuthInfo(mac: String, timestamp: String) -> String {
        let key = OttaiBackend.deviceSignKey
        return md5Hex(key + appName + deviceId + mac + timestamp + key)
    }

    /// `cgmAuth/verify`: `md5(appName + deviceId + mac + authDevHex + authFlagHex + timestamp + deviceSignKey)`.
    public func signCgmAuthVerify(mac: String, authDevHex: String, authFlagHex: String, timestamp: String) -> String {
        md5Hex(appName + deviceId + mac + authDevHex + authFlagHex + timestamp + OttaiBackend.deviceSignKey)
    }

    /// `signApiToken`: `md5(appName + deviceId + timestamp + deviceSignKey)`.
    public func signApiToken(timestamp: String) -> String {
        md5Hex(appName + deviceId + timestamp + OttaiBackend.deviceSignKey)
    }

    /// `signLogin`: `md5(appName + deviceId + timestamp + apiToken + email + password + deviceSignKey)`.
    public func signLogin(timestamp: String, apiToken: String, email: String, password: String) -> String {
        md5Hex(appName + deviceId + timestamp + apiToken + email + password + OttaiBackend.deviceSignKey)
    }

    /// Plaintext-transport signature: `md5(appName + deviceId + timestamp + args + deviceSignKey)`.
    ///
    /// `args` are concatenated in the order the endpoint declares them, with no
    /// separators - `requestSmsCode` is `(phone, apiToken)`, `smsLogin` is
    /// `(requestId, phone, validCode)`, `validateDeviceByMacV3` is `(mac)`.
    public func signPlain(timestamp: String, _ args: [String]) -> String {
        md5Hex(appName + deviceId + timestamp + args.joined() + OttaiBackend.deviceSignKey)
    }

    /// `cgmAuth/verify` on the plaintext transport. Unlike `signCgmAuthVerify`
    /// the server compares every hex field uppercased, and the preimage carries
    /// no `timestamp` of its own - the caller's `timestamp` is that value.
    public func signPlainAuthVerify(
        mac: String,
        authDevHex: String,
        authFlagHex: String,
        timestamp: String
    ) -> String {
        let key = OttaiBackend.deviceSignKey
        return md5Hex(
            appName + deviceId + mac.uppercased() + authDevHex.uppercased()
                + authFlagHex.uppercased() + timestamp + key
        )
    }

    /// Millisecond timestamp string. The app uses a server-synced clock; wall-clock is a stand-in.
    public static func timestampMillis(_ date: Date = Date()) -> String {
        String(Int(date.timeIntervalSince1970 * 1000))
    }

    /// Full URL for an endpoint under `baseURL/pathPrefix/path`.
    func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(pathPrefix).appendingPathComponent(path)
    }

    /// Full URL for a CN plaintext endpoint under `baseURL/cgm/app/server/path`.
    func plainEndpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(Self.ottaiPlainPathPrefix).appendingPathComponent(path)
    }

    /// Standard header set. `productModel` is opt-in because only `validateDeviceByMacV3`,
    /// `cgmAuth/verify` and `authInfo` send it. `timestamp` is fresh; callers that already signed a timestamp
    /// must overwrite it after this call.
    func applyBaseHeaders(_ request: inout URLRequest, includeProductModel: Bool = false) {
        if includeProductModel {
            request.setValue(productModel, forHTTPHeaderField: "productModel")
        }
        request.setValue(Self.timestampMillis(), forHTTPHeaderField: "timestamp")
        // v1 (time-based), like the app. Foundation's UUID() is v4 and would
        // differ in the version nibble on every request.
        request.setValue(OttaiTraceID.next(), forHTTPHeaderField: "traceId")
        request.setValue(appName, forHTTPHeaderField: "appName")
        request.setValue(packageName, forHTTPHeaderField: "packageName")
        request.setValue(versionName, forHTTPHeaderField: "versionName")
        request.setValue(versionCode, forHTTPHeaderField: "versionCode")
        request.setValue(userAgent, forHTTPHeaderField: "ua")
        request.setValue(timeZoneName, forHTTPHeaderField: "timeZoneName")
        request.setValue(timeZoneOffsetSeconds, forHTTPHeaderField: "timezone")
        request.setValue(language, forHTTPHeaderField: "language")
        request.setValue(country, forHTTPHeaderField: "country")
        request.setValue(region, forHTTPHeaderField: "region")
        request.setValue(deviceId, forHTTPHeaderField: "deviceId")
        request.setValue(unit, forHTTPHeaderField: "unit")
        request.setValue(deviceModel, forHTTPHeaderField: "deviceModel")
        applyCnForwardHeaders(&request)
    }

    /// Header set for the plaintext (CN) transport.
    ///
    /// The mainland backend geoblocks requests that do not carry the Android
    /// app's identity, so this replaces `applyBaseHeaders` wholesale rather than
    /// layering on top of it: `User-Agent` is Dart, `ua` is `Android`, and
    /// `applicationType` is `ottai_main`. `timestamp` is fresh; callers that
    /// already signed a timestamp must overwrite it afterwards.
    func applyPlainHeaders(_ request: inout URLRequest, includeProductModel: Bool = false) {
        if includeProductModel {
            request.setValue(productModel, forHTTPHeaderField: "productModel")
        }
        request.setValue("Dart/3.8 (dart:io)", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.timestampMillis(), forHTTPHeaderField: "timestamp")
        request.setValue(OttaiTraceID.next(), forHTTPHeaderField: "traceId")
        request.setValue(appName, forHTTPHeaderField: "appName")
        request.setValue("ottai_main", forHTTPHeaderField: "applicationType")
        request.setValue(packageName, forHTTPHeaderField: "packageName")
        request.setValue(versionName, forHTTPHeaderField: "versionName")
        request.setValue(versionCode, forHTTPHeaderField: "versionCode")
        request.setValue(userAgent, forHTTPHeaderField: "ua")
        request.setValue(timeZoneName, forHTTPHeaderField: "timeZoneName")
        request.setValue(timeZoneOffsetSeconds, forHTTPHeaderField: "timezone")
        request.setValue(language, forHTTPHeaderField: "language")
        request.setValue(country, forHTTPHeaderField: "country")
        request.setValue(region, forHTTPHeaderField: "region")
        request.setValue(deviceId, forHTTPHeaderField: "deviceId")
        request.setValue(unit, forHTTPHeaderField: "unit")
        request.setValue(deviceModel, forHTTPHeaderField: "deviceModel")
        applyCnForwardHeaders(&request)
    }

    /// The mainland backend only answers requests that look like they come from China.
    /// xDrip's Ottai driver sends the same four headers on every CN call.
    static let cnForwardIp = "114.114.114.114"

    private func applyCnForwardHeaders(_ request: inout URLRequest) {
        guard isOttaiCn else { return }
        for name in ["X-Forwarded-For", "X-Real-IP", "CF-Connecting-IP", "True-Client-IP"] {
            request.setValue(Self.cnForwardIp, forHTTPHeaderField: name)
        }
    }
}

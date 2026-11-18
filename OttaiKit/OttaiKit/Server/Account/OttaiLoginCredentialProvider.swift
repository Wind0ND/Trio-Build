//
//  OttaiLoginCredentialProvider.swift
//  OttaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CryptoKit
import Foundation

/// BYOA: user login is the sole credential model. Each user logs in with
/// their own Ottai account; nothing is shipped embedded in the app.
///
/// Reproduces the app's login over the reversed secure channel:
///   1. `GET user/apiToken` -> per-session apiToken UUID.
///   2. `encryptInfo = base64(AES-256-ECB/PKCS7({"email","password"}, key=aesKey))`.
///   3. `signature = md5(appName + deviceId + ts + apiToken + email + password + deviceSignKey)`.
///   4. `POST user/mail/login` -> JWT `{accessToken, refreshToken, userId, glucoseSecretKey}`.
public struct OttaiLoginCredentialProvider {
    /// AES-256 key for the login `encryptInfo`.
    public static let aesKey = "miH5ngQ7z4NZU3JgZFq87Gg6v1Y7YJm9"

    let email: String
    let password: String
    let template: OttaiBackend
    let session: URLSession

    public init(
        email: String,
        password: String,
        template: OttaiBackend = .ottaiCnTemplate,
        session: URLSession = .shared
    ) {
        self.email = email
        self.password = password
        self.template = template
        self.session = session
    }

    /// `encryptInfo = base64(AES-256-ECB/PKCS7(compactJSON({"email","password"}), key=aesKey))`.
    public static func encryptInfo(email: String, password: String) throws -> String {
        let json = "{\"email\":\"\(jsonEscape(email))\",\"password\":\"\(jsonEscape(password))\"}"
        let cipher = try AESECB().encryptECB_PKCS7(Data(json.utf8), keyUTF8: aesKey)
        return cipher.base64EncodedString()
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public func backend() async throws -> OttaiBackend {
        let client = OttaiEnvelopedClient(backend: template, urlSession: session)
        let result = try await client.login(email: email, password: password)
        var b = template.withCredentials(result.credentials)
        if let gsk = result.glucoseSecretKey { b.glucoseSecretKey = gsk }
        return b
    }
}

public extension OttaiEnvelopedClient {
    /// The result of a successful login: the JWT session pair plus the per-account
    /// `glucoseSecretKey` (needed to decipher sensor coefficients/keys).
    struct LoginResult: Sendable {
        public let credentials: OttaiCredentials
        public let glucoseSecretKey: String?
    }

    /// `GET user/apiToken`, unauthenticated pre-step. Signed with
    /// `md5(appName+deviceId+ts+deviceSignKey)`, `timestamp` header = the sig ts.
    /// Returns the per-session apiToken UUID.
    func getApiToken() async throws -> String {
        let ts = OttaiBackend.timestampMillis()
        let sig = backend.signApiToken(timestamp: ts)
        let data = try await envelopedGET(
            path: "user/apiToken",
            body: ["signature": sig],
            extraHeaders: ["timestamp": ts],
            authed: false // unauthenticated pre-step
        )
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoginError.noApiToken
        }
        // `data` may be the UUID string directly, or `{apiToken: …}`.
        if let token = root["data"] as? String, !token.isEmpty { return token }
        if let obj = root["data"] as? [String: Any], let token = obj["apiToken"] as? String, !token.isEmpty {
            return token
        }
        if let token = root["apiToken"] as? String, !token.isEmpty { return token }
        throw LoginError.noApiToken
    }

    /// `POST user/mail/login`, unauthenticated. Body `{encryptInfo, apiToken,
    /// signature}`, `timestamp` header = the sig ts. Parses the JWT bundle
    /// (`data.jwtToken.{accessToken,refreshToken}`, `data.userId`,
    /// `data.glucoseSecretKey`; the top-level `data.accessToken` is null). Runs the
    /// `getApiToken` pre-step itself.
    ///
    /// Only ever throws `LoginError` — transport/crypto failures from the
    /// envelope layer are wrapped in `.transportFailure`.
    func login(email: String, password: String) async throws -> LoginResult {
        do {
            return try await performLogin(email: email, password: password)
        } catch let error as LoginError {
            throw error
        } catch {
            throw LoginError.transportFailure(underlying: String(describing: error))
        }
    }

    private func performLogin(email: String, password: String) async throws -> LoginResult {
        let apiToken = try await getApiToken()
        let ts = OttaiBackend.timestampMillis()
        let encryptInfo = try OttaiLoginCredentialProvider.encryptInfo(email: email, password: password)
        let signature = backend.signLogin(timestamp: ts, apiToken: apiToken, email: email, password: password)

        let data = try await envelopedPOST(
            path: "user/mail/login",
            body: ["encryptInfo": encryptInfo, "apiToken": apiToken, "signature": signature],
            extraHeaders: ["timestamp": ts],
            authed: false // unauthenticated: a stale token from a previous
            // session must not leak onto a re-login
        )

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoginError.malformedResponseBody("response not JSON")
        }

        if let code = root["code"] as? String, code != "OK", code != "SUCCESS" {
            let msg = (root["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            throw LoginError.serverError(code: code, message: msg)
        }
        let dataObj = (root["data"] as? [String: Any]) ?? root
        let jwt = (dataObj["jwtToken"] as? [String: Any]) ?? dataObj
        guard let access = (jwt["accessToken"] as? String) ?? (dataObj["accessToken"] as? String),
              !access.isEmpty
        else {
            throw LoginError.malformedResponseBody("no accessToken in response")
        }
        guard let refresh = (jwt["refreshToken"] as? String) ?? (dataObj["refreshToken"] as? String),
              !refresh.isEmpty
        else {
            throw LoginError.malformedResponseBody("no refreshToken in response")
        }
        let gsk = dataObj["glucoseSecretKey"] as? String
        let accountId = (dataObj["userId"] as? Int).map(String.init)
            ?? (dataObj["userId"] as? String)
        let creds = OttaiCredentials(
            refreshToken: refresh,
            accessToken: access,
            sessionUserId: accountId
        )
        backend = backend.withCredentials(creds)
        if let gsk, !gsk.isEmpty { backend.glucoseSecretKey = gsk }
        return LoginResult(credentials: creds, glucoseSecretKey: (gsk?.isEmpty == false) ? gsk : nil)
    }
}

// MARK: - Mainland (Ottai) sign-in

public extension OttaiEnvelopedClient {
    /// What a successful mainland sign-in hands back: the JWT pair plus the
    /// per-account `glucoseSecretKey` needed to unwrap sensor coefficients.
    struct OttaiLoginResult: Sendable {
        public let credentials: OttaiCredentials
        public let glucoseSecretKey: String?
    }

    /// `GET user/apiToken`: the unauthenticated pre-step. The mainland service
    /// hands a token to anyone, but the response is still the `{code, data}`
    /// envelope with the UUID under `data`.
    func ottaiApiToken() async throws -> String {
        let data = try await plainGET(path: "user/apiToken")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoginError.noApiToken
        }
        if let token = root["data"] as? String, !token.isEmpty { return token }
        if let obj = root["data"] as? [String: Any],
           let token = obj["apiToken"] as? String, !token.isEmpty
        {
            return token
        }
        throw LoginError.noApiToken
    }

    /// `POST user/smsCode`: sends the verification code and returns the
    /// `requestId` that `smsLogin` must quote.
    ///
    /// `smsType` is not part of the signature but must be `1` - without it the
    /// message still goes out and every later `smsLogin` fails with
    /// `Sms_CodeInvalid`.
    func ottaiRequestSmsCode(phone: String, phoneCode: String = "86") async throws -> String {
        let ts = OttaiBackend.timestampMillis()
        let apiToken = try await ottaiApiToken()
        let signature = backend.signPlain(timestamp: ts, [phone, apiToken])
        let data = try await plainPOST(
            path: "user/smsCode",
            body: [
                "phoneCode": phoneCode,
                "phone": phone,
                "apiToken": apiToken,
                "smsType": 1,
                "signature": signature
            ],
            extraHeaders: ["timestamp": ts],
            authed: false
        )
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoginError.malformedResponseBody("smsCode response not JSON")
        }
        if let code = root["code"] as? String, code != "OK", code != "SUCCESS" {
            throw LoginError.serverError(code: code, message: (root["msg"] as? String))
        }
        if let requestId = root["data"] as? String, !requestId.isEmpty { return requestId }
        if let obj = root["data"] as? [String: Any],
           let requestId = (obj["requestId"] as? String) ?? (obj["smsRequestId"] as? String),
           !requestId.isEmpty
        {
            return requestId
        }
        throw LoginError.malformedResponseBody("no requestId in smsCode response")
    }

    /// `POST user/smsLogin`: trades the code for a JWT pair.
    ///
    /// Signed over `(requestId, phone, code)` in that order; the JWT bundle is
    /// shaped like `user/mail/login` (`data.jwtToken.{accessToken,refreshToken}`,
    /// `data.glucoseSecretKey`), so the same fallbacks apply.
    func ottaiSmsLogin(requestId: String, phone: String, code: String) async throws -> OttaiLoginResult {
        let ts = OttaiBackend.timestampMillis()
        let signature = backend.signPlain(timestamp: ts, [requestId, phone, code])
        let data = try await plainPOST(
            path: "user/smsLogin",
            body: [
                "phoneCode": "86",
                "phone": phone,
                "requestId": requestId,
                "validCode": code,
                "signature": signature
            ],
            extraHeaders: ["timestamp": ts],
            authed: false
        )
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoginError.malformedResponseBody("smsLogin response not JSON")
        }
        if let code = root["code"] as? String, code != "OK", code != "SUCCESS" {
            throw LoginError.serverError(code: code, message: (root["msg"] as? String))
        }
        let dataObj = (root["data"] as? [String: Any]) ?? root
        let jwt = (dataObj["jwtToken"] as? [String: Any]) ?? dataObj
        guard let access = (jwt["accessToken"] as? String) ?? (dataObj["accessToken"] as? String),
              !access.isEmpty
        else {
            throw LoginError.malformedResponseBody("no accessToken in smsLogin response")
        }
        let refresh = (jwt["refreshToken"] as? String)
            ?? (dataObj["refreshToken"] as? String)
            ?? ""
        let gsk = dataObj["glucoseSecretKey"] as? String
        let accountId = (dataObj["userId"] as? Int).map(String.init)
            ?? (dataObj["userId"] as? String)
        let creds = OttaiCredentials(
            refreshToken: refresh,
            accessToken: access,
            sessionUserId: accountId
        )
        backend = backend.withCredentials(creds)
        if let gsk, !gsk.isEmpty { backend.glucoseSecretKey = gsk }
        return OttaiLoginResult(credentials: creds, glucoseSecretKey: (gsk?.isEmpty == false) ? gsk : nil)
    }
}

/// Drives the mainland sign-in: request a code, then trade it for a session.
///
/// Kept separate from `OttaiLoginCredentialProvider` because the two services
/// authenticate differently (email + password there, phone + SMS here) and
/// only the latter needs a `requestId` round trip in between.
public struct OttaiCnLoginProvider: Sendable {
    public let phone: String
    public let requestId: String
    public let code: String
    private let session: URLSession

    public init(phone: String, requestId: String, code: String, session: URLSession = .shared) {
        self.phone = phone
        self.requestId = requestId
        self.code = code
        self.session = session
    }

    /// Exchange the code for a backend carrying the new session.
    public func backend(template: OttaiBackend = .ottaiCnTemplate) async throws -> OttaiBackend {
        do {
            let client = OttaiEnvelopedClient(backend: template, urlSession: session)
            let result = try await client.ottaiSmsLogin(
                requestId: requestId,
                phone: phone,
                code: code
            )
            var b = template.withCredentials(result.credentials)
            if let gsk = result.glucoseSecretKey { b.glucoseSecretKey = gsk }
            return b
        } catch let error as OttaiEnvelopedClient.LoginError {
            throw error
        } catch {
            throw OttaiEnvelopedClient.LoginError.transportFailure(underlying: String(describing: error))
        }
    }

    /// Send the verification code; returns the `requestId` `backend()` needs.
    public static func requestCode(
        phone: String,
        phoneCode: String = "86",
        session: URLSession = .shared
    ) async throws -> String {
        let client = OttaiEnvelopedClient(backend: .ottaiCnTemplate, urlSession: session)
        return try await client.ottaiRequestSmsCode(phone: phone, phoneCode: phoneCode)
    }
}

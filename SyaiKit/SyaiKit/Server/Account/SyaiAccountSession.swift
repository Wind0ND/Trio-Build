//
//  SyaiAccountSession.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public struct SyaiAccountSession: Codable, Sendable, Equatable {
    public var email: String
    public var refreshToken: String
    public var accessToken: String?
    public var glucoseSecretKey: String?
    public var userId: String?
    public var password: String?
    /// Which regional service this session belongs to. Left `nil` on sessions
    /// saved before the mainland driver existed. When it is `true` every later
    /// request is pinned to the mainland host, even if a call site forgets to
    /// pass the template - a static-dispatch slip must not silently send a CN
    /// account id to the global server.
    public var isOttaiCn: Bool?

    public init(
        email: String,
        refreshToken: String,
        accessToken: String? = nil,
        glucoseSecretKey: String? = nil,
        userId: String? = nil,
        password: String? = nil,
        isOttaiCn: Bool? = nil
    ) {
        self.email = email
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.glucoseSecretKey = glucoseSecretKey
        self.userId = userId
        self.password = password
        self.isOttaiCn = isOttaiCn
    }

    public init(email: String, backend: SyaiBackend, password: String? = nil) {
        self.init(
            email: email,
            refreshToken: backend.credentials.refreshToken,
            accessToken: backend.credentials.accessToken,
            glucoseSecretKey: backend.glucoseSecretKey,
            userId: backend.userId,
            password: password,
            isOttaiCn: backend.isOttaiCn
        )
    }

    public var credentials: SyaiCredentials {
        SyaiCredentials(refreshToken: refreshToken, accessToken: accessToken, sessionUserId: userId)
    }

    public func backend(template: SyaiBackend = .syaiTemplate) -> SyaiBackend {
        // The session, not the caller, decides the region: a mainland session
        // must always reach api.ottai.com.
        let resolved = isOttaiCn == true ? .ottaiCnTemplate : template
        var b = resolved.withCredentials(credentials)
        b.glucoseSecretKey = glucoseSecretKey
        return b
    }

    public var refreshTokenExpiry: Date? { credentials.refreshTokenExpiry }
    public var hasValidSession: Bool { credentials.hasValidSession }

    public func withRotatedCredentials(_ c: SyaiCredentials, glucoseSecretKey gsk: String? = nil) -> SyaiAccountSession {
        SyaiAccountSession(
            email: email,
            refreshToken: c.refreshToken.isEmpty ? refreshToken : c.refreshToken,
            accessToken: c.accessToken ?? accessToken,
            glucoseSecretKey: gsk ?? glucoseSecretKey,
            userId: userId ?? c.userId,
            password: password,
            isOttaiCn: isOttaiCn
        )
    }
}

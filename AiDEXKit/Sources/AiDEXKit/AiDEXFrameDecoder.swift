//
//  AiDEXFrameDecoder.swift
//  AiDEXKit
//
//  Protocol reference (MIT):
//  https://github.com/Arrow36/aidex-x-linx-ble-reader
//  Copyright (c) 2026 Arrow36. See THIRD_PARTY_NOTICES.md.
//
//  This is an independent Swift transcription of the documented advertisement
//  layout. It is not a port of the reference implementation and does not talk
//  to a sensor.
//

import Foundation

public enum AiDEXProtocol {
    /// Little-endian Bluetooth SIG company identifier at the start of the
    /// manufacturer data.
    public static let companyID: UInt16 = 0x0059
    public static let manufacturerDataLength = 22
    // CoreBluetooth includes the two-byte company ID before the scan response.
    static let scanResponseDataLength = 7
    public static let payloadLength = 20
    public static let crcCoveredLength = 16
    public static let maximumActiveMinutes = 21_600
    public static let minimumGlucoseMgdL = 18
    public static let maximumGlucoseMgdL = 800
    public static let currentWordFlag: UInt16 = 0x8000
    public static let glucoseMask: UInt16 = 0x03FF
    public static let sentinelWord: UInt16 = 0xFFFF
    public static let crcPolynomial: UInt32 = 0x04C1_1DB7
    public static let crcSeedModulus: UInt32 = 0x7F_A777
}

public struct AiDEXDecodedFrame: Equatable, Sendable {
    public let activeMinutes: Int
    public let status: UInt8
    public let currentWord: UInt16
    public let glucoseMgdL: Int
}

public enum AiDEXFrameRejection: Equatable, Sendable {
    case wrongLength(Int)
    case unexpectedCompanyID
    case scanResponse
    case checksumMismatch
    case statusNotReady(UInt8)
    case expired(Int)
    case sentinelWord
    case currentFlagMissing
    case glucoseOutOfRange(Int)
}

public enum AiDEXFrameDecodeResult: Equatable, Sendable {
    case success(AiDEXDecodedFrame)
    case rejected(AiDEXFrameRejection)
}

extension AiDEXFrameRejection {
    /// Maps every decoder rejection to the probe's finite issue. The ordinary
    /// five-byte scan response is not a measurement and is not an error.
    var measurementIssue: AiDEXMeasurementIssue? {
        switch self {
        case .scanResponse:
            return nil
        case .wrongLength, .unexpectedCompanyID:
            return .unsupportedManufacturerFrame
        case .checksumMismatch:
            return .checksumMismatch
        case .statusNotReady, .expired, .sentinelWord, .currentFlagMissing, .glucoseOutOfRange:
            return .readingUnavailable
        }
    }
}

public enum AiDEXFrameDecoder {
    /// Decodes only an exact 2-byte company ID plus 20-byte measurement
    /// payload, checks the proprietary CRC, and rejects every unsupported
    /// field before exposing a value.
    public static func decode(manufacturerData: Data) -> AiDEXFrameDecodeResult {
        guard manufacturerData.count == AiDEXProtocol.manufacturerDataLength ||
            manufacturerData.count == AiDEXProtocol.scanResponseDataLength
        else {
            return .rejected(.wrongLength(manufacturerData.count))
        }
        let bytes = [UInt8](manufacturerData)

        let companyID = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard companyID == AiDEXProtocol.companyID else {
            return .rejected(.unexpectedCompanyID)
        }
        guard bytes.count == AiDEXProtocol.manufacturerDataLength else {
            return .rejected(.scanResponse)
        }

        let payload = Array(bytes[2 ..< AiDEXProtocol.manufacturerDataLength])
        let storedChecksum = UInt32(payload[16])
            | UInt32(payload[17]) << 8
            | UInt32(payload[18]) << 16
            | UInt32(payload[19]) << 24
        guard checksum(for: payload) == storedChecksum else {
            return .rejected(.checksumMismatch)
        }

        let activeMinutes = Int(payload[0]) | Int(payload[1]) << 8
        let status = payload[2]
        guard status == 0 else {
            return .rejected(.statusNotReady(status))
        }
        guard activeMinutes < AiDEXProtocol.maximumActiveMinutes else {
            return .rejected(.expired(activeMinutes))
        }

        let currentWord = UInt16(payload[5]) | UInt16(payload[6]) << 8
        guard currentWord != AiDEXProtocol.sentinelWord else {
            return .rejected(.sentinelWord)
        }
        guard currentWord & AiDEXProtocol.currentWordFlag != 0 else {
            return .rejected(.currentFlagMissing)
        }

        let glucose = Int(currentWord & AiDEXProtocol.glucoseMask)
        guard (AiDEXProtocol.minimumGlucoseMgdL ... AiDEXProtocol.maximumGlucoseMgdL).contains(glucose) else {
            return .rejected(.glucoseOutOfRange(glucose))
        }

        return .success(AiDEXDecodedFrame(
            activeMinutes: activeMinutes,
            status: status,
            currentWord: currentWord,
            glucoseMgdL: glucose
        ))
    }

    /// Non-reflected CRC-32/MPEG-2 style loop with no final XOR and a
    /// proprietary seed. The seed is the wrapping sum of the four
    /// little-endian UInt32 words in the CRC-covered region, modulo 0x7FA777.
    static func checksum(for payload: [UInt8]) -> UInt32 {
        precondition(payload.count >= AiDEXProtocol.payloadLength)
        var crc = seed(for: payload)
        for byte in payload[0 ..< AiDEXProtocol.crcCoveredLength] {
            crc ^= UInt32(byte) << 24
            for _ in 0 ..< 8 {
                if crc & 0x8000_0000 != 0 {
                    crc = (crc << 1) ^ AiDEXProtocol.crcPolynomial
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    static func seed(for payload: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        for offset in stride(from: 0, to: AiDEXProtocol.crcCoveredLength, by: 4) {
            let word = UInt32(payload[offset])
                | UInt32(payload[offset + 1]) << 8
                | UInt32(payload[offset + 2]) << 16
                | UInt32(payload[offset + 3]) << 24
            sum = sum &+ word
        }
        return sum % AiDEXProtocol.crcSeedModulus
    }
}

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PrivacyAppKit

final class PrivacyCoverImageTests: XCTestCase {
    func testDetailedImagesAndExtremeAspectRatiosFitTheActivityBudget() throws {
        for (width, height) in [(512, 512), (1536, 32), (32, 1536)] {
            let image = try makeImage(width: width, height: height)
            let input = try encode(image, type: UTType.png.identifier)
            let output = try XCTUnwrap(PrivacyCoverImage.thumbnail(input))
            XCTAssertLessThanOrEqual(output.count, 1200)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, decoded.height)
            XCTAssertGreaterThanOrEqual(decoded.width, 8)
            XCTAssertLessThanOrEqual(decoded.width, 48)
        }
    }

    func testInvalidPhotoIsRejected() {
        XCTAssertNil(PrivacyCoverImage.thumbnail(Data()))
        XCTAssertNil(PrivacyCoverImage.thumbnail(Data("not an image".utf8)))
    }

    func testSourceOrientationAndMetadataDoNotLeakIntoThumbnail() throws {
        let image = try makeImage(width: 96, height: 64)
        let input = try encode(image, type: UTType.jpeg.identifier, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private camera note"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.0, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.0, kCGImagePropertyGPSLongitudeRef: "E"
            ]
        ])
        let output = try XCTUnwrap(PrivacyCoverImage.thumbnail(input))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        XCTAssertEqual(orientation, 1)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
    }

    func testTransparentCoverFlattensToBlackWithoutLosingVisiblePixels() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
        let image = try XCTUnwrap(context.makeImage())
        let input = try encode(image, type: UTType.png.identifier)
        let output = try XCTUnwrap(PrivacyCoverImage.thumbnail(input))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo))
        let rendered = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        rendered.draw(decoded, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let pixels = try XCTUnwrap(rendered.data).assumingMemoryBound(to: UInt8.self)
        let black = 16 * 128 + 8 * 4
        let red = 16 * 128 + 24 * 4
        XCTAssertLessThan(pixels[black], 40)
        XCTAssertLessThan(pixels[black + 1], 40)
        XCTAssertLessThan(pixels[black + 2], 40)
        XCTAssertGreaterThan(pixels[red], 180)
        XCTAssertLessThan(pixels[red + 1], 70)
        XCTAssertLessThan(pixels[red + 2], 70)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        var seed: UInt32 = 0xA12B34
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0 ..< width * height {
            for channel in 0 ..< 3 {
                seed = seed &* 1664525 &+ 1013904223
                bytes[pixel * 4 + channel] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ))
    }

    private func encode(_ image: CGImage, type: String, properties: [CFString: Any] = [:]) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
#endif

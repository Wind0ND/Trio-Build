#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Creates an orientation-correct, opaque cover without carrying source metadata into ActivityKit.
enum PrivacyCoverImage {
    static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary)
        else { return nil }

        let side = min(image.width, image.height)
        guard side > 0,
              let cropped = image.cropping(to: CGRect(
                  x: CGFloat(image.width - side) / 2, y: CGFloat(image.height - side) / 2,
                  width: CGFloat(side), height: CGFloat(side)
              ))
        else { return nil }

        // The fallback sizes also cover detailed photos whose JPEG headers or image data exceed the budget.
        for size in [48, 40, 32, 24, 16, 12, 8] {
            guard let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
            guard let normalized = context.makeImage() else { return nil }

            // PNG preserves simple artwork; JPEG handles detailed photos. Both start from fresh RGB pixels.
            if let png = encode(normalized, type: UTType.png.identifier), png.count <= 1200 { return png }
            for quality in [0.8, 0.65, 0.45, 0.25, 0.1] {
                if let jpeg = encode(normalized, type: UTType.jpeg.identifier, quality: quality), jpeg.count <= 1200 {
                    return jpeg
                }
            }
        }
        return nil
    }

    private static func encode(_ image: CGImage, type: String, quality: Double? = nil) -> Data? {
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, type as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: false]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? result as Data : nil
    }
}
#endif

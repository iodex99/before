import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

// =============================================================================
// BEFORE — image processing.
//
// Spec §11: normalise before upload. Strip metadata, resize, keep enough
// quality to judge a garment, stay under the upload ceiling.
//
// Two things this file is careful about:
//   1. It never decodes a full-resolution image into memory. A 48MP photo
//      decoded naively is ~190MB and will terminate the app (§82).
//   2. It strips location and device metadata. A wardrobe photo carrying the
//      GPS coordinates of someone's bedroom is not something to upload (§43).
// =============================================================================

public struct ProcessedImage: Sendable {
    public let data: Data
    public let mediaType: String
    public let pixelSize: CGSize
    public let byteCount: Int
}

public enum ImageProcessingError: LocalizedError {
    case unreadable
    case tooLarge(bytes: Int)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable, .encodingFailed:
            "That image couldn't be read. Try another photo."
        case .tooLarge:
            "That image is too large or couldn't be read. Try another photo."
        }
    }
}

public enum ImageProcessor {

    /// Fashion detail — weave, stitching, hardware — survives at this size.
    /// Going lower saves bandwidth and costs the model the thing it is judging.
    public static let maximumDimension: CGFloat = 2200

    /// Matches MAX_UPLOAD_BYTES on the server.
    public static let maximumBytes = 6 * 1024 * 1024

    /// Start high. Fashion photography compresses badly at low quality and the
    /// artefacts look like fabric texture.
    private static let initialQuality: CGFloat = 0.85
    private static let minimumQuality: CGFloat = 0.55

    // MARK: - Entry points

    /// Process an image already in memory. Runs off the main actor.
    public static func process(_ image: UIImage) async throws -> ProcessedImage {
        try await Task.detached(priority: .userInitiated) {
            let resized = downsample(image, to: maximumDimension)
            return try encode(resized)
        }.value
    }

    /// Process image data without ever fully decoding the original.
    ///
    /// This is the path used for photo-library picks and shared screenshots,
    /// which is where the genuinely large files come from.
    public static func process(data: Data) async throws -> ProcessedImage {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                throw ImageProcessingError.unreadable
            }
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0, downsampleOptions
            ) else {
                throw ImageProcessingError.unreadable
            }
            // The orientation is baked in by the thumbnail transform, so the
            // resulting image needs no orientation metadata of its own.
            return try encode(UIImage(cgImage: thumbnail))
        }.value
    }

    public static func process(fileURL: URL) async throws -> ProcessedImage {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try await process(data: data)
    }

    // MARK: - Implementation

    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private static var downsampleOptions: CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation and discards it in one step.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ] as CFDictionary
    }

    private static func downsample(_ image: UIImage, to maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }

        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1          // target is already in pixels
        format.opaque = true      // product photos have no useful alpha
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Encode to JPEG, stepping quality down only as far as needed.
    ///
    /// JPEG rather than HEIC deliberately: the backend and every AI provider
    /// accept JPEG, and converting once on device is better than discovering
    /// a format problem after the upload.
    private static func encode(_ image: UIImage) throws -> ProcessedImage {
        var quality = initialQuality

        while quality >= minimumQuality {
            guard let data = image.jpegData(compressionQuality: quality) else {
                throw ImageProcessingError.encodingFailed
            }
            if data.count <= maximumBytes {
                return ProcessedImage(
                    data: data,
                    mediaType: "image/jpeg",
                    pixelSize: image.size,
                    byteCount: data.count
                )
            }
            quality -= 0.1
        }

        // Still too big at the quality floor: shrink the image rather than
        // degrade it further into mush.
        let smaller = downsample(image, to: maximumDimension * 0.7)
        guard let data = smaller.jpegData(compressionQuality: minimumQuality) else {
            throw ImageProcessingError.encodingFailed
        }
        guard data.count <= maximumBytes else {
            throw ImageProcessingError.tooLarge(bytes: data.count)
        }
        return ProcessedImage(
            data: data,
            mediaType: "image/jpeg",
            pixelSize: smaller.size,
            byteCount: data.count
        )
    }

    // MARK: - Display

    /// A small image for a list row. Never hand a full-size photo to a 64pt
    /// thumbnail (spec §82).
    public static func thumbnail(from data: Data, maxPixelSize: CGFloat = 200) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map(UIImage.init(cgImage:))
    }
}

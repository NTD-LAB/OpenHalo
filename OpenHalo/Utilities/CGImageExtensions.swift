import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension CGImage {
    func encodedData(
        as format: EncodedImageFormat
    ) throws -> Data {
        let mutableData = CFDataCreateMutable(nil, 0)!
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            format.uti.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageEncodingError.destinationCreationFailed
        }

        CGImageDestinationAddImage(destination, self, format.options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncodingError.encodingFailed
        }

        return mutableData as Data
    }

    func toBase64JPEG(quality: Double = 0.7) throws -> String {
        let data = try encodedData(as: .jpeg(quality: quality))
        return data.base64EncodedString()
    }
}

enum EncodedImageFormat {
    case jpeg(quality: Double)
    case png

    var uti: UTType {
        switch self {
        case .jpeg:
            return .jpeg
        case .png:
            return .png
        }
    }

    var options: [CFString: Any] {
        switch self {
        case .jpeg(let quality):
            return [
                kCGImageDestinationLossyCompressionQuality: quality
            ]
        case .png:
            return [:]
        }
    }
}

enum ImageEncodingError: Error, LocalizedError {
    case destinationCreationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .destinationCreationFailed:
            return "Failed to create image destination"
        case .encodingFailed:
            return "Failed to encode image as JPEG"
        }
    }
}

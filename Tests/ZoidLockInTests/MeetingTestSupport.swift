import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZoidLockInCore

enum MeetingTestSupport {
    static let substantiveNotes = """
    # Client workshop — Q3 roadmap

    Reviewed the Cairo rollout timeline with the product lead.
    Covered staffing, vendor invoices, and the next on-site date.
    Agreed to send the statement of work before Friday and attach the café receipt.
    """

    static let alternateSubstantiveNotes = """
    # Follow-up — vendor invoice review

    Walked through the remaining change requests with operations.
    Confirmed the receipt matches the meal and the meeting room booking.
    Next step is to circulate minutes to the steering group on Monday.
    """

    static var substantiveNotesData: Data {
        Data(substantiveNotes.utf8)
    }

    static var alternateSubstantiveNotesData: Data {
        Data(alternateSubstantiveNotes.utf8)
    }
}

enum TestImageError: Error {
    case context
    case destination
    case finalize
}

enum TestImageFactory {
    static let minimalPDF = Data("%PDF-1.4\n1 0 obj<< /Type /Catalog >>endobj\ntrailer<<>>\n%%EOF\n".utf8)

    static func uniquePDF(_ salt: String) -> Data {
        Data("%PDF-1.4\n1 0 obj<< /Type /Catalog /Title (\(salt)) >>endobj\ntrailer<<>>\n%%EOF\n".utf8)
    }

    static func jpeg(
        make: String? = "Apple",
        model: String? = "iPhone 15 Pro",
        dateTime: String? = "2023:11:14 22:20:00",
        software: String? = nil,
        offset: String? = "+00:00",
        pixelSize: Int = OfflineMeetingPolicy.minimumPhotoEdge,
        includeCameraHardware: Bool = true,
        includeMakerApple: Bool = true,
        fill: CGColor = CGColor(red: 0.76, green: 0.23, blue: 0.18, alpha: 1)
    ) throws -> Data {
        try encode(
            uti: UTType.jpeg,
            make: make,
            model: model,
            dateTime: dateTime,
            software: software,
            offset: offset,
            pixelSize: pixelSize,
            includeCameraHardware: includeCameraHardware,
            includeMakerApple: includeMakerApple,
            fill: fill
        )
    }

    static func png() throws -> Data {
        try encode(
            uti: UTType.png,
            make: nil,
            model: nil,
            dateTime: nil,
            software: nil,
            offset: nil,
            pixelSize: 64,
            includeCameraHardware: false,
            includeMakerApple: false,
            fill: CGColor(red: 0.9, green: 0.88, blue: 0.82, alpha: 1)
        )
    }

    static func heicOrNil() -> Data? {
        try? encode(
            uti: UTType.heic,
            make: "Apple",
            model: "iPhone 15 Pro",
            dateTime: "2023:11:14 22:20:00",
            software: nil,
            offset: "+00:00",
            pixelSize: OfflineMeetingPolicy.minimumPhotoEdge,
            includeCameraHardware: true,
            includeMakerApple: true,
            fill: CGColor(red: 0.76, green: 0.23, blue: 0.18, alpha: 1)
        )
    }

    static func thumbnailJPEG() throws -> Data {
        try jpeg(
            pixelSize: 48,
            includeCameraHardware: false,
            includeMakerApple: false
        )
    }

    static func appleCameraJPEG(
        dateTime: String,
        offset: String = "+00:00",
        fill: CGColor = CGColor(red: 0.76, green: 0.23, blue: 0.18, alpha: 1)
    ) throws -> Data {
        try jpeg(dateTime: dateTime, offset: offset, fill: fill)
    }

    private static func encode(
        uti: UTType,
        make: String?,
        model: String?,
        dateTime: String?,
        software: String?,
        offset: String?,
        pixelSize: Int,
        includeCameraHardware: Bool,
        includeMakerApple: Bool,
        fill: CGColor
    ) throws -> Data {
        let image = try makeCGImage(size: pixelSize, fill: fill)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            uti.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.destination
        }

        var tiff: [CFString: Any] = [:]
        if let make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model { tiff[kCGImagePropertyTIFFModel] = model }
        if let dateTime { tiff[kCGImagePropertyTIFFDateTime] = dateTime }
        if let software { tiff[kCGImagePropertyTIFFSoftware] = software }

        var exif: [CFString: Any] = [:]
        if let dateTime { exif[kCGImagePropertyExifDateTimeOriginal] = dateTime }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        if includeCameraHardware {
            exif[kCGImagePropertyExifFocalLength] = 6.765
            exif[kCGImagePropertyExifFNumber] = 1.78
            exif[kCGImagePropertyExifISOSpeedRatings] = [125]
            exif[kCGImagePropertyExifLensModel] = "iPhone 15 Pro back triple camera 6.765mm f/1.78"
            exif[kCGImagePropertyExifFocalLenIn35mmFilm] = 24
            exif[kCGImagePropertyExifExposureTime] = 0.008
        }

        var properties: [CFString: Any] = [:]
        if !tiff.isEmpty {
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if !exif.isEmpty {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if includeMakerApple {
            properties[kCGImagePropertyMakerAppleDictionary] = [
                "1": 1,
                "14": 0,
                "RunType": 1,
            ] as [String: Any]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.finalize
        }
        return data as Data
    }

    private static func makeCGImage(size: Int, fill: CGColor) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.context
        }
        context.setFillColor(fill)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else {
            throw TestImageError.context
        }
        return image
    }
}

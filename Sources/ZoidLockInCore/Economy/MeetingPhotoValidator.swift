import CoreGraphics
import Foundation
import ImageIO

/// Failures from the local EXIF gate that runs before any network dispatch.
public enum MeetingPhotoValidationError: Error, Equatable, Sendable {
    case unreadableImage
    case strippedMetadata
    case softwareEdited(String)
    case notAppleCamera(make: String?, model: String?)
    case missingCaptureTimestamp
    case timestampOutOfWindow(capturedAt: Date, punchIn: Date, punchOut: Date)
    case missingAppleHardwareIndicators
    case photoTooSmall(width: Int, height: Int)
    case missingTimezoneOffset
    case timezoneOffsetMismatch(photoOffset: Int, systemOffset: Int)
}

extension MeetingPhotoValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Environment photo could not be decoded."
        case .strippedMetadata:
            return "Environment photo EXIF was stripped or re-saved without camera metadata."
        case .softwareEdited(let software):
            return "Environment photo was software-edited (\(software))."
        case .notAppleCamera(let make, let model):
            let label = [make, model].compactMap { $0 }.joined(separator: " ")
            if label.isEmpty {
                return "Environment photo is not from a genuine Apple camera."
            }
            return "Environment photo camera '\(label)' is not a genuine Apple iPhone or iPad."
        case .missingCaptureTimestamp:
            return "Environment photo is missing DateTimeOriginal / TIFF DateTime."
        case .timestampOutOfWindow(let capturedAt, let punchIn, let punchOut):
            return "Photo timestamp \(capturedAt.ISO8601Format()) is outside the meeting window \(punchIn.ISO8601Format()) … \(punchOut.addingTimeInterval(OfflineMeetingPolicy.photoTimestampLeeway).ISO8601Format())."
        case .missingAppleHardwareIndicators:
            return "Environment photo is missing Apple MakerNotes, lens, or sensor capture metadata."
        case .photoTooSmall(let width, let height):
            return "Environment photo \(width)×\(height) is below the \(OfflineMeetingPolicy.minimumPhotoEdge)×\(OfflineMeetingPolicy.minimumPhotoEdge) minimum."
        case .missingTimezoneOffset:
            return "Environment photo is missing OffsetTimeOriginal; timezone-naive timestamps are rejected."
        case .timezoneOffsetMismatch(let photoOffset, let systemOffset):
            return "Photo timezone offset \(Self.formatOffset(photoOffset)) is not UTC and does not match the system offset \(Self.formatOffset(systemOffset))."
        }
    }

    private static func formatOffset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let absolute = abs(seconds)
        return String(format: "%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)
    }
}

/// Observable EXIF facts extracted from the environment photo.
public struct MeetingPhotoValidation: Sendable, Equatable {
    public var make: String?
    public var model: String?
    public var software: String?
    public var capturedAt: Date
    public var isAppleCamera: Bool
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hasMakerAppleDictionary: Bool

    public init(
        make: String?,
        model: String?,
        software: String?,
        capturedAt: Date,
        isAppleCamera: Bool,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        hasMakerAppleDictionary: Bool = false
    ) {
        self.make = make
        self.model = model
        self.software = software
        self.capturedAt = capturedAt
        self.isAppleCamera = isAppleCamera
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hasMakerAppleDictionary = hasMakerAppleDictionary
    }
}

/// Inspects environment-photo binaries with ImageIO (`CGImageSourceCopyPropertiesAtIndex`).
public struct MeetingPhotoValidator: Sendable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func validate(
        imageData: Data,
        punchIn: Date,
        punchOut: Date
    ) throws -> MeetingPhotoValidation {
        guard !imageData.isEmpty else {
            throw MeetingPhotoValidationError.unreadableImage
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else {
            throw MeetingPhotoValidationError.unreadableImage
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw MeetingPhotoValidationError.unreadableImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              !properties.isEmpty
        else {
            throw MeetingPhotoValidationError.strippedMetadata
        }

        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] ?? [:]
        let makerApple = Self.makerAppleDictionary(from: properties)
        let hasMakerApple = (makerApple?.isEmpty == false)

        let pixelWidth = Self.intValue(
            properties[kCGImagePropertyPixelWidth as String]
                ?? exif[kCGImagePropertyExifPixelXDimension as String]
        )
        let pixelHeight = Self.intValue(
            properties[kCGImagePropertyPixelHeight as String]
                ?? exif[kCGImagePropertyExifPixelYDimension as String]
        )
        guard pixelWidth >= OfflineMeetingPolicy.minimumPhotoEdge,
              pixelHeight >= OfflineMeetingPolicy.minimumPhotoEdge
        else {
            throw MeetingPhotoValidationError.photoTooSmall(width: pixelWidth, height: pixelHeight)
        }

        let make = string(from: tiff[kCGImagePropertyTIFFMake as String] ?? properties[kCGImagePropertyTIFFMake as String])
        let model = string(from: tiff[kCGImagePropertyTIFFModel as String] ?? properties[kCGImagePropertyTIFFModel as String])
        let software = firstString([
            tiff[kCGImagePropertyTIFFSoftware as String],
            properties[kCGImagePropertyTIFFSoftware as String],
            png["Software"],
            exif["Software"],
        ])

        if let software, Self.isSoftwareEditor(software) {
            throw MeetingPhotoValidationError.softwareEdited(software)
        }

        let isApple = Self.isGenuineAppleCamera(make: make, model: model)
        guard isApple else {
            if make == nil && model == nil && tiff.isEmpty && exif.isEmpty {
                throw MeetingPhotoValidationError.strippedMetadata
            }
            throw MeetingPhotoValidationError.notAppleCamera(make: make, model: model)
        }

        let hasCaptureMetadata = Self.hasCameraCaptureMetadata(exif: exif, properties: properties)
        guard hasMakerApple || hasCaptureMetadata else {
            throw MeetingPhotoValidationError.missingAppleHardwareIndicators
        }

        let original = string(from: exif[kCGImagePropertyExifDateTimeOriginal as String])
        let tiffDate = string(from: tiff[kCGImagePropertyTIFFDateTime as String] ?? properties[kCGImagePropertyTIFFDateTime as String])
        guard original != nil || tiffDate != nil else {
            throw MeetingPhotoValidationError.missingCaptureTimestamp
        }

        let offset = string(from: exif[kCGImagePropertyExifOffsetTimeOriginal as String])
            ?? string(from: exif["OffsetTimeOriginal"])
            ?? string(from: exif[kCGImagePropertyExifOffsetTime as String])
            ?? string(from: exif["OffsetTime"])
        guard let offset else {
            throw MeetingPhotoValidationError.missingTimezoneOffset
        }
        guard let photoZone = Self.parseOffset(offset) else {
            throw MeetingPhotoValidationError.missingTimezoneOffset
        }
        guard let capturedAt = Self.parseExifDate(original ?? tiffDate, offset: offset, fallbackTimeZone: timeZone) else {
            throw MeetingPhotoValidationError.missingCaptureTimestamp
        }

        let photoOffset = photoZone.secondsFromGMT(for: capturedAt)
        let systemOffset = timeZone.secondsFromGMT(for: capturedAt)
        if photoOffset != 0 && photoOffset != systemOffset {
            throw MeetingPhotoValidationError.timezoneOffsetMismatch(
                photoOffset: photoOffset,
                systemOffset: systemOffset
            )
        }

        let windowEnd = punchOut.addingTimeInterval(OfflineMeetingPolicy.photoTimestampLeeway)
        if capturedAt < punchIn.addingTimeInterval(-1) || capturedAt > windowEnd.addingTimeInterval(1) {
            throw MeetingPhotoValidationError.timestampOutOfWindow(
                capturedAt: capturedAt,
                punchIn: punchIn,
                punchOut: punchOut
            )
        }

        return MeetingPhotoValidation(
            make: make,
            model: model,
            software: software,
            capturedAt: capturedAt,
            isAppleCamera: true,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            hasMakerAppleDictionary: hasMakerApple
        )
    }

    public static func isGenuineAppleCamera(make: String?, model: String?) -> Bool {
        let makeOK = (make ?? "").localizedCaseInsensitiveContains("apple")
        let modelValue = model ?? ""
        let modelOK = modelValue.localizedCaseInsensitiveContains("iphone")
            || modelValue.localizedCaseInsensitiveContains("ipad")
        return makeOK && modelOK
    }

    public static func isSoftwareEditor(_ software: String) -> Bool {
        let lowered = software.lowercased()
        let markers = [
            "photoshop",
            "adobe photoshop",
            "lightroom",
            "adobe lightroom",
            "gimp",
            "gnu image manipulation",
            "pixelmator",
            "affinity photo",
            "snapseed",
            "picsart",
            "paint.net",
            "imagemagick",
            "graphicsmagick",
            "corel",
            "capture one",
        ]
        return markers.contains { lowered.contains($0) }
    }

    public static func parseExifDate(
        _ raw: String?,
        offset: String?,
        fallbackTimeZone: TimeZone
    ) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let zone: TimeZone
        if let offset, let parsed = parseOffset(offset) {
            zone = parsed
        } else {
            zone = fallbackTimeZone
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let date = formatter.date(from: trimmed) {
            return date
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss.SSS"
        return formatter.date(from: trimmed)
    }

    public static func parseOffset(_ raw: String) -> TimeZone? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "Z" || trimmed == "z" {
            return TimeZone(secondsFromGMT: 0)
        }
        let pattern = /^([+-])(\d{2}):?(\d{2})$/
        guard let match = trimmed.firstMatch(of: pattern),
              let hours = Int(match.2),
              let minutes = Int(match.3)
        else {
            return nil
        }
        let sign = match.1 == "-" ? -1 : 1
        let seconds = sign * ((hours * 3600) + (minutes * 60))
        guard abs(seconds) <= 14 * 3600 else {
            return nil
        }
        return TimeZone(secondsFromGMT: seconds)
    }

    public static func hasCameraCaptureMetadata(exif: [String: Any], properties: [String: Any]) -> Bool {
        let lensModel = stringValue(
            exif[kCGImagePropertyExifLensModel as String] ?? properties[kCGImagePropertyExifLensModel as String]
        )
        let focal = exif[kCGImagePropertyExifFocalLength as String]
            ?? properties[kCGImagePropertyExifFocalLength as String]
        let iso = exif[kCGImagePropertyExifISOSpeedRatings as String]
            ?? properties[kCGImagePropertyExifISOSpeedRatings as String]
        let fNumber = exif[kCGImagePropertyExifFNumber as String]
        let exposure = exif[kCGImagePropertyExifExposureTime as String]
        let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]
        let signals = [lensModel != nil, focal != nil, iso != nil, fNumber != nil, exposure != nil, focal35 != nil]
        return signals.filter { $0 }.count >= 2
    }

    public static func makerAppleDictionary(from properties: [String: Any]) -> [String: Any]? {
        if let apple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
           !apple.isEmpty {
            return apple
        }
        if let apple = properties["{MakerApple}"] as? [String: Any], !apple.isEmpty {
            return apple
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let number = value as? Int {
            return number
        }
        if let number = value as? Double {
            return Int(number)
        }
        return 0
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func string(from value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func firstString(_ values: [Any?]) -> String? {
        for value in values {
            if let text = string(from: value) {
                return text
            }
        }
        return nil
    }
}

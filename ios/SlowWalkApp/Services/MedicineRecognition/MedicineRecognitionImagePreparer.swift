import Foundation
import ImageIO
import SlowWalkClientCore
import UIKit
import UniformTypeIdentifiers

nonisolated struct PreparedMedicineRecognitionImage: Sendable, Equatable {
    static let jpegMIMEType = "image/jpeg"

    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String = jpegMIMEType) {
        self.data = data
        self.mimeType = mimeType
    }
}

nonisolated enum MedicineRecognitionImagePreparationError:
    Error,
    Sendable,
    Equatable
{
    case invalidImage
    case imageTooLarge
}

nonisolated protocol MedicineRecognitionImagePreparing: Sendable {
    func prepare(
        _ input: OCRImageInput
    ) async throws -> PreparedMedicineRecognitionImage
}

/// Produces the bounded, orientation-normalized image sent to the recognition
/// API. The source bytes are scoped to this call and are never logged or kept
/// on the preparer.
nonisolated struct MedicineRecognitionImagePreparer:
    MedicineRecognitionImagePreparing,
    Sendable
{
    struct Configuration: Sendable {
        static let standard = Configuration()

        let maximumPixelDimension: Int
        let maximumOutputByteCount: Int
        let minimumPixelDimension: Int
        let maximumResizeAttempts: Int
        let resizeFactor: CGFloat
        let compressionQualities: [CGFloat]

        init(
            maximumPixelDimension: Int = 2_048,
            maximumOutputByteCount: Int = 4 * 1_024 * 1_024,
            minimumPixelDimension: Int = 320,
            maximumResizeAttempts: Int = 6,
            resizeFactor: CGFloat = 0.8,
            compressionQualities: [CGFloat] = [
                0.88, 0.76, 0.64, 0.52, 0.4,
            ]
        ) {
            precondition(maximumPixelDimension > 0)
            precondition(maximumOutputByteCount > 0)
            precondition(minimumPixelDimension > 0)
            precondition(minimumPixelDimension <= maximumPixelDimension)
            precondition(maximumResizeAttempts >= 0)
            precondition(resizeFactor > 0 && resizeFactor < 1)
            precondition(!compressionQualities.isEmpty)
            precondition(compressionQualities.allSatisfy { (0 ... 1).contains($0) })

            self.maximumPixelDimension = maximumPixelDimension
            self.maximumOutputByteCount = maximumOutputByteCount
            self.minimumPixelDimension = minimumPixelDimension
            self.maximumResizeAttempts = maximumResizeAttempts
            self.resizeFactor = resizeFactor
            self.compressionQualities = compressionQualities
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    func prepare(
        _ input: OCRImageInput
    ) async throws -> PreparedMedicineRecognitionImage {
        try await Self.prepareOffActor(input, configuration: configuration)
    }

    @concurrent
    private static func prepareOffActor(
        _ input: OCRImageInput,
        configuration: Configuration
    ) async throws -> PreparedMedicineRecognitionImage {
        try Task.checkCancellation()
        guard !input.data.isEmpty else {
            throw MedicineRecognitionImagePreparationError.invalidImage
        }

        let decodedImage = try decodeThumbnail(
            from: input.data,
            maximumPixelDimension: configuration.maximumPixelDimension
        )
        try Task.checkCancellation()

        var image = try render(
            decodedImage,
            orientation: input.orientation,
            maximumPixelDimension: configuration.maximumPixelDimension
        )
        try Task.checkCancellation()

        for resizeAttempt in 0 ... configuration.maximumResizeAttempts {
            for quality in configuration.compressionQualities {
                try Task.checkCancellation()
                guard let encoded = encodeJPEG(image, quality: quality) else {
                    throw MedicineRecognitionImagePreparationError.invalidImage
                }
                try Task.checkCancellation()
                if encoded.count <= configuration.maximumOutputByteCount {
                    return PreparedMedicineRecognitionImage(data: encoded)
                }
            }

            guard resizeAttempt < configuration.maximumResizeAttempts,
                  let nextSize = nextSmallerSize(
                      for: image.size,
                      configuration: configuration
                  )
            else {
                throw MedicineRecognitionImagePreparationError.imageTooLarge
            }

            image = try renderUpImage(image, size: nextSize)
            try Task.checkCancellation()
        }

        throw MedicineRecognitionImagePreparationError.imageTooLarge
    }

    private static func decodeThumbnail(
        from data: Data,
        maximumPixelDimension: Int
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ),
            CGImageSourceGetCount(source) > 0,
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else {
            throw MedicineRecognitionImagePreparationError.invalidImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ),
            image.width > 0,
            image.height > 0
        else {
            throw MedicineRecognitionImagePreparationError.invalidImage
        }
        return image
    }

    private static func render(
        _ image: CGImage,
        orientation: OCRImageOrientation,
        maximumPixelDimension: Int
    ) throws -> UIImage {
        let swapsDimensions = orientation.swapsPixelDimensions
        let orientedWidth = swapsDimensions ? image.height : image.width
        let orientedHeight = swapsDimensions ? image.width : image.height
        let scale = min(
            1,
            CGFloat(maximumPixelDimension)
                / CGFloat(max(orientedWidth, orientedHeight))
        )
        let size = CGSize(
            width: max(1, floor(CGFloat(orientedWidth) * scale)),
            height: max(1, floor(CGFloat(orientedHeight) * scale))
        )

        let source = UIImage(
            cgImage: image,
            scale: 1,
            orientation: orientation.uiImageOrientation
        )
        return try render(source, size: size)
    }

    private static func renderUpImage(
        _ image: UIImage,
        size: CGSize
    ) throws -> UIImage {
        guard let cgImage = image.cgImage else {
            throw MedicineRecognitionImagePreparationError.invalidImage
        }
        return try render(
            UIImage(cgImage: cgImage, scale: 1, orientation: .up),
            size: size
        )
    }

    private static func render(
        _ image: UIImage,
        size: CGSize
    ) throws -> UIImage {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width >= 1,
              size.height >= 1
        else {
            throw MedicineRecognitionImagePreparationError.invalidImage
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let bounds = CGRect(origin: .zero, size: size)
        let rendered = UIGraphicsImageRenderer(
            size: size,
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            image.draw(in: bounds)
        }
        guard rendered.cgImage != nil else {
            throw MedicineRecognitionImagePreparationError.invalidImage
        }
        return rendered
    }

    private static func encodeJPEG(
        _ image: UIImage,
        quality: CGFloat
    ) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            cgImage,
            [
                kCGImageDestinationLossyCompressionQuality: quality,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func nextSmallerSize(
        for size: CGSize,
        configuration: Configuration
    ) -> CGSize? {
        let currentLongest = max(size.width, size.height)
        let minimumLongest = min(
            currentLongest,
            CGFloat(configuration.minimumPixelDimension)
        )
        guard currentLongest > minimumLongest else { return nil }

        let nextLongest = max(
            minimumLongest,
            floor(currentLongest * configuration.resizeFactor)
        )
        guard nextLongest < currentLongest else { return nil }

        let scale = nextLongest / currentLongest
        return CGSize(
            width: max(1, floor(size.width * scale)),
            height: max(1, floor(size.height * scale))
        )
    }
}

private extension OCRImageOrientation {
    nonisolated var swapsPixelDimensions: Bool {
        switch self {
        case .left, .right, .leftMirrored, .rightMirrored:
            true
        case .up, .down, .upMirrored, .downMirrored:
            false
        }
    }

    nonisolated var uiImageOrientation: UIImage.Orientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        }
    }
}

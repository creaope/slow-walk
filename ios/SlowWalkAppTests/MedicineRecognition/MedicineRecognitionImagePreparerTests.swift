import Foundation
import ImageIO
import SlowWalkClientCore
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import SlowWalkApp

@Suite(.serialized)
struct MedicineRecognitionImagePreparerTests {
    private enum CornerColor: CaseIterable {
        case red
        case green
        case blue
        case yellow

        var rgb: (Int, Int, Int) {
            switch self {
            case .red: (245, 30, 30)
            case .green: (30, 190, 50)
            case .blue: (30, 50, 235)
            case .yellow: (245, 215, 30)
            }
        }

        var uiColor: UIColor {
            let (red, green, blue) = rgb
            return UIColor(
                red: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
        }
    }

    private struct OrientationExpectation {
        let orientation: OCRImageOrientation
        let width: Int
        let height: Int
        let corners: [CornerColor]
    }

    @Test func producesBoundedJPEGWithStableMIMEType() async throws {
        let prepared = try await MedicineRecognitionImagePreparer().prepare(
            input(data: makeQuadrantPNG())
        )

        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.data.count <= 4 * 1_024 * 1_024)
        #expect(Array(prepared.data.prefix(3)) == [0xFF, 0xD8, 0xFF])
        #expect(decodedImage(prepared.data) != nil)
    }

    @Test func inputOrientationIsPhysicallyAppliedForAllEightCases() async throws {
        let source = makeQuadrantPNG(width: 120, height: 80)
        let expectations = [
            OrientationExpectation(
                orientation: .up,
                width: 120,
                height: 80,
                corners: [.red, .green, .blue, .yellow]
            ),
            OrientationExpectation(
                orientation: .upMirrored,
                width: 120,
                height: 80,
                corners: [.green, .red, .yellow, .blue]
            ),
            OrientationExpectation(
                orientation: .down,
                width: 120,
                height: 80,
                corners: [.yellow, .blue, .green, .red]
            ),
            OrientationExpectation(
                orientation: .downMirrored,
                width: 120,
                height: 80,
                corners: [.blue, .yellow, .red, .green]
            ),
            OrientationExpectation(
                orientation: .leftMirrored,
                width: 80,
                height: 120,
                corners: [.red, .blue, .green, .yellow]
            ),
            OrientationExpectation(
                orientation: .right,
                width: 80,
                height: 120,
                corners: [.blue, .red, .yellow, .green]
            ),
            OrientationExpectation(
                orientation: .rightMirrored,
                width: 80,
                height: 120,
                corners: [.yellow, .green, .blue, .red]
            ),
            OrientationExpectation(
                orientation: .left,
                width: 80,
                height: 120,
                corners: [.green, .yellow, .red, .blue]
            ),
        ]

        for expectation in expectations {
            let prepared = try await MedicineRecognitionImagePreparer().prepare(
                input(data: source, orientation: expectation.orientation)
            )
            let image = try #require(decodedImage(prepared.data))
            #expect(image.width == expectation.width)
            #expect(image.height == expectation.height)
            #expect(sampledCorners(of: image) == expectation.corners)
        }
    }

    @Test func downsamplesLongestPixelDimensionBeforeUpload() async throws {
        let source = makeSolidPNG(
            width: 3_000,
            height: 900,
            color: .systemTeal
        )

        let prepared = try await MedicineRecognitionImagePreparer().prepare(
            input(data: source, orientation: .right)
        )
        let image = try #require(decodedImage(prepared.data))

        #expect(max(image.width, image.height) <= 2_048)
        #expect(image.height == 2_048)
        #expect(image.width > 0)
    }

    @Test func inputOrientationOverridesConflictingEmbeddedMetadata() async throws {
        let source = makeQuadrantJPEG(embeddedOrientation: 3)

        let prepared = try await MedicineRecognitionImagePreparer().prepare(
            input(data: source, orientation: .up)
        )
        let image = try #require(decodedImage(prepared.data))
        let properties = outputProperties(prepared.data)

        #expect(sampledCorners(of: image) == [.red, .green, .blue, .yellow])
        #expect((properties?[kCGImagePropertyOrientation] as? Int) ?? 1 == 1)
    }

    @Test func transparentPixelsAreCompositedOntoWhite() async throws {
        let source = makeTransparentPNG()

        let prepared = try await MedicineRecognitionImagePreparer().prepare(
            input(data: source)
        )
        let image = try #require(decodedImage(prepared.data))
        let pixel = rgbaPixels(of: image).pixel(x: 5, y: 5)

        #expect(pixel.red >= 245)
        #expect(pixel.green >= 245)
        #expect(pixel.blue >= 245)
        #expect(pixel.alpha == 255)
    }

    @Test func rejectsEmptyAndDamagedInputAsInvalidImage() async {
        for bytes in [Data(), Data([0x89, 0x50, 0x4E, 0x47, 0x0D])] {
            do {
                _ = try await MedicineRecognitionImagePreparer().prepare(
                    input(data: bytes)
                )
                Issue.record("expected invalid image rejection")
            } catch let error as MedicineRecognitionImagePreparationError {
                #expect(error == .invalidImage)
            } catch {
                Issue.record("unexpected error: \(type(of: error))")
            }
        }
    }

    @Test func highEntropyImageRemainsWithinUploadLimit() async throws {
        let source = makeHighEntropyPNG(width: 2_048, height: 2_048)

        let prepared = try await MedicineRecognitionImagePreparer().prepare(
            input(data: source)
        )
        let image = try #require(decodedImage(prepared.data))

        #expect(prepared.data.count <= 4 * 1_024 * 1_024)
        #expect(max(image.width, image.height) <= 2_048)
    }

    @Test func reportsImageTooLargeAfterBoundedCompressionAttempts() async {
        let configuration = MedicineRecognitionImagePreparer.Configuration(
            maximumPixelDimension: 128,
            maximumOutputByteCount: 32,
            minimumPixelDimension: 32,
            maximumResizeAttempts: 1
        )
        let preparer = MedicineRecognitionImagePreparer(
            configuration: configuration
        )

        do {
            _ = try await preparer.prepare(input(data: makeQuadrantPNG()))
            Issue.record("expected image-too-large rejection")
        } catch let error as MedicineRecognitionImagePreparationError {
            #expect(error == .imageTooLarge)
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
    }

    @Test func propagatesCancellation() async {
        let source = makeQuadrantPNG(width: 600, height: 400)
        let preparer = MedicineRecognitionImagePreparer()
        let task = Task {
            await Task.yield()
            return try await preparer.prepare(input(data: source))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation is not collapsed into an image error.
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
    }

    private func input(
        data: Data,
        orientation: OCRImageOrientation = .up
    ) -> OCRImageInput {
        OCRImageInput(
            data: data,
            orientation: orientation,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeQuadrantPNG(
        width: Int = 120,
        height: Int = 80
    ) -> Data {
        let size = CGSize(width: width, height: height)
        let image = renderer(size: size, opaque: true).image { context in
            let halfWidth = CGFloat(width) / 2
            let halfHeight = CGFloat(height) / 2
            let entries: [(CornerColor, CGRect)] = [
                (.red, CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight)),
                (
                    .green,
                    CGRect(
                        x: halfWidth,
                        y: 0,
                        width: halfWidth,
                        height: halfHeight
                    )
                ),
                (
                    .blue,
                    CGRect(
                        x: 0,
                        y: halfHeight,
                        width: halfWidth,
                        height: halfHeight
                    )
                ),
                (
                    .yellow,
                    CGRect(
                        x: halfWidth,
                        y: halfHeight,
                        width: halfWidth,
                        height: halfHeight
                    )
                ),
            ]
            for (color, rect) in entries {
                color.uiColor.setFill()
                context.fill(rect)
            }
        }
        return image.pngData()!
    }

    private func makeSolidPNG(
        width: Int,
        height: Int,
        color: UIColor
    ) -> Data {
        let size = CGSize(width: width, height: height)
        let image = renderer(size: size, opaque: true).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()!
    }

    private func makeQuadrantJPEG(embeddedOrientation: Int) -> Data {
        let png = makeQuadrantPNG()
        let image = decodedImage(png)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImagePropertyOrientation: embeddedOrientation,
                kCGImageDestinationLossyCompressionQuality: 0.95,
            ] as CFDictionary
        )
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makeTransparentPNG() -> Data {
        let size = CGSize(width: 100, height: 80)
        let image = renderer(size: size, opaque: false).image { context in
            context.cgContext.clear(CGRect(origin: .zero, size: size))
            UIColor.red.setFill()
            context.fill(CGRect(x: 30, y: 20, width: 40, height: 40))
        }
        return image.pngData()!
    }

    private func makeHighEntropyPNG(width: Int, height: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt32 = 0xA341_316C
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[offset] = UInt8(truncatingIfNeeded: state)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 16)
            bytes[offset + 3] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let image = bytes.withUnsafeMutableBytes { buffer -> CGImage in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            return context.makeImage()!
        }
        return UIImage(cgImage: image).pngData()!
    }

    private func renderer(
        size: CGSize,
        opaque: Bool
    ) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    private func decodedImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func outputProperties(_ data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
    }

    private func sampledCorners(of image: CGImage) -> [CornerColor] {
        let pixels = rgbaPixels(of: image)
        let quarterX = image.width / 4
        let quarterY = image.height / 4
        let samples = [
            pixels.pixel(x: quarterX, y: quarterY),
            pixels.pixel(x: image.width - quarterX - 1, y: quarterY),
            pixels.pixel(x: quarterX, y: image.height - quarterY - 1),
            pixels.pixel(
                x: image.width - quarterX - 1,
                y: image.height - quarterY - 1
            ),
        ]
        return samples.map { sample in
            CornerColor.allCases.min { lhs, rhs in
                sample.distanceSquared(to: lhs.rgb)
                    < sample.distanceSquared(to: rhs.rgb)
            }!
        }
    }

    private func rgbaPixels(of image: CGImage) -> PixelBuffer {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * image.height
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
        }
        return PixelBuffer(
            bytes: bytes,
            width: image.width,
            height: image.height
        )
    }
}

private struct PixelBuffer {
    struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int

        func distanceSquared(to other: (Int, Int, Int)) -> Int {
            let redDistance = red - other.0
            let greenDistance = green - other.1
            let blueDistance = blue - other.2
            return redDistance * redDistance
                + greenDistance * greenDistance
                + blueDistance * blueDistance
        }
    }

    let bytes: [UInt8]
    let width: Int
    let height: Int

    func pixel(x: Int, y: Int) -> Pixel {
        precondition((0 ..< width).contains(x))
        precondition((0 ..< height).contains(y))
        let offset = (y * width + x) * 4
        return Pixel(
            red: Int(bytes[offset]),
            green: Int(bytes[offset + 1]),
            blue: Int(bytes[offset + 2]),
            alpha: Int(bytes[offset + 3])
        )
    }
}

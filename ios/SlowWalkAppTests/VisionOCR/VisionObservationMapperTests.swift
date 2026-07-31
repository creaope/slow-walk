import Foundation
import SlowWalkClientCore
import Testing

@testable import SlowWalkApp

@Suite("Vision OCR normalization")
struct VisionObservationMapperTests {
    @Test func normalizesAndSortsTopToBottomThenLeftToRight() {
        let mapper = VisionObservationNormalizer()
        let observedAt = Date(timeIntervalSince1970: 100)

        let observations = [
            RecognizedTextObservation(
                text: "  Second row  ",
                confidence: 0.6,
                boundingRegion: OCRBoundingRegion(
                    x: 0.1,
                    y: 0.5,
                    width: 0.2,
                    height: 0.1
                ),
                languageCode: "zh-Hans",
                observedAt: observedAt
            ),
            RecognizedTextObservation(
                text: "First row right",
                confidence: 0.7,
                boundingRegion: OCRBoundingRegion(
                    x: 0.7,
                    y: 0.1,
                    width: 0.2,
                    height: 0.1
                ),
                languageCode: "zh-Hans",
                observedAt: observedAt
            ),
            RecognizedTextObservation(
                text: "First row left",
                confidence: 0.8,
                boundingRegion: OCRBoundingRegion(
                    x: 0.1,
                    y: 0.1,
                    width: 0.2,
                    height: 0.1
                ),
                languageCode: "zh-Hans",
                observedAt: observedAt
            ),
        ]

        let normalized = mapper.normalize(observations)

        #expect(normalized.map(\.text) == [
            "First row left",
            "First row right",
            "Second row",
        ])
        #expect(normalized.map(\.confidence) == [0.8, 0.7, 0.6])
    }

    @Test func dropsEmptyTextAndClampsConfidence() {
        let mapper = VisionObservationNormalizer()
        let observedAt = Date(timeIntervalSince1970: 100)

        let normalized = mapper.normalize([
            RecognizedTextObservation(
                text: " \n ",
                confidence: 2,
                boundingRegion: nil,
                languageCode: " ",
                observedAt: observedAt
            ),
            RecognizedTextObservation(
                text: "kept",
                confidence: -1,
                boundingRegion: nil,
                languageCode: " zh-Hans ",
                observedAt: observedAt
            ),
        ])

        #expect(normalized.count == 1)
        #expect(normalized[0].text == "kept")
        #expect(normalized[0].confidence == 0)
        #expect(normalized[0].languageCode == "zh-Hans")
    }

    @Test func recognizerRejectsEmptyImage() async {
        let recognizer = AppleVisionMedicineTextRecognizer()
        let input = OCRImageInput(
            data: Data(),
            orientation: .up,
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        do {
            _ = try await recognizer.recognizeText(in: input)
            Issue.record("empty image data must be rejected")
        } catch let error as AppleVisionMedicineTextRecognizer.Failure {
            #expect(error == .emptyImageData)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

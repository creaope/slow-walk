import Foundation
import SlowWalkClientCore

/// Normalizes raw OCR observations into a deterministic persistence order
/// without creating any medicine meaning.
struct VisionObservationNormalizer: Sendable {
    struct NormalizedObservation: Sendable, Equatable {
        let text: String
        let confidence: Double
        let boundingRegion: OCRBoundingRegion?
        let languageCode: String?
        let observedAt: Date
    }

    func normalize(
        _ observations: [RecognizedTextObservation]
    ) -> [NormalizedObservation] {
        observations
            .map {
                let confidence = $0.confidence
                return NormalizedObservation(
                    text: $0.text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    confidence: confidence.isFinite
                        ? min(max(confidence, 0), 1)
                        : 0,
                    boundingRegion: $0.boundingRegion,
                    languageCode: $0.languageCode?
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ),
                    observedAt: $0.observedAt
                )
            }
            .filter { !$0.text.isEmpty }
            .sorted(by: Self.isOrderedBefore)
    }

    private static func isOrderedBefore(
        _ lhs: NormalizedObservation,
        _ rhs: NormalizedObservation
    ) -> Bool {
        switch (lhs.boundingRegion, rhs.boundingRegion) {
        case let (left?, right?):
            for (leftValue, rightValue) in [
                (left.y, right.y),
                (left.x, right.x),
                (left.height, right.height),
                (left.width, right.width),
            ] {
                let comparison = compare(leftValue, rightValue)
                if comparison != 0 {
                    return comparison < 0
                }
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        if lhs.observedAt != rhs.observedAt {
            return lhs.observedAt < rhs.observedAt
        }
        if lhs.text != rhs.text { return lhs.text < rhs.text }
        let leftLanguage = lhs.languageCode ?? ""
        let rightLanguage = rhs.languageCode ?? ""
        if leftLanguage != rightLanguage {
            return leftLanguage < rightLanguage
        }
        return compare(lhs.confidence, rhs.confidence) < 0
    }

    /// NaN-safe comparison aligned with the Client Core OCR mapper so cache
    /// order cannot drift from assessment order on malformed coordinates.
    private static func compare(
        _ lhs: Double,
        _ rhs: Double
    ) -> Int {
        if lhs == rhs {
            return 0
        }
        if lhs.isNaN || rhs.isNaN {
            if lhs.bitPattern == rhs.bitPattern {
                return 0
            }
            return lhs.bitPattern < rhs.bitPattern ? -1 : 1
        }
        return lhs < rhs ? -1 : 1
    }
}

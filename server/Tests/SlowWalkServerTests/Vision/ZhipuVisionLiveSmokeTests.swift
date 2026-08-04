import Foundation
@testable import SlowWalkServer
import XCTest

final class ZhipuVisionLiveSmokeTests: XCTestCase, @unchecked Sendable {
    func testLiveZhipuVisionRequest() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_ZHIPU_LIVE_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set RUN_ZHIPU_LIVE_SMOKE=1 to explicitly enable network access."
            )
        }

        let client = try ZhipuVisionClient(environment: environment)
        let result = try await client.extractVisibleTexts(
            from: VisionImagePayload(
                data: try XCTUnwrap(Data(base64Encoded: Self.syntheticPNG)),
                mimeType: "image/png"
            )
        )

        _ = result.imageReadable
        XCTAssertLessThanOrEqual(
            result.visibleTexts.count,
            VisionVisibleTextResult.maximumVisibleTextCount
        )
    }

    /// A synthetic 32-by-32 checkerboard with no sensitive content.
    private static let syntheticPNG =
        "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAAAAABWESUoAAAAIElEQVR42mP4"
        + "DwUMUIDOZxghCkaYd3EqGE0Po+kBiQ8AIcT+EHESaBMAAAAASUVORK5CYII="
}

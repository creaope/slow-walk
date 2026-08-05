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

        let fixture = try Self.loadFixture()
        let client = try ZhipuVisionClient(environment: environment)
        let result = try await client.extractVisibleTexts(
            from: VisionImagePayload(
                data: fixture.imageData,
                mimeType: fixture.asset.mimeType
            )
        )
        try Self.validate(result)
    }

    func testFixtureUsesApprovedMedicineAsset() throws {
        let fixture = try Self.loadFixture()
        XCTAssertEqual(fixture.asset.id, "acetaminophen-clean-v1")
        XCTAssertGreaterThan(fixture.imageData.count, 100_000)
    }

    func testSmokeResultValidationRejectsMissingRequiredOutput() throws {
        let cases: [(Bool, [String], SmokeValidationError)] = [
            (false, ["ACETAMINOPHEN", "500 mg"], .imageNotReadable),
            (true, [], .emptyVisibleTexts),
            (true, ["500 mg"], .missingAcetaminophen),
            (true, ["ACETAMINOPHEN"], .missingStrength),
            (true, ["ACET AMINOPHEN", "500 mg"], .missingAcetaminophen),
            (true, ["ACETAMINOPHEN", "500 m g"], .missingStrength),
        ]
        for (imageReadable, visibleTexts, expectedError) in cases {
            let result = try Self.makeResult(
                imageReadable: imageReadable, visibleTexts: visibleTexts
            )
            XCTAssertThrowsError(try Self.validate(result)) { error in
                XCTAssertEqual(error as? SmokeValidationError, expectedError)
            }
        }
        XCTAssertNoThrow(try Self.validate(try Self.makeResult(
            imageReadable: true,
            visibleTexts: ["acetaminophen", "500", "MG"]
        )))
    }

    func testSmokeResultValidationAcceptsConsecutiveWhitespace() throws {
        XCTAssertNoThrow(try Self.validate(try Self.makeResult(
            imageReadable: true,
            visibleTexts: [
                "  ACETAMINOPHEN   ",
                "\n500\t\tmg\n",
            ]
        )))
    }

    func testSmokeResultValidationAcceptsCombinedText() throws {
        XCTAssertNoThrow(try Self.validate(try Self.makeResult(
            imageReadable: true,
            visibleTexts: ["ACETAMINOPHEN 500 mg"]
        )))
    }

    private static func loadFixture() throws -> (asset: MedicineAssetManifest.Asset, imageData: Data) {
        let manifestURL = try findManifestURL()
        let manifest = try JSONDecoder().decode(
            MedicineAssetManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        guard manifest.schemaVersion == 1 else {
            throw FixtureError.invalidSchemaVersion
        }
        guard let asset = manifest.assets.first(
            where: { $0.id == "acetaminophen-clean-v1" }
        ) else {
            throw FixtureError.assetNotFound
        }
        guard asset.synthetic else {
            throw FixtureError.assetNotSynthetic
        }
        guard asset.approvedForRecording else {
            throw FixtureError.assetNotApprovedForRecording
        }
        guard asset.expectedReadable else {
            throw FixtureError.assetNotExpectedReadable
        }
        guard asset.mimeType == "image/png" else {
            throw FixtureError.invalidMimeType
        }
        let imageURL = manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(asset.file)
        return (asset, try Data(contentsOf: imageURL))
    }

    private static func findManifestURL(
        sourceFile: StaticString = #filePath
    ) throws -> URL {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: String(describing: sourceFile))
            .deletingLastPathComponent()

        while true {
            let candidate = directory.appendingPathComponent(
                "shared/demo-assets/medicine/manifest.json"
            )
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }

            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { break }
            directory = parent
        }
        throw FixtureError.manifestNotFound
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func validate(_ result: VisionVisibleTextResult) throws {
        guard result.imageReadable else {
            throw SmokeValidationError.imageNotReadable
        }
        guard !result.visibleTexts.isEmpty else {
            throw SmokeValidationError.emptyVisibleTexts
        }
        let text = normalize(result.visibleTexts.joined(separator: " "))
        guard text.contains(normalize("ACETAMINOPHEN")) else {
            throw SmokeValidationError.missingAcetaminophen
        }
        guard text.contains(normalize("500 mg")) else {
            throw SmokeValidationError.missingStrength
        }
    }

    private static func makeResult(
        imageReadable: Bool,
        visibleTexts: [String]
    ) throws -> VisionVisibleTextResult {
        let object: [String: Any] = [
            "visibleTexts": visibleTexts,
            "imageReadable": imageReadable,
            "uncertainRegionsPresent": false,
        ]
        return try JSONDecoder().decode(
            VisionVisibleTextResult.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private struct MedicineAssetManifest: Decodable {
        let schemaVersion: Int
        let assets: [Asset]

        struct Asset: Decodable {
            let id: String
            let file: String
            let synthetic: Bool
            let approvedForRecording: Bool
            let expectedVisibleTexts: [String]
            let expectedReadable: Bool
            let mimeType: String
        }
    }

    private enum FixtureError: Error {
        case manifestNotFound, invalidSchemaVersion, assetNotFound, invalidMimeType
        case assetNotSynthetic, assetNotApprovedForRecording, assetNotExpectedReadable
    }

    private enum SmokeValidationError: Error, Equatable {
        case imageNotReadable, emptyVisibleTexts, missingAcetaminophen, missingStrength
    }
}

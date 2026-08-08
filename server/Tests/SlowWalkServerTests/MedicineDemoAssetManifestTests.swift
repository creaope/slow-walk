import Foundation
import XCTest

final class MedicineDemoAssetManifestTests: XCTestCase {
    func testSharedManifestIsStableAndConsumableByServerTests() throws {
        let manifestURL = try locateManifest()
        let manifest = try JSONDecoder().decode(
            MedicineDemoAssetManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(
            manifest.assets.map(\.id),
            manifest.assets.map(\.id).sorted()
        )
        XCTAssertEqual(Set(manifest.assets.map(\.id)).count, 4)
        XCTAssertTrue(manifest.assets.allSatisfy(\.synthetic))

        let approved = manifest.assets.filter(\.approvedForRecording)
        XCTAssertEqual(approved.map(\.id), ["acetaminophen-clean-v1"])
        XCTAssertEqual(
            approved.first?.expectedCanonicalMedicineID,
            "demo-acetaminophen"
        )

        let ambiguous = try XCTUnwrap(
            manifest.assets.first {
                $0.id == "cold-relief-ambiguous-v1"
            }
        )
        XCTAssertTrue(ambiguous.expectedAmbiguous)
        XCTAssertNil(ambiguous.expectedCanonicalMedicineID)

        let assetRoot = manifestURL.deletingLastPathComponent()
            .standardizedFileURL
        for asset in manifest.assets {
            XCTAssertFalse(asset.expectedVisibleTexts.isEmpty, asset.id)
            XCTAssertEqual(asset.mimeType, "image/png", asset.id)
            XCTAssertLessThanOrEqual(asset.width, 1_600, asset.id)
            XCTAssertLessThanOrEqual(asset.height, 1_200, asset.id)
            XCTAssertFalse(asset.file.hasPrefix("/"), asset.id)
            XCTAssertFalse(
                asset.file.split(separator: "/").contains(".."),
                asset.id
            )
            let fileURL = assetRoot.appendingPathComponent(asset.file)
                .standardizedFileURL
            XCTAssertTrue(
                fileURL.path.hasPrefix(assetRoot.path + "/"),
                asset.id
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fileURL.path),
                asset.id
            )
        }
    }

    private func locateManifest() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let relativePath = "shared/demo-assets/medicine/manifest.json"

        for _ in 0 ... 8 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }

        throw NSError(
            domain: "MedicineDemoAssetManifestTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not locate repository asset manifest at \(relativePath)",
            ]
        )
    }
}

private struct MedicineDemoAssetManifest: Decodable {
    let schemaVersion: Int
    let assets: [MedicineDemoAsset]
}

private struct MedicineDemoAsset: Decodable {
    let id: String
    let file: String
    let sha256: String
    let synthetic: Bool
    let approvedForRecording: Bool
    let expectedVisibleTexts: [String]
    let expectedCanonicalMedicineID: String?
    let purpose: String
    let expectedReadable: Bool
    let expectedAmbiguous: Bool
    let generatedBy: String
    let generatorVersion: String
    let width: Int
    let height: Int
    let mimeType: String
}

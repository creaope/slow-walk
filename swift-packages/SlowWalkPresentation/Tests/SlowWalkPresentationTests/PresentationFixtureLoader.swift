import Foundation
import SlowWalkAPIContracts
import XCTest

/// Loads the repository's canonical Medicine demo fixtures.
///
/// `demo-fixtures/` is the single source of truth and is located by walking
/// upward from this file looking for `demo-fixtures/README.md`, matching the
/// stable anchor strategy used by the server golden tests. No second copy of
/// the JSON exists in this package.
///
/// A missing or unreadable fixture is a broken checkout and always fails a
/// test. `XCTSkip` is never used, so a fixture that disappears cannot hide.
enum PresentationFixtureLoader {
    static let maximumAnchorSearchDepth = 8
    static let anchorRelativePath = "demo-fixtures/README.md"

    static func fixtureDirectory() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        var searched = [directory.path]

        for _ in 0 ... maximumAnchorSearchDepth {
            let anchor = directory.appendingPathComponent(
                anchorRelativePath
            )
            if FileManager.default.fileExists(
                atPath: anchor.path
            ) {
                return directory.appendingPathComponent(
                    "demo-fixtures"
                )
            }
            directory.deleteLastPathComponent()
            searched.append(directory.path)
        }

        throw PresentationFixtureError.anchorNotFound(
            anchor: anchorRelativePath,
            searchedDirectories: searched
        )
    }

    static func load(
        _ filename: String
    ) throws -> PresentationFixturePayload {
        let directory = try fixtureDirectory()
        let fileURL = directory.appendingPathComponent(
            filename
        )
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            throw PresentationFixtureError.fixtureMissing(
                fixture: filename,
                directory: directory.path
            )
        }
        let data = try Data(contentsOf: fileURL)
        do {
            return try SlowWalkJSONCoding.makeDecoder()
                .decode(
                    PresentationFixturePayload.self,
                    from: data
                )
        } catch {
            throw PresentationFixtureError
                .fixtureUndecodable(
                    fixture: filename,
                    directory: directory.path,
                    underlying: error
                )
        }
    }

    /// Every JSON fixture, in the order the README table lists them.
    static let allJSONFixtureFilenames = [
        "medicine-normal.json",
        "medicine-ambiguous.json",
        "medicine-health-warning.json",
        "medicine-source-warning.json",
        "medicine-red-risk.json",
    ]

    static func loadAll() throws
        -> [PresentationFixturePayload]
    {
        try allJSONFixtureFilenames.map(load)
    }
}

enum PresentationFixtureError:
    Error,
    CustomStringConvertible
{
    case anchorNotFound(
        anchor: String,
        searchedDirectories: [String]
    )
    case fixtureMissing(fixture: String, directory: String)
    case fixtureUndecodable(
        fixture: String,
        directory: String,
        underlying: any Error
    )

    var description: String {
        switch self {
        case let .anchorNotFound(anchor, searched):
            return """
                Could not locate the repository anchor \
                "\(anchor)". Searched upward through: \
                \(searched.joined(separator: " -> ")). \
                Run tests from a complete repository checkout.
                """
        case let .fixtureMissing(fixture, directory):
            return """
                Demo fixture "\(fixture)" is missing from \
                \(directory). The fixture is required; the \
                test fails instead of skipping.
                """
        case let .fixtureUndecodable(
            fixture,
            directory,
            underlying
        ):
            return """
                Demo fixture "\(fixture)" in \(directory) \
                could not be decoded as canonical DTOs: \
                \(underlying)
                """
        }
    }
}

/// The fixture envelope. `response` decodes into the canonical
/// `MedicineAssessmentResponseDTO`, so a Core DTO change breaks these tests
/// rather than being papered over by a local mirror type.
struct PresentationFixturePayload: Decodable {
    let fixtureID: String
    let disclaimer: String
    let request: MedicineAssessmentRequestDTO
    let response: MedicineAssessmentResponseDTO
    let expectation: PresentationFixtureExpectation
}

struct PresentationFixtureExpectation: Decodable {
    let allowsOrdinaryExplanation: Bool
    let expectedActionCardPrimaryInstruction: String
    let expectedActionCardTitle: String
    let expectedPresentationVariant: String
    let expectedRiskLevel: String
    let expectedViewState: String
    let recommendContactFamily: Bool
    let recommendContactHealthcareProfessional: Bool
}

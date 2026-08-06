@testable import SlowWalkServer
import XCTest

final class SlowWalkServerConfigurationTests: XCTestCase {
    func testMissingEnvironmentUsesLoopbackDefaults() throws {
        let configuration = try SlowWalkServerConfiguration.load(
            environment: [:]
        )

        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 8080)
    }

    func testExplicitHostIsUsed() throws {
        let configuration = try SlowWalkServerConfiguration.load(
            environment: [
                SlowWalkServerConfiguration.hostEnvironmentKey:
                    "0.0.0.0",
            ]
        )

        XCTAssertEqual(configuration.host, "0.0.0.0")
        XCTAssertEqual(configuration.port, 8080)
    }

    func testExplicitPortIsUsed() throws {
        let configuration = try SlowWalkServerConfiguration.load(
            environment: [
                SlowWalkServerConfiguration.portEnvironmentKey: "9090",
            ]
        )

        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 9090)
    }

    func testNonNumericPortIsRejected() {
        assertConfigurationError(
            environment: [
                SlowWalkServerConfiguration.portEnvironmentKey: "not-a-port",
            ],
            expected: .portInvalid
        )
    }

    func testZeroPortIsRejected() {
        assertConfigurationError(
            environment: [
                SlowWalkServerConfiguration.portEnvironmentKey: "0",
            ],
            expected: .portOutOfRange
        )
    }

    func testPortAboveMaximumIsRejected() {
        assertConfigurationError(
            environment: [
                SlowWalkServerConfiguration.portEnvironmentKey: "65536",
            ],
            expected: .portOutOfRange
        )
    }

    func testEmptyOrWhitespaceHostIsRejected() {
        for host in ["", "  \n\t  "] {
            assertConfigurationError(
                environment: [
                    SlowWalkServerConfiguration.hostEnvironmentKey: host,
                ],
                expected: .hostEmpty
            )
        }
    }

    func testErrorsDoNotContainEnvironmentValues() {
        let invalidPort = "private-port-value-LEAK-CANARY"

        XCTAssertThrowsError(
            try SlowWalkServerConfiguration.load(
                environment: [
                    SlowWalkServerConfiguration.portEnvironmentKey:
                        invalidPort,
                ]
            )
        ) { error in
            XCTAssertFalse(
                String(describing: error).contains(invalidPort)
            )
            XCTAssertFalse(
                (error as NSError).localizedDescription
                    .contains(invalidPort)
            )
        }
    }

    private func assertConfigurationError(
        environment: [String: String],
        expected: SlowWalkServerConfigurationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try SlowWalkServerConfiguration.load(
                environment: environment
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SlowWalkServerConfigurationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

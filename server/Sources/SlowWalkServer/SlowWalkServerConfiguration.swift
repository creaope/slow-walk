import Foundation

public enum SlowWalkServerConfigurationError:
    Error,
    Sendable,
    Equatable,
    LocalizedError,
    CustomStringConvertible
{
    case hostEmpty
    case portInvalid
    case portOutOfRange

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .hostEmpty:
            "SLOWWALK_SERVER_HOST must not be empty."
        case .portInvalid:
            "SLOWWALK_SERVER_PORT must be a base-10 integer."
        case .portOutOfRange:
            "SLOWWALK_SERVER_PORT must be between 1 and 65535."
        }
    }
}

public struct SlowWalkServerConfiguration: Sendable, Equatable {
    static let hostEnvironmentKey = "SLOWWALK_SERVER_HOST"
    static let portEnvironmentKey = "SLOWWALK_SERVER_PORT"

    public static let defaultHost = "127.0.0.1"
    public static let defaultPort = 8080

    public let host: String
    public let port: Int
    public let serverName: String

    public init(
        host: String = SlowWalkServerConfiguration.defaultHost,
        port: Int = SlowWalkServerConfiguration.defaultPort,
        serverName: String = "slow-walk-server"
    ) {
        self.host = host
        self.port = port
        self.serverName = serverName
    }

    public static func load(
        environment: [String: String] =
            ProcessInfo.processInfo.environment
    ) throws -> SlowWalkServerConfiguration {
        let host: String
        if let rawHost = environment[hostEnvironmentKey] {
            let trimmedHost = rawHost.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmedHost.isEmpty else {
                throw SlowWalkServerConfigurationError.hostEmpty
            }
            host = trimmedHost
        } else {
            host = defaultHost
        }

        let port: Int
        if let rawPort = environment[portEnvironmentKey] {
            let trimmedPort = rawPort.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmedPort.isEmpty,
                  trimmedPort.utf8.allSatisfy({
                      (48...57).contains($0)
                  }),
                  let parsedPort = Int(trimmedPort)
            else {
                throw SlowWalkServerConfigurationError.portInvalid
            }
            guard (1...65_535).contains(parsedPort) else {
                throw SlowWalkServerConfigurationError.portOutOfRange
            }
            port = parsedPort
        } else {
            port = defaultPort
        }

        return SlowWalkServerConfiguration(
            host: host,
            port: port
        )
    }
}

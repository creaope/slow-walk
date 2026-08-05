import Foundation

/// Non-secret endpoint configuration for medicine recognition.
///
/// A supplied but invalid higher-priority value fails closed instead of
/// falling through to another source. This prevents a deployment typo from
/// silently selecting an unintended endpoint.
nonisolated enum MedicineRecognitionServerConfiguration:
    Sendable,
    Equatable
{
    case available(baseURL: URL)
    case unavailable

    static let baseURLConfigurationKey =
        "SLOWWALK_MEDICINE_RECOGNITION_BASE_URL"

    init(
        explicitBaseURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: String] = Self.bundledInfoDictionary()
    ) {
        if let explicitBaseURL {
            self = Self.validated(explicitBaseURL)
            return
        }
        if let rawValue = environment[Self.baseURLConfigurationKey] {
            self = Self.validated(rawValue)
            return
        }
        if let rawValue = infoDictionary[Self.baseURLConfigurationKey] {
            self = Self.validated(rawValue)
            return
        }
        self = .unavailable
    }

    var baseURL: URL? {
        guard case .available(let baseURL) = self else { return nil }
        return baseURL
    }

    private static func validated(_ rawValue: String) -> Self {
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return .unavailable
        }
        return validated(url)
    }

    private static func validated(_ url: URL) -> Self {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        let host = components.host?.lowercased(),
        !host.isEmpty,
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        isPermitted(scheme: scheme, host: host)
        else {
            return .unavailable
        }
        return .available(baseURL: url)
    }

    private static func isPermitted(
        scheme: String,
        host: String
    ) -> Bool {
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }

        let normalizedHost = host.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )
        return normalizedHost == "localhost"
            || normalizedHost == "127.0.0.1"
            || normalizedHost == "::1"
    }

    private static func bundledInfoDictionary() -> [String: String] {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: baseURLConfigurationKey
        ) as? String else {
            return [:]
        }
        return [baseURLConfigurationKey: value]
    }
}

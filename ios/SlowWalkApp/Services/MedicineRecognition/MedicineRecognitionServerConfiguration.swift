import Foundation

/// One security boundary for configured and directly injected Server URLs.
/// The production call site selects its HTTP policy at compile time.
nonisolated enum MedicineRecognitionServerURLPolicy {
    static func validatedURL(from rawValue: String) -> URL? {
        #if DEBUG
        validatedURL(from: rawValue, allowsPrivateNetworkHTTP: true)
        #else
        validatedURL(from: rawValue, allowsPrivateNetworkHTTP: false)
        #endif
    }

    static func validatedURL(
        from rawValue: String,
        allowsPrivateNetworkHTTP: Bool
    ) -> URL? {
        guard let parsedComponents = URLComponents(string: rawValue),
              let scheme = parsedComponents.scheme?.lowercased()
        else {
            return nil
        }

        let url: URL?
        if scheme == "http" {
            // Preserve invalid characters so Foundation cannot normalize a
            // non-canonical IP spelling before the policy examines it.
            url = URL(
                string: rawValue,
                encodingInvalidCharacters: false
            )
        } else {
            url = URL(string: rawValue)
        }

        guard let url,
              permits(
                  url,
                  allowsPrivateNetworkHTTP: allowsPrivateNetworkHTTP
              )
        else {
            return nil
        }
        return url
    }

    static func permits(_ url: URL) -> Bool {
        #if DEBUG
        permits(url, allowsPrivateNetworkHTTP: true)
        #else
        permits(url, allowsPrivateNetworkHTTP: false)
        #endif
    }

    static func permits(
        _ url: URL,
        allowsPrivateNetworkHTTP: Bool
    ) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        let rawHost = components.host,
        let percentEncodedHost = components.percentEncodedHost,
        !rawHost.isEmpty,
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil
        else {
            return false
        }

        let host = normalizedHost(rawHost)
        guard host != "0.0.0.0" else { return false }

        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        guard percentEncodedHost == rawHost else { return false }
        if isLoopback(host) { return true }
        guard allowsPrivateNetworkHTTP else { return false }
        return isCanonicalPrivateIPv4(host)
    }

    private static func normalizedHost(_ host: String) -> String {
        guard host.first == "[", host.last == "]" else {
            return host.lowercased()
        }
        return String(host.dropFirst().dropLast()).lowercased()
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
    }

    private static func isCanonicalPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 4 else { return false }

        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty,
                  part.count == 1 || part.first != "0",
                  part.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let value = UInt8(part)
            else {
                return false
            }
            octets.append(value)
        }

        // Subnet masks are not available here. Reject the common directed
        // broadcast form in addition to the range-level broadcast addresses.
        guard octets[3] != 255 else { return false }

        switch (octets[0], octets[1]) {
        case (10, _):
            return true
        case (172, 16 ... 31):
            return true
        case (192, 168):
            return true
        default:
            return false
        }
    }
}

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
        guard !trimmed.isEmpty,
              let url = MedicineRecognitionServerURLPolicy.validatedURL(
                  from: trimmed
              )
        else {
            return .unavailable
        }
        return .available(baseURL: url)
    }

    private static func validated(_ url: URL) -> Self {
        guard MedicineRecognitionServerURLPolicy.permits(url) else {
            return .unavailable
        }
        return .available(baseURL: url)
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

import Foundation

#if canImport(Security)
import Security
#endif

/// Failures raised while loading the Zhipu debug runtime configuration.
///
/// None of the cases carry the API key, so rendering or reflecting an error is
/// safe even when loading fails after a key has been supplied.
enum ZhipuVisionRuntimeConfigurationError:
    Error,
    Sendable,
    Equatable,
    LocalizedError,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    case apiKeyMissing
    case apiKeyEmpty
    case baseURLInvalid
    case keychainReadFailed(status: Int32)
    case keychainValueInvalid

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .apiKeyMissing:
            "ZHIPU_API_KEY is missing and no Zhipu Debug Key was found in the macOS Keychain."
        case .apiKeyEmpty:
            "ZHIPU_API_KEY or the Zhipu macOS Keychain value is empty."
        case .baseURLInvalid:
            "ZHIPU_BASE_URL is not a valid URL."
        case .keychainReadFailed(let status):
            "The Zhipu Debug Key could not be read from the macOS Keychain (status: \(status))."
        case .keychainValueInvalid:
            "The Zhipu Debug Key in the macOS Keychain is not valid UTF-8 text."
        }
    }

    var debugDescription: String { description }
}

/// Runtime-only Zhipu Vision settings assembled from environment variables and
/// the macOS Keychain.
///
/// Provider details remain in ``VisionProviderConfiguration`` and the key
/// remains in ``VisionCredential``. The current client sends only `primary`;
/// `fallback` is retained for future orchestration and is not selected here.
struct ZhipuVisionRuntimeConfiguration:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    static let providerIdentifier = "zhipu"
    static let defaultBaseURLString =
        "https://open.bigmodel.cn/api/paas/v4"
    static let defaultPrimaryModel = "glm-4.6v"
    static let defaultFallbackModel = "glm-4.6v-flash"

    static let apiKeyEnvironmentKey = "ZHIPU_API_KEY"
    static let baseURLEnvironmentKey = "ZHIPU_BASE_URL"
    static let primaryModelEnvironmentKey =
        "ZHIPU_VISION_MODEL_PRIMARY"
    static let fallbackModelEnvironmentKey =
        "ZHIPU_VISION_MODEL_FALLBACK"

    /// Keychain coordinates used only when `ZHIPU_API_KEY` is absent.
    static let keychainService = "slow-walk-server.zhipu.debug"
    static let keychainAccount = apiKeyEnvironmentKey

    let primary: VisionProviderConfiguration
    /// Reserved configuration only; PR #53 does not execute model fallback.
    let fallback: VisionProviderConfiguration
    let credential: VisionCredential

    /// Loads settings from the current process. Supplying a reader keeps the
    /// Keychain boundary deterministic in tests without introducing another
    /// credential representation.
    static func load(
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        keychainAPIKey: @Sendable () throws -> String? = {
            try ZhipuVisionKeychain.loadAPIKey()
        }
    ) throws -> ZhipuVisionRuntimeConfiguration {
        let rawAPIKey: String
        if let environmentAPIKey = environment[apiKeyEnvironmentKey] {
            rawAPIKey = environmentAPIKey
        } else if let keychainAPIKey = try keychainAPIKey() {
            rawAPIKey = keychainAPIKey
        } else {
            throw ZhipuVisionRuntimeConfigurationError.apiKeyMissing
        }

        let apiKey = rawAPIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ZhipuVisionRuntimeConfigurationError.apiKeyEmpty
        }

        let baseURLString = environment[baseURLEnvironmentKey]
            ?? defaultBaseURLString
        guard let baseURL = URL(
            string: baseURLString.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        ) else {
            throw ZhipuVisionRuntimeConfigurationError.baseURLInvalid
        }

        let primary = try VisionProviderConfiguration(
            providerIdentifier: providerIdentifier,
            baseURL: baseURL,
            model: environment[primaryModelEnvironmentKey]
                ?? defaultPrimaryModel
        )
        let fallback = try VisionProviderConfiguration(
            providerIdentifier: providerIdentifier,
            baseURL: baseURL,
            model: environment[fallbackModelEnvironmentKey]
                ?? defaultFallbackModel
        )

        return ZhipuVisionRuntimeConfiguration(
            primary: primary,
            fallback: fallback,
            credential: VisionCredential(apiKey: apiKey)
        )
    }

    var description: String {
        "ZhipuVisionRuntimeConfiguration(baseURL: \(primary.baseURL.absoluteString), "
            + "primaryModel: \(primary.model), fallbackModel: \(fallback.model), "
            + "credential: \(VisionCredential.redactionMarker))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "primary": primary,
                "fallback": fallback,
                "credential": VisionCredential.redactionMarker,
            ],
            displayStyle: .struct
        )
    }
}

private enum ZhipuVisionKeychain {
    static func loadAPIKey() throws -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String:
                ZhipuVisionRuntimeConfiguration.keychainService,
            kSecAttrAccount as String:
                ZhipuVisionRuntimeConfiguration.keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &item
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ZhipuVisionRuntimeConfigurationError
                .keychainReadFailed(status: status)
        }
        guard let data = item as? Data,
              let apiKey = String(data: data, encoding: .utf8)
        else {
            throw ZhipuVisionRuntimeConfigurationError
                .keychainValueInvalid
        }
        return apiKey
        #else
        return nil
        #endif
    }
}

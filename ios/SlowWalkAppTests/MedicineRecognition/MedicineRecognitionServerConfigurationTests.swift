import Foundation
import Testing

@testable import SlowWalkApp

@Suite("Medicine recognition server configuration")
struct MedicineRecognitionServerConfigurationTests {
    private let key = MedicineRecognitionServerConfiguration
        .baseURLConfigurationKey

    @Test func explicitHTTPSURLHasHighestPriority() throws {
        let explicit = try #require(
            URL(string: "https://explicit.example/gateway/")
        )
        let configuration = MedicineRecognitionServerConfiguration(
            explicitBaseURL: explicit,
            environment: [key: "https://environment.example"],
            infoDictionary: [key: "https://info.example"]
        )

        #expect(configuration == .available(baseURL: explicit))
        #expect(configuration.baseURL == explicit)
    }

    @Test func readsEnvironmentBeforeInfoDictionary() throws {
        let environmentURL = try #require(
            URL(string: "https://environment.example/api/")
        )
        let configuration = MedicineRecognitionServerConfiguration(
            environment: [key: environmentURL.absoluteString],
            infoDictionary: [key: "https://info.example"]
        )

        #expect(
            configuration == .available(baseURL: environmentURL)
        )
    }

    @Test func readsInfoDictionaryWhenEnvironmentIsAbsent() throws {
        let infoURL = try #require(
            URL(string: "https://info.example/slowwalk/")
        )
        let configuration = MedicineRecognitionServerConfiguration(
            environment: [:],
            infoDictionary: [key: infoURL.absoluteString]
        )

        #expect(configuration == .available(baseURL: infoURL))
    }

    @Test func permitsOnlyNamedLoopbackHostsOverHTTP() throws {
        let values = [
            "http://localhost:8080",
            "http://127.0.0.1:8080/base/",
            "http://[::1]:8080",
        ]

        for value in values {
            let url = try #require(URL(string: value))
            #expect(
                MedicineRecognitionServerConfiguration(
                    explicitBaseURL: url,
                    environment: [:],
                    infoDictionary: [:]
                ) == .available(baseURL: url)
            )
        }
    }

    @Test func missingAndBlankValuesAreUnavailable() {
        let missing = MedicineRecognitionServerConfiguration(
            environment: [:],
            infoDictionary: [:]
        )
        let blankEnvironment = MedicineRecognitionServerConfiguration(
            environment: [key: " \n\t "],
            infoDictionary: [key: "https://ignored.example"]
        )
        let blankInfo = MedicineRecognitionServerConfiguration(
            environment: [:],
            infoDictionary: [key: "  "]
        )

        #expect(missing == .unavailable)
        #expect(missing.baseURL == nil)
        #expect(blankEnvironment == .unavailable)
        #expect(blankInfo == .unavailable)
    }

    @Test func rejectsMalformedAndNonHTTPURLs() throws {
        let values = [
            "not a URL",
            "/relative/path",
            "ftp://medicine.example/path",
            "https:///missing-host",
        ]

        for value in values {
            #expect(
                MedicineRecognitionServerConfiguration(
                    environment: [key: value],
                    infoDictionary: [:]
                ) == .unavailable
            )
        }
    }

    @Test func rejectsRemotePlaintextHTTP() throws {
        let values = [
            "http://medicine.example",
            "http://localhost.example",
            "http://127.0.0.2",
        ]

        for value in values {
            #expect(
                MedicineRecognitionServerConfiguration(
                    environment: [key: value],
                    infoDictionary: [:]
                ) == .unavailable
            )
        }
    }

    @Test func rejectsUserInfoQueryAndFragment() throws {
        let values = [
            "https://user@medicine.example",
            "https://user:password@medicine.example",
            "https://medicine.example?token=secret",
            "https://medicine.example#fragment",
        ]

        for value in values {
            #expect(
                MedicineRecognitionServerConfiguration(
                    environment: [key: value],
                    infoDictionary: [:]
                ) == .unavailable
            )
        }
    }

    @Test func doesNotInterpretCredentialConfiguration() {
        let credentialsOnly = [
            "ZHIPU_API_KEY": "not-a-real-secret",
            "AUTHORIZATION": "Bearer not-a-real-token",
        ]
        let configuration = MedicineRecognitionServerConfiguration(
            environment: credentialsOnly,
            infoDictionary: [:]
        )

        #expect(configuration == .unavailable)
        #expect(
            MedicineRecognitionServerConfiguration
                .baseURLConfigurationKey
                == "SLOWWALK_MEDICINE_RECOGNITION_BASE_URL"
        )
    }

    @Test func privacyCopyReflectsPreferenceAndConfiguration() {
        #expect(
            MedicineRecognitionPrivacyCopy.description(
                onDeviceOnly: true,
                onlineRecognitionConfigured: true
            ) == "药品包装图片只在这台设备上处理。"
        )
        #expect(
            MedicineRecognitionPrivacyCopy.description(
                onDeviceOnly: false,
                onlineRecognitionConfigured: true
            ).contains("优先发送到已配置的识别服务")
        )
        #expect(
            MedicineRecognitionPrivacyCopy.description(
                onDeviceOnly: false,
                onlineRecognitionConfigured: false
            ) == "当前未配置在线识别服务，药品包装图片只在设备上处理。"
        )
    }
}

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

    @Test func privateIPv4PolicyUsesCanonicalCIDRRanges() throws {
        let permitted = [
            "http://10.0.0.1:8080",
            "http://10.255.255.254:8080",
            "http://172.16.0.1:8080",
            "http://172.31.255.254:8080",
            "http://192.168.0.1:8080",
            "http://192.168.255.254:8080",
        ]
        let rejected = [
            "http://0.0.0.0:8080",
            "http://8.8.8.8:8080",
            "http://172.15.255.254:8080",
            "http://172.32.0.1:8080",
            "http://192.167.255.254:8080",
            "http://example.com:8080",
            "http://10.0.0.255:8080",
            "http://172.31.255.255:8080",
            "http://192.168.1.255:8080",
        ]

        for value in permitted {
            let url = try #require(URL(string: value))
            #expect(
                MedicineRecognitionServerURLPolicy.permits(
                    url,
                    allowsPrivateNetworkHTTP: true
                )
            )
        }
        for value in rejected {
            let url = try #require(URL(string: value))
            #expect(
                !MedicineRecognitionServerURLPolicy.permits(
                    url,
                    allowsPrivateNetworkHTTP: true
                )
            )
        }
    }

    @Test func rejectsNonCanonicalIPv4Representations() throws {
        let values = [
            "http://3232235777:8080",
            "http://0xC0.0xA8.0x01.0x17:8080",
            "http://0300.0250.01.027:8080",
            "http://192.168.1:8080",
            "http://192.168.001.023:8080",
            "http://192.168.0x1.23:8080",
            "http://192%2e168%2e1%2e23:8080",
            "http://%31%39%32.168.1.23:8080",
        ]

        for value in values {
            let url = try #require(URL(string: value))
            #expect(
                !MedicineRecognitionServerURLPolicy.permits(
                    url,
                    allowsPrivateNetworkHTTP: true
                )
            )
        }
    }

    @Test func rawConfigurationRejectsNormalizedIPv4Separators() {
        let values = [
            "http://192。168。1。23:8080",
            "http://192．168．1．23:8080",
            "http://192｡168｡1｡23:8080",
        ]

        for value in values {
            #expect(
                MedicineRecognitionServerURLPolicy.validatedURL(
                    from: value,
                    allowsPrivateNetworkHTTP: true
                ) == nil
            )
            #expect(
                MedicineRecognitionServerConfiguration(
                    environment: [key: value],
                    infoDictionary: [:]
                ) == .unavailable
            )
        }
    }

    @Test func strictBuildPolicyRejectsPrivateHTTP() throws {
        let privateURL = try #require(
            URL(string: "http://192.168.1.23:8080")
        )
        let loopbackURL = try #require(
            URL(string: "http://127.0.0.1:8080")
        )
        let secureURL = try #require(
            URL(string: "https://medicine.example")
        )

        #expect(
            !MedicineRecognitionServerURLPolicy.permits(
                privateURL,
                allowsPrivateNetworkHTTP: false
            )
        )
        #expect(
            MedicineRecognitionServerURLPolicy.permits(
                loopbackURL,
                allowsPrivateNetworkHTTP: false
            )
        )
        #expect(
            MedicineRecognitionServerURLPolicy.permits(
                secureURL,
                allowsPrivateNetworkHTTP: false
            )
        )
    }

    #if DEBUG
    @Test func debugConfigurationPermitsPrivateIPv4HTTP() throws {
        let values = [
            "http://192.168.1.23:8080",
            "http://10.0.0.5:8080",
            "http://172.20.10.2:8080",
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
    #endif

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
            "http://8.8.8.8",
            "http://0.0.0.0",
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

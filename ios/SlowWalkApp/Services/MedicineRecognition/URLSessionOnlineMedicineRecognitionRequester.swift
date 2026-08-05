import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore

/// Rejects every redirect so medicine images are sent only to the configured
/// origin. Redirect targets never receive the request body or its headers.
nonisolated final class MedicineRecognitionRedirectRejectingDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Stateless remote-recognition transport. Image preparation and response
/// mapping remain behind their existing canonical boundaries.
nonisolated final class URLSessionOnlineMedicineRecognitionRequester:
    OnlineMedicineRecognitionRequesting,
    @unchecked Sendable
{
    static let requestTimeout: TimeInterval = 40
    static let maximumResponseBytes = 1 * 1_024 * 1_024
    static let maximumUploadBytes = 4 * 1_024 * 1_024

    private let baseURL: URL
    private let imagePreparer: any MedicineRecognitionImagePreparing
    private let responseMapper: OnlineMedicineRecognitionResponseMapper
    private let redirectDelegate: MedicineRecognitionRedirectRejectingDelegate
    private let session: URLSession

    init(
        baseURL: URL,
        imagePreparer: any MedicineRecognitionImagePreparing =
            MedicineRecognitionImagePreparer(),
        responseMapper: OnlineMedicineRecognitionResponseMapper = .init(),
        protocolClasses: [AnyClass]? = nil
    ) {
        self.baseURL = baseURL
        self.imagePreparer = imagePreparer
        self.responseMapper = responseMapper

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }

        let redirectDelegate =
            MedicineRecognitionRedirectRejectingDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func recognize(
        request: OnlineMedicineRecognitionRequest
    ) async throws -> OnlineMedicineRecognitionResult {
        try Task.checkCancellation()
        let image: PreparedMedicineRecognitionImage
        do {
            image = try await imagePreparer.prepare(request.image)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            guard let error = error as?
                MedicineRecognitionImagePreparationError
            else {
                throw OnlineMedicineRecognitionFailure.invalidImage
            }
            switch error {
            case .invalidImage:
                throw OnlineMedicineRecognitionFailure.invalidImage
            case .imageTooLarge:
                throw OnlineMedicineRecognitionFailure.imageTooLarge
            }
        }
        try Task.checkCancellation()
        try validatePreparedImage(image)

        guard let endpointURL = endpointURL() else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        let requestDTO = MedicineRecognitionAPIRequestDTO(
            imageBase64: image.data.base64EncodedString(),
            mimeType: image.mimeType,
            requestID: request.requestID,
            clientCapabilities:
                MedicineRecognitionClientCapabilitiesDTO(
                    supportsLocalFallback: true
                ),
            apiVersion: SlowWalkAPI.version
        )
        let body: Data
        do {
            body = try SlowWalkJSONCoding.makeEncoder().encode(requestDTO)
        } catch {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        try Task.checkCancellation()

        var urlRequest = URLRequest(
            url: endpointURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        urlRequest.httpBody = body

        let (data, httpResponse) = try await responseData(
            for: urlRequest,
            expectedURL: endpointURL
        )
        try Task.checkCancellation()

        switch httpResponse.statusCode {
        case 200:
            return try decodeAndMap(
                data,
                response: httpResponse,
                request: request
            )
        case 429, 502, 503, 504:
            return try decodeAndMapGatewayFailure(
                data,
                response: httpResponse,
                request: request
            )
        case 500 ..< 600:
            throw OnlineMedicineRecognitionFailure.serverUnavailable
        default:
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
    }

    private func decodeAndMap(
        _ data: Data,
        response: HTTPURLResponse,
        request: OnlineMedicineRecognitionRequest
    ) throws -> OnlineMedicineRecognitionResult {
        try Task.checkCancellation()
        guard hasJSONContentType(response) else {
            try Task.checkCancellation()
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        let responseDTO: MedicineRecognitionAPIResponseDTO
        do {
            responseDTO = try SlowWalkJSONCoding.makeDecoder().decode(
                MedicineRecognitionAPIResponseDTO.self,
                from: data
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        try Task.checkCancellation()
        guard responseDTO.status != .providerUnavailable else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        return try map(responseDTO, for: request)
    }

    private func decodeAndMapGatewayFailure(
        _ data: Data,
        response: HTTPURLResponse,
        request: OnlineMedicineRecognitionRequest
    ) throws -> OnlineMedicineRecognitionResult {
        try Task.checkCancellation()
        guard hasJSONContentType(response),
              let responseDTO = try? SlowWalkJSONCoding.makeDecoder().decode(
                MedicineRecognitionAPIResponseDTO.self,
                from: data
              ),
              responseDTO.status == .providerUnavailable,
              responseDTO.errorCode == expectedProviderErrorCode(
                for: response.statusCode
              )
        else {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        try Task.checkCancellation()
        return try map(responseDTO, for: request)
    }

    private func map(
        _ responseDTO: MedicineRecognitionAPIResponseDTO,
        for request: OnlineMedicineRecognitionRequest
    ) throws -> OnlineMedicineRecognitionResult {
        try Task.checkCancellation()
        do {
            let result = try responseMapper.map(responseDTO, for: request)
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as OnlineMedicineRecognitionFailure {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw failure
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
    }

    private func endpointURL() -> URL? {
        guard let scheme = baseURL.scheme?.lowercased(),
              let host = baseURL.host?.lowercased(),
              isPermitted(scheme: scheme, host: host),
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              var components = URLComponents(
                url: baseURL,
                resolvingAgainstBaseURL: false
              )
        else {
            return nil
        }

        let basePath = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (basePath.isEmpty ? "" : "/\(basePath)")
            + SlowWalkAPI.Endpoint.medicineRecognize.path
        return components.url
    }

    private func responseData(
        for request: URLRequest,
        expectedURL: URL
    ) async throws -> (Data, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
        } catch {
            throw mapTransportError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.url == expectedURL
        else {
            bytes.task.cancel()
            try Task.checkCancellation()
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
        do {
            try validateDeclaredResponseSize(httpResponse)
        } catch {
            bytes.task.cancel()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        if Task.isCancelled {
            bytes.task.cancel()
            throw CancellationError()
        }

        switch httpResponse.statusCode {
        case 200, 429, 502, 503, 504:
            break
        case 500 ..< 600:
            bytes.task.cancel()
            try Task.checkCancellation()
            throw OnlineMedicineRecognitionFailure.serverUnavailable
        default:
            bytes.task.cancel()
            try Task.checkCancellation()
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }

        var data = Data()
        let declaredLength = httpResponse.expectedContentLength
        if declaredLength > 0 {
            data.reserveCapacity(
                min(Int(declaredLength), Self.maximumResponseBytes)
            )
        }
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else {
                    bytes.task.cancel()
                    throw OnlineMedicineRecognitionFailure.invalidResponse
                }
                data.append(byte)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            bytes.task.cancel()
            throw CancellationError()
        } catch let failure as OnlineMedicineRecognitionFailure {
            bytes.task.cancel()
            throw failure
        } catch {
            bytes.task.cancel()
            throw mapTransportError(error)
        }
        return (data, httpResponse)
    }

    private func validateDeclaredResponseSize(
        _ response: HTTPURLResponse
    ) throws {
        if let value = response.value(
            forHTTPHeaderField: "Content-Length"
        ) {
            guard let declaredLength = Int(value),
                  declaredLength >= 0,
                  declaredLength <= Self.maximumResponseBytes
            else {
                throw OnlineMedicineRecognitionFailure.invalidResponse
            }
        }
        let expectedLength = response.expectedContentLength
        guard expectedLength <= Int64(Self.maximumResponseBytes) else {
            throw OnlineMedicineRecognitionFailure.invalidResponse
        }
    }

    private func validatePreparedImage(
        _ image: PreparedMedicineRecognitionImage
    ) throws {
        guard !image.data.isEmpty,
              image.mimeType == PreparedMedicineRecognitionImage.jpegMIMEType
        else {
            throw OnlineMedicineRecognitionFailure.invalidImage
        }
        guard image.data.count <= Self.maximumUploadBytes else {
            throw OnlineMedicineRecognitionFailure.imageTooLarge
        }
        guard image.data.starts(with: [0xFF, 0xD8, 0xFF]) else {
            throw OnlineMedicineRecognitionFailure.invalidImage
        }
    }

    private func expectedProviderErrorCode(
        for statusCode: Int
    ) -> APIErrorCode? {
        switch statusCode {
        case 429:
            .providerRateLimited
        case 502:
            .invalidProviderResponse
        case 503:
            .providerUnavailable
        case 504:
            .providerTimeout
        default:
            nil
        }
    }

    private func isPermitted(scheme: String, host: String) -> Bool {
        if scheme == "https" {
            return true
        }
        guard scheme == "http" else {
            return false
        }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
    }

    private func hasJSONContentType(
        _ response: HTTPURLResponse
    ) -> Bool {
        guard let contentType = response.value(
            forHTTPHeaderField: "Content-Type"
        )?.lowercased() else {
            return false
        }
        return contentType == "application/json"
            || contentType.hasPrefix("application/json;")
    }

    private func mapTransportError(
        _ error: any Error
    ) -> any Error {
        if error is CancellationError || Task.isCancelled {
            return CancellationError()
        }
        guard let urlError = error as? URLError else {
            return OnlineMedicineRecognitionFailure.serverUnavailable
        }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return OnlineMedicineRecognitionFailure.timeout
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .dataNotAllowed,
             .internationalRoamingOff:
            return OnlineMedicineRecognitionFailure.offline
        case .badServerResponse,
             .cannotParseResponse,
             .redirectToNonExistentLocation,
             .httpTooManyRedirects,
             .badURL,
             .unsupportedURL:
            return OnlineMedicineRecognitionFailure.invalidResponse
        default:
            return OnlineMedicineRecognitionFailure.serverUnavailable
        }
    }
}

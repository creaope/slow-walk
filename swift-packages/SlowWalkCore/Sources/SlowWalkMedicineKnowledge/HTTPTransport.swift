import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPTransportMethod:
    String,
    Codable,
    Sendable,
    CaseIterable,
    Hashable
{
    case get = "GET"
    case post = "POST"
}

public struct HTTPTransportRequest:
    Sendable,
    Equatable
{
    public let url: URL
    public let method: HTTPTransportMethod
    public let headers: [String: String]
    public let body: Data?
    public let timeout: TimeInterval

    public init(
        url: URL,
        method: HTTPTransportMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPTransportResponse:
    Sendable,
    Equatable
{
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let normalizedName = name.lowercased()
        return headers.first {
            $0.key.lowercased() == normalizedName
        }?.value
    }
}

public enum HTTPTransportError:
    Error,
    Sendable,
    Equatable
{
    case timeout
    case cancelled
    case invalidResponse
    case networkFailure
}

@available(macOS 14.0, iOS 17.0, *)
public struct URLSessionHTTPTransport:
    HTTPTransporting,
    Sendable
{
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(
        _ request: HTTPTransportRequest
    ) async throws -> HTTPTransportResponse {
        try Task.checkCancellation()

        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: request.timeout
        )
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (data, response) = try await session.data(
                for: urlRequest
            )
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPTransportError.invalidResponse
            }
            var headers = [String: String]()
            for (name, value) in httpResponse.allHeaderFields {
                headers[String(describing: name)] =
                    String(describing: value)
            }
            return HTTPTransportResponse(
                statusCode: httpResponse.statusCode,
                headers: headers,
                body: data
            )
        } catch is CancellationError {
            throw HTTPTransportError.cancelled
        } catch let error as HTTPTransportError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw HTTPTransportError.timeout
            case .cancelled:
                throw HTTPTransportError.cancelled
            default:
                throw HTTPTransportError.networkFailure
            }
        } catch {
            throw HTTPTransportError.networkFailure
        }
    }
}

public struct HTTPRetryPolicy:
    Sendable,
    Equatable
{
    public static let standard = HTTPRetryPolicy(
        maximumAttempts: 2,
        retryableStatusCodes: [408, 429, 500, 502, 503, 504]
    )

    public let maximumAttempts: Int
    public let retryableStatusCodes: Set<Int>

    public init(
        maximumAttempts: Int,
        retryableStatusCodes: Set<Int>
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.retryableStatusCodes = retryableStatusCodes
    }
}

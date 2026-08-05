import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The non-sensitive parts of one provider HTTP response.
struct VisionHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

/// Sends an already-constructed vision request.
protocol VisionHTTPTransport: Sendable {
    func send(_ request: VisionTransportRequest) async throws -> VisionHTTPResponse
}

enum VisionHTTPTransportError: Error, Sendable { case nonHTTPResponse }

/// Rejects every redirect so credentials and image data stay on the original request.
final class VisionHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    override var description: String {
        "VisionHTTPRedirectDelegate(policy: rejectAll)"
    }

    func redirectRequest(for _: URLRequest) -> URLRequest? { nil }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(redirectRequest(for: request))
    }
}

/// URLSession-backed transport shared by macOS and Linux server builds.
struct URLSessionVisionHTTPTransport: VisionHTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func send(_ request: VisionTransportRequest) async throws -> VisionHTTPResponse {
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: request.timeout
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (body, response) = try await session.data(
            for: urlRequest,
            delegate: VisionHTTPRedirectDelegate()
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VisionHTTPTransportError.nonHTTPResponse
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) {
            result, entry in
            guard let name = entry.key as? String else { return }
            result[name] = String(describing: entry.value)
        }
        return VisionHTTPResponse(
            statusCode: httpResponse.statusCode, headers: headers, body: body
        )
    }
}

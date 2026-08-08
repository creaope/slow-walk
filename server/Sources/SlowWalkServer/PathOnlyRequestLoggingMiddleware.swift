import Hummingbird
import Logging

struct PathOnlyRequestLoggingMiddleware<Context: RequestContext>:
    RouterMiddleware
{
    private let logLevel: Logger.Level

    init(_ logLevel: Logger.Level) {
        self.logLevel = logLevel
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        context.logger.log(
            level: logLevel,
            "Request",
            metadata: [
                "hb.request.path": .string(request.uri.path),
                "hb.request.method": .string(request.method.rawValue),
            ]
        )
        return try await next(request, context)
    }
}

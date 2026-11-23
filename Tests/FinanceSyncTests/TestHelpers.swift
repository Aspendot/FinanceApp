import FinanceSync
import Foundation

/// Scriptable in-memory `HTTPTransport` for deterministic unit tests without network access.
actor FakeHTTPTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private var queued: [Handler] = []
    private var defaultHandler: Handler?
    private(set) var recordedRequests: [HTTPRequest] = []

    init(responses: [HTTPResponse] = [], handler: Handler? = nil) {
        self.queued = responses.map { response in
            { _ in response }
        }
        self.defaultHandler = handler
    }

    func enqueue(_ response: HTTPResponse) {
        queued.append { _ in response }
    }

    func enqueue(_ handler: @escaping Handler) {
        queued.append(handler)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recordedRequests.append(request)
        if !queued.isEmpty {
            let next = queued.removeFirst()
            return try await next(request)
        }
        if let defaultHandler {
            return try await defaultHandler(request)
        }
        throw HTTPTransportError.requestFailed("No fake response configured for \(request.method) \(request.url.absoluteString).")
    }

    func requests() -> [HTTPRequest] {
        recordedRequests
    }
}

/// Records sleep durations without actually waiting.
actor RecordingSleeper: Sleeper {
    private(set) var recordedDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        recordedDurations.append(duration)
    }

    func durations() -> [Duration] {
        recordedDurations
    }
}

enum TestJSON {
    static func response(statusCode: Int = 200, headers: [String: String] = [:], json: Any) throws -> HTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: json)
        return HTTPResponse(statusCode: statusCode, headers: headers, body: data)
    }

    static func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

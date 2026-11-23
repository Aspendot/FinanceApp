import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An outgoing HTTP request with pure value semantics.
public struct HTTPRequest: Sendable, Equatable {
    /// HTTP method such as `"GET"` or `"POST"`.
    public var method: String
    /// Destination URL.
    public var url: URL
    /// Request header fields.
    public var headers: [String: String]
    /// Optional request body bytes.
    public var body: Data?

    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Converts this value into a Foundation `URLRequest`.
    public func makeURLRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        return request
    }
}

/// A received HTTP response with pure value semantics.
public struct HTTPResponse: Sendable, Equatable {
    /// HTTP status code, such as 200 or 401.
    public var statusCode: Int
    /// Response header fields.
    public var headers: [String: String]
    /// Response body bytes.
    public var body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Returns the first header value whose name matches `name` case-insensitively.
    public func headerValue(for name: String) -> String? {
        let target = name.lowercased()
        for (key, value) in headers where key.lowercased() == target {
            return value
        }
        return nil
    }
}

/// Errors thrown by an `HTTPTransport` when a request cannot complete.
public enum HTTPTransportError: Error, LocalizedError, Equatable, Sendable {
    /// The transport received a response that was not an HTTP response.
    case nonHTTPResponse
    /// The underlying network layer failed to complete the request.
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "The server returned a non-HTTP response."
        case .requestFailed(let message):
            return "HTTP request failed: \(message)"
        }
    }
}

/// Abstraction over HTTP networking so clients can be tested without the network.
public protocol HTTPTransport: Sendable {
    /// Sends an HTTP request and returns the raw status, headers and body.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Default `HTTPTransport` backed by `URLSession`.
public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    /// Creates a transport using the given `URLSession` (`.shared` by default).
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = request.makeURLRequest()
        let data: Data
        let response: URLResponse

        #if canImport(FoundationNetworking)
        (data, response) = try await sendWithDataTask(urlRequest)
        #else
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            throw HTTPTransportError.requestFailed(error.localizedDescription)
        }
        #endif

        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.nonHTTPResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    #if canImport(FoundationNetworking)
    private func sendWithDataTask(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
        let taskBox = DataTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let dataTask = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(throwing: HTTPTransportError.requestFailed(error.localizedDescription))
                        return
                    }
                    guard let response else {
                        continuation.resume(throwing: HTTPTransportError.nonHTTPResponse)
                        return
                    }
                    continuation.resume(returning: (data ?? Data(), response))
                }
                taskBox.set(dataTask)
                dataTask.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
    #endif
}

#if canImport(FoundationNetworking)
private final class DataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func set(_ newTask: URLSessionDataTask) {
        lock.lock()
        let shouldCancel = cancelled
        task = newTask
        lock.unlock()
        if shouldCancel {
            newTask.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }
}
#endif

/// Abstraction over async sleeping so retry backoff can be tested without real delays.
public protocol Sleeper: Sendable {
    /// Suspends the current task for at least `duration`.
    func sleep(for duration: Duration) async throws
}

/// Default `Sleeper` backed by `Task.sleep(for:)`.
public struct TaskSleeper: Sleeper, Sendable {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

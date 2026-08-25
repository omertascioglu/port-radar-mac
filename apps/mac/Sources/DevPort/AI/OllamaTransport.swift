// Modification notice: Changed in 2026 for the Port Radar Offline fork's private local Ollama service.
import Foundation

struct OllamaOriginPolicy: Sendable {
    static let allowedPaths: Set<String> = [
        "/api/version",
        "/api/tags",
        "/api/show",
        "/api/chat",
    ]

    private static let loopbackHost = "127.0.0.1"

    let endpoint: OllamaServiceEndpoint

    /// Accepts only `<leased origin><path>` for one allowlisted control path.
    func allows(_ url: URL, path: String) -> Bool {
        guard Self.allowedPaths.contains(path),
              let origin = leasedOrigin(),
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: true
              )
        else {
            return false
        }

        return components.scheme == "http"
            && components.host == Self.loopbackHost
            && components.port == origin.port
            && components.path == path
            && components.percentEncodedPath == path
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
            && url.absoluteString == origin.absoluteString + path
    }

    /// The request URL for one allowlisted control path, or `nil` when the
    /// leased origin cannot produce a safe loopback URL for it.
    func requestURL(path: String) -> URL? {
        guard let origin = leasedOrigin(),
              let url = URL(string: origin.absoluteString + path),
              allows(url, path: path)
        else {
            return nil
        }
        return url
    }

    private struct LeasedOrigin {
        let absoluteString: String
        let port: Int
    }

    private func leasedOrigin() -> LeasedOrigin? {
        guard let components = URLComponents(
                url: endpoint.baseURL,
                resolvingAgainstBaseURL: false
              ),
              components.scheme == "http",
              components.host == Self.loopbackHost,
              let port = components.port,
              components.path.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }
        return LeasedOrigin(
            absoluteString: endpoint.baseURL.absoluteString,
            port: port
        )
    }
}

final class OllamaRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    URLSessionDelegate,
    @unchecked Sendable
{
    /// The offline client never follows redirects, not even same-origin ones.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

enum OllamaStreamLimits {
    /// One newline-delimited `/api/chat` record is small; anything larger is
    /// refused before it is decoded.
    static let maxRecordBytes = 64 * 1024
    /// Cumulative bytes accepted for a single streamed chat response.
    static let maxTotalBytes = 4 * 1024 * 1024
    /// How much raw body the live loader accumulates before handing a chunk on.
    static let flushBytes = 16 * 1024
}

enum OllamaSessionFactory {
    /// Configuration for short buffered control requests. Streaming responses
    /// carry their own configuration and must not inherit these deadlines.
    static func makeControlSession() -> URLSession {
        let configuration = makePrivateConfiguration()
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 120
        return makeSession(configuration: configuration)
    }

    /// Configuration for one streamed chat. A local model can think for a long
    /// while and then emit tokens slowly, so this bounds only the idle gap
    /// between records — never the whole response — and deliberately carries no
    /// five-second deadline.
    static func makeStreamingSession() -> URLSession {
        let configuration = makePrivateConfiguration()
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        return makeSession(configuration: configuration)
    }

    private static func makePrivateConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    private static func makeSession(
        configuration: URLSessionConfiguration
    ) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: OllamaRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

protocol OllamaDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: OllamaDataLoading {}

protocol OllamaByteStreamLoading: Sendable {
    func byteStream(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<Data, any Error>, URLResponse)
}

extension URLSession: OllamaByteStreamLoading {
    /// Bridges the response body into raw byte chunks. Splitting records and
    /// bounding their size stays in the transport, so this only accumulates.
    func byteStream(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<Data, any Error>, URLResponse) {
        let (bytes, response) = try await self.bytes(for: request)
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if byte == UInt8(ascii: "\n")
                            || buffer.count >= OllamaStreamLimits.flushBytes {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    try Task.checkCancellation()
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, response)
    }
}

protocol OllamaTransporting: Sendable {
    func request(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Data

    func stream(
        path: String,
        method: String,
        body: Data?
    ) async throws -> AsyncThrowingStream<Data, any Error>
}

struct OllamaHTTPError: Error, Sendable {
    let statusCode: Int
    let hasAPIMessage: Bool
}

struct OllamaTransport: OllamaTransporting, Sendable {
    private static let newline = UInt8(ascii: "\n")
    private static let whitespaceBytes: Set<UInt8> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20]

    private let loader: any OllamaDataLoading
    private let streamLoader: any OllamaByteStreamLoading
    private let policy: OllamaOriginPolicy

    init(lease: OllamaServiceLease) {
        loader = OllamaSessionFactory.makeControlSession()
        streamLoader = OllamaSessionFactory.makeStreamingSession()
        policy = OllamaOriginPolicy(endpoint: lease.endpoint)
    }

    private init(
        loader: any OllamaDataLoading,
        streamLoader: any OllamaByteStreamLoading,
        endpoint: OllamaServiceEndpoint
    ) {
        self.loader = loader
        self.streamLoader = streamLoader
        self.policy = OllamaOriginPolicy(endpoint: endpoint)
    }

    #if DEBUG
    static func testInstance(
        loader: any OllamaDataLoading = OllamaUnavailableLoader(),
        streamLoader: any OllamaByteStreamLoading = OllamaUnavailableLoader(),
        endpoint: OllamaServiceEndpoint
    ) -> Self {
        Self(loader: loader, streamLoader: streamLoader, endpoint: endpoint)
    }

    var endpointForTesting: OllamaServiceEndpoint {
        policy.endpoint
    }
    #endif

    func request(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Data {
        guard let url = policy.requestURL(path: path) else {
            throw LocalAIError.unsafeLocalEndpoint
        }

        let (data, response) = try await loader.data(
            for: makeRequest(url: url, method: method, body: body)
        )
        try validate(response: response, path: path) { data }
        return data
    }

    /// Streams one allowlisted path as newline-delimited records. Every record
    /// is bounded before it reaches a decoder, and the response is only exposed
    /// once its status and final URL are proven to stay inside the lease.
    func stream(
        path: String,
        method: String = "POST",
        body: Data? = nil
    ) async throws -> AsyncThrowingStream<Data, any Error> {
        guard let url = policy.requestURL(path: path) else {
            throw LocalAIError.unsafeLocalEndpoint
        }

        let (source, response) = try await streamLoader.byteStream(
            for: makeRequest(url: url, method: method, body: body)
        )
        try validate(response: response, path: path) { nil }
        return records(from: source)
    }

    private func makeRequest(
        url: URL,
        method: String,
        body: Data?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }
        return request
    }

    /// Rejects anything that leaves the leased origin, or any non-success
    /// status, with bounded metadata only. `errorBody` is the buffered body when
    /// one exists; a streamed body is never buffered to inspect it.
    private func validate(
        response: URLResponse,
        path: String,
        errorBody: () -> Data?
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LocalAIError.malformedResponse
        }
        guard let finalURL = http.url,
              policy.allows(finalURL, path: path) else {
            throw LocalAIError.unsafeLocalEndpoint
        }
        if (300..<400).contains(http.statusCode) {
            throw LocalAIError.unsafeLocalEndpoint
        }
        guard (200..<300).contains(http.statusCode) else {
            let hasAPIMessage = errorBody().map { body in
                (try? JSONDecoder()
                    .decode(OllamaAPIErrorResponse.self, from: body)
                    .error.isEmpty) == false
            } ?? false
            throw OllamaHTTPError(
                statusCode: http.statusCode,
                hasAPIMessage: hasAPIMessage
            )
        }
    }

    private func records(
        from source: AsyncThrowingStream<Data, any Error>
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                var pending = Data()
                var totalBytes = 0
                do {
                    for try await chunk in source {
                        try Task.checkCancellation()
                        totalBytes += chunk.count
                        guard totalBytes <= OllamaStreamLimits.maxTotalBytes
                        else {
                            throw LocalAIError.malformedResponse
                        }
                        pending.append(chunk)

                        while let newline = pending.firstIndex(
                            of: Self.newline
                        ) {
                            let record = Data(pending.prefix(upTo: newline))
                            pending.removeSubrange(
                                pending.startIndex...newline
                            )
                            guard record.count
                                <= OllamaStreamLimits.maxRecordBytes else {
                                throw LocalAIError.malformedResponse
                            }
                            let trimmed = Self.trimmed(record)
                            if !trimmed.isEmpty {
                                continuation.yield(trimmed)
                            }
                        }

                        guard pending.count
                            <= OllamaStreamLimits.maxRecordBytes else {
                            throw LocalAIError.malformedResponse
                        }
                    }

                    try Task.checkCancellation()
                    let trailing = Self.trimmed(pending)
                    if !trailing.isEmpty {
                        continuation.yield(trailing)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.streamFailure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func streamFailure(_ error: any Error) -> any Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        return error
    }

    private static func trimmed(_ record: Data) -> Data {
        var slice = record[record.startIndex...]
        while let first = slice.first, whitespaceBytes.contains(first) {
            slice = slice.dropFirst()
        }
        while let last = slice.last, whitespaceBytes.contains(last) {
            slice = slice.dropLast()
        }
        return Data(slice)
    }
}

#if DEBUG
/// Stands in for a loader a test never exercises, so an unexpected call fails
/// loudly instead of reaching the network.
struct OllamaUnavailableLoader:
    OllamaDataLoading,
    OllamaByteStreamLoading,
    Sendable
{
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw LocalAIError.malformedResponse
    }

    func byteStream(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<Data, any Error>, URLResponse) {
        throw LocalAIError.malformedResponse
    }
}
#endif

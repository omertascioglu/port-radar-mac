import Foundation
import XCTest
@testable import DevPort

private final class AuthenticationChallengeSenderStub:
    NSObject,
    URLAuthenticationChallengeSender,
    @unchecked Sendable
{
    func use(
        _ credential: URLCredential,
        for challenge: URLAuthenticationChallenge
    ) {}

    func continueWithoutCredential(
        for challenge: URLAuthenticationChallenge
    ) {}

    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class NilURLHTTPURLResponse:
    HTTPURLResponse,
    @unchecked Sendable
{
    override var url: URL? { nil }
}

private enum FinalResponseURL: Sendable {
    case requestURL
    case explicit(URL)
    case missing
}

private enum LoaderResponse: Sendable {
    case http(
        statusCode: Int,
        finalURL: FinalResponseURL = .requestURL
    )
    case nonHTTP
    case cancellation

    func urlResponse(
        for request: URLRequest,
        contentLength: Int
    ) throws -> URLResponse {
        switch self {
        case .http(let statusCode, let finalURL):
            switch finalURL {
            case .requestURL:
                return HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            case .explicit(let url):
                return HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            case .missing:
                return NilURLHTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            }
        case .nonHTTP:
            return URLResponse(
                url: request.url!,
                mimeType: nil,
                expectedContentLength: contentLength,
                textEncodingName: nil
            )
        case .cancellation:
            throw CancellationError()
        }
    }
}

private actor LoaderSpy: OllamaDataLoading {
    private let response: LoaderResponse
    private let data: Data
    private var requests: [URLRequest] = []

    init(response: LoaderResponse = .http(statusCode: 200), data: Data = Data()) {
        self.response = response
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)

        return (
            data,
            try response.urlResponse(for: request, contentLength: data.count)
        )
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}

private actor AsyncOneShotSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signalled() -> Bool { isSignalled }
}

/// A byte source the test drives step by step: nothing arrives until the test
/// sends it, and the stream stays open until the test finishes it.
private final class ControlledByteSource: Sendable {
    let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let termination = AsyncOneShotSignal()

    init() {
        let (stream, continuation) = AsyncThrowingStream<
            Data,
            any Error
        >.makeStream()
        self.stream = stream
        self.continuation = continuation
        let termination = self.termination
        continuation.onTermination = { _ in
            Task { await termination.signal() }
        }
    }

    func send(_ text: String) {
        continuation.yield(Data(text.utf8))
    }

    func send(_ data: Data) {
        continuation.yield(data)
    }

    func finish() {
        continuation.finish()
    }

    func fail(_ error: any Error) {
        continuation.finish(throwing: error)
    }

    func waitUntilTerminated() async {
        await termination.wait()
    }

    func isTerminated() async -> Bool {
        await termination.signalled()
    }
}

private actor ByteStreamLoaderSpy: OllamaByteStreamLoading {
    private let response: LoaderResponse
    private let source: ControlledByteSource
    private var requests: [URLRequest] = []

    init(
        response: LoaderResponse = .http(statusCode: 200),
        source: ControlledByteSource = ControlledByteSource()
    ) {
        self.response = response
        self.source = source
    }

    func byteStream(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<Data, any Error>, URLResponse) {
        requests.append(request)

        return (
            source.stream,
            try response.urlResponse(for: request, contentLength: 0)
        )
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}

private enum TransportSourceError: Error {
    case missingSource(String)
}

final class OllamaTransportTests: XCTestCase {
    private let lease = OllamaServiceLease.testInstance(
        endpoint: OllamaServiceEndpoint(
            baseURL: URL(string: "http://127.0.0.1:11435")!,
            processIdentifier: 4321
        )
    )
    private var endpoint: OllamaServiceEndpoint { lease.endpoint }
    private var origin: String { lease.endpoint.baseURL.absoluteString }
    private var policy: OllamaOriginPolicy {
        OllamaOriginPolicy(endpoint: lease.endpoint)
    }

    func testAllowsOnlyTheLeasedOriginAndControlPaths() {
        for path in ["/api/version", "/api/tags", "/api/show", "/api/chat"] {
            XCTAssertTrue(
                policy.allows(URL(string: origin + path)!, path: path),
                path
            )
        }

        let rejected: [(url: String, path: String)] = [
            ("https://127.0.0.1:11435/api/chat", "/api/chat"),
            ("http://localhost:11435/api/chat", "/api/chat"),
            ("http://[::1]:11435/api/chat", "/api/chat"),
            ("http://127.0.0.2:11435/api/chat", "/api/chat"),
            ("http://0.0.0.0:11435/api/chat", "/api/chat"),
            ("http://10.0.0.5:11435/api/chat", "/api/chat"),
            ("http://ollama.com/api/chat", "/api/chat"),
            ("http://ollama.com:11435/api/chat", "/api/chat"),
            ("http://127.0.0.1:11436/api/chat", "/api/chat"),
            ("http://127.0.0.1:011435/api/chat", "/api/chat"),
            ("http://127.0.0.1/api/chat", "/api/chat"),
            ("http://user@127.0.0.1:11435/api/chat", "/api/chat"),
            ("http://user:password@127.0.0.1:11435/api/chat", "/api/chat"),
            ("http://127.0.0.1:11435/api/chat?model=remote", "/api/chat"),
            ("http://127.0.0.1:11435/api/chat#remote", "/api/chat"),
            ("http://127.0.0.1:11435/api/chat/", "/api/chat/"),
            ("http://127.0.0.1:11435/api%2Fchat", "/api/chat"),
            ("http://127.0.0.1:11435/api/../api/chat", "/api/chat"),
            ("http://127.0.0.1:11435/api/pull", "/api/pull"),
            ("http://127.0.0.1:11435/api/create", "/api/create"),
            ("http://127.0.0.1:11435/api/delete", "/api/delete"),
            ("http://127.0.0.1:11435/api/push", "/api/push"),
            ("http://127.0.0.1:11435/api/web_search", "/api/web_search"),
            ("http://127.0.0.1:11435/api/web_fetch", "/api/web_fetch"),
            ("http://127.0.0.1:11435/api/unknown", "/api/unknown"),
            ("http://127.0.0.1:11435/", "/"),
            ("http://127.0.0.1:11435/api/chat", "/api/tags"),
            ("http://127.0.0.1:11435/api/tags", "/api/pull"),
        ]

        for candidate in rejected {
            XCTAssertFalse(
                policy.allows(
                    URL(string: candidate.url)!,
                    path: candidate.path
                ),
                "\(candidate.url) as \(candidate.path)"
            )
        }
    }

    func testRejectsTheGloballyRunningOllamaPortWhileLeasedToThePrivateService() {
        XCTAssertFalse(policy.allows(
            URL(string: "http://127.0.0.1:11434/api/chat")!,
            path: "/api/chat"
        ))
        XCTAssertFalse(policy.allows(
            URL(string: "http://localhost:11434/api/tags")!,
            path: "/api/tags"
        ))
    }

    func testAllowsNothingWhenTheEndpointIsNotAPrivateLoopbackOrigin() {
        let unsafeOrigins = [
            "https://127.0.0.1:11435",
            "http://localhost:11435",
            "http://ollama.com:11435",
            "http://user@127.0.0.1:11435",
            "http://127.0.0.1:11435/api",
            "http://127.0.0.1",
        ]

        for unsafeOrigin in unsafeOrigins {
            let policy = OllamaOriginPolicy(
                endpoint: OllamaServiceEndpoint(
                    baseURL: URL(string: unsafeOrigin)!,
                    processIdentifier: 99
                )
            )

            for path in ["/api/version", "/api/tags", "/api/show", "/api/chat"] {
                XCTAssertFalse(
                    policy.allows(
                        URL(string: unsafeOrigin + path)!,
                        path: path
                    ),
                    "\(unsafeOrigin)\(path)"
                )
            }
        }
    }

    func testControlSessionDisablesPersistenceCredentialsAndProxying() {
        let session = OllamaSessionFactory.makeControlSession()
        let configuration = session.configuration

        XCTAssertFalse(session === URLSession.shared)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpAdditionalHeaders)
        XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 5)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 120)
    }

    func testRedirectDelegateRejectsEveryRedirectIncludingTheSameOrigin() async {
        let delegate = OllamaRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: origin + "/api/chat")!)
        let response = HTTPURLResponse(
            url: URL(string: origin + "/api/chat")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        let destinations = [
            origin + "/api/chat",
            origin + "/api/tags",
            origin + "/api/pull",
            "http://127.0.0.1:11434/api/chat",
            "https://ollama.com/api/chat",
        ]

        for destination in destinations {
            let redirected = await redirectedRequest(
                delegate: delegate,
                session: session,
                task: task,
                response: response,
                destination: destination
            )

            XCTAssertNil(redirected, destination)
        }
    }

    func testRedirectDelegateCancelsAuthenticationChallenges() async {
        let result = await withCheckedContinuation { continuation in
            OllamaRedirectDelegate().urlSession(
                URLSession(configuration: .ephemeral),
                didReceive: authenticationChallenge()
            ) { disposition, credential in
                continuation.resume(returning: (disposition, credential))
            }
        }

        XCTAssertEqual(result.0, .cancelAuthenticationChallenge)
        XCTAssertNil(result.1)
    }

    func testRedirectDelegateCancelsTaskAuthenticationChallenges() async {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: origin + "/api/chat")!)

        let result = await withCheckedContinuation { continuation in
            OllamaRedirectDelegate().urlSession(
                session,
                task: task,
                didReceive: authenticationChallenge()
            ) { disposition, credential in
                continuation.resume(returning: (disposition, credential))
            }
        }

        XCTAssertEqual(result.0, .cancelAuthenticationChallenge)
        XCTAssertNil(result.1)
    }

    func testLeaseBoundTransportUsesOnlyTheLeasedEndpoint() {
        let transport = OllamaTransport(lease: lease)

        XCTAssertEqual(transport.endpointForTesting, endpoint)
    }

    func testBuildsExactRequestsAndAddsJSONContentTypeOnlyWithBody() async throws {
        let loader = LoaderSpy(data: Data("success".utf8))
        let transport = OllamaTransport.testInstance(
            loader: loader,
            endpoint: endpoint
        )
        let body = Data("{\"model\":\"qwen3:4b\"}".utf8)

        let postData = try await transport.request(
            path: "/api/chat",
            method: "POST",
            body: body
        )
        _ = try await transport.request(path: "/api/tags")

        XCTAssertEqual(postData, Data("success".utf8))
        let requests = await loader.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            origin + "/api/chat"
        )
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].httpBody, body)
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertEqual(
            requests[1].url?.absoluteString,
            origin + "/api/tags"
        )
        XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertNil(requests[1].httpBody)
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Content-Type"))
    }

    func testRejectsUnsafePathBeforeInvokingLoader() async {
        let loader = LoaderSpy()
        let transport = OllamaTransport.testInstance(
            loader: loader,
            endpoint: endpoint
        )
        let unsafePaths = [
            "",
            "/",
            "/api/pull",
            "/api/create",
            "/api/delete",
            "/api/push",
            "/api/web_search",
            "/api/web_fetch",
            "/api/unknown",
            "/api/chat/",
            "/api/chat?model=remote",
            "/api/chat#remote",
            "/api/../api/chat",
            "/api%2Fchat",
            "api/chat",
            "//ollama.com/api/chat",
            "http://127.0.0.1:11435/api/chat",
        ]

        for path in unsafePaths {
            do {
                _ = try await transport.request(path: path)
                XCTFail("Expected unsafe path to be rejected: \(path)")
            } catch {
                XCTAssertEqual(error as? LocalAIError, .unsafeLocalEndpoint)
            }
        }

        let requests = await loader.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRejectsNonHTTPResponseAsMalformed() async {
        let transport = OllamaTransport.testInstance(
            loader: LoaderSpy(response: .nonHTTP),
            endpoint: endpoint
        )

        do {
            _ = try await transport.request(path: "/api/version")
            XCTFail("Expected non-HTTP response to be rejected")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .malformedResponse)
        }
    }

    func testRejectsFinalResponseURLOutsideLeasedOriginBeforeReturningData() async {
        let unsafeFinalURLs: [FinalResponseURL] = [
            .explicit(URL(string: "https://ollama.com/api/chat")!),
            .explicit(URL(string: "http://127.0.0.1:11434/api/chat")!),
            .explicit(URL(string: "http://localhost:11435/api/chat")!),
            .explicit(URL(string: "http://127.0.0.1:11435/api/pull")!),
            .explicit(URL(string: "http://127.0.0.1:11435/api/tags")!),
            .explicit(URL(string: "not-an-absolute-http-url")!),
            .missing,
        ]

        for finalURL in unsafeFinalURLs {
            let loader = LoaderSpy(
                response: .http(statusCode: 200, finalURL: finalURL),
                data: Data("must-not-be-returned".utf8)
            )
            let transport = OllamaTransport.testInstance(
                loader: loader,
                endpoint: endpoint
            )

            do {
                _ = try await transport.request(path: "/api/chat")
                XCTFail("Expected unsafe final response URL to be rejected")
            } catch {
                XCTAssertEqual(error as? LocalAIError, .unsafeLocalEndpoint)
            }
        }
    }

    func testRejectsEveryRedirectStatusAsUnsafe() async {
        for statusCode in [300, 302, 307, 308, 399] {
            let transport = OllamaTransport.testInstance(
                loader: LoaderSpy(response: .http(statusCode: statusCode)),
                endpoint: endpoint
            )

            do {
                _ = try await transport.request(path: "/api/version")
                XCTFail("Expected status \(statusCode) to be rejected")
            } catch {
                XCTAssertEqual(error as? LocalAIError, .unsafeLocalEndpoint)
            }
        }
    }

    func testHTTPErrorContainsOnlyBoundedMetadata() async {
        let secret = "request-secret-that-must-not-escape"
        let body = Data("{\"error\":\"server echoed \(secret)\"}".utf8)
        let transport = OllamaTransport.testInstance(
            loader: LoaderSpy(response: .http(statusCode: 500), data: body),
            endpoint: endpoint
        )

        do {
            _ = try await transport.request(
                path: "/api/chat",
                method: "POST",
                body: Data(secret.utf8)
            )
            XCTFail("Expected HTTP error")
        } catch let error as OllamaHTTPError {
            XCTAssertEqual(error.statusCode, 500)
            XCTAssertTrue(error.hasAPIMessage)
            XCTAssertFalse(error is any LocalizedError)
            XCTAssertEqual(
                Set(Mirror(reflecting: error).children.compactMap(\.label)),
                ["statusCode", "hasAPIMessage"]
            )
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
        } catch {
            XCTFail("Expected OllamaHTTPError, got \(error)")
        }
    }

    func testHTTPErrorReportsWhetherStructuredMessageExists() async {
        let cases: [(Data, Bool)] = [
            (Data("{\"error\":\"not found\"}".utf8), true),
            (Data("{\"error\":\"\"}".utf8), false),
            (Data("not-json".utf8), false),
        ]

        for (data, expectedHasMessage) in cases {
            let transport = OllamaTransport.testInstance(
                loader: LoaderSpy(response: .http(statusCode: 404), data: data),
                endpoint: endpoint
            )

            do {
                _ = try await transport.request(path: "/api/show")
                XCTFail("Expected HTTP error")
            } catch let error as OllamaHTTPError {
                XCTAssertEqual(error.statusCode, 404)
                XCTAssertEqual(error.hasAPIMessage, expectedHasMessage)
            } catch {
                XCTFail("Expected OllamaHTTPError, got \(error)")
            }
        }
    }

    func testLoaderCancellationRemainsCancellationError() async {
        let transport = OllamaTransport.testInstance(
            loader: LoaderSpy(response: .cancellation),
            endpoint: endpoint
        )

        do {
            _ = try await transport.request(path: "/api/chat")
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testStreamingSessionKeepsNoFiveSecondChatDeadlineAndNoPersistence() {
        let session = OllamaSessionFactory.makeStreamingSession()
        let configuration = session.configuration

        XCTAssertFalse(session === URLSession.shared)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpAdditionalHeaders)
        XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
        XCTAssertNotEqual(configuration.timeoutIntervalForRequest, 5)
        XCTAssertGreaterThanOrEqual(configuration.timeoutIntervalForRequest, 60)
        XCTAssertGreaterThanOrEqual(
            configuration.timeoutIntervalForResource,
            3600
        )
        XCTAssertEqual(
            OllamaSessionFactory.makeControlSession()
                .configuration.timeoutIntervalForRequest,
            5
        )
    }

    func testStreamBuildsTheExactChatRequestAndYieldsRecordsInOrder() async throws {
        let source = ControlledByteSource()
        let loader = ByteStreamLoaderSpy(source: source)
        let transport = OllamaTransport.testInstance(
            streamLoader: loader,
            endpoint: endpoint
        )
        let body = Data("{\"model\":\"qwen3:4b\",\"stream\":true}".utf8)

        let stream = try await transport.stream(
            path: "/api/chat",
            method: "POST",
            body: body
        )
        source.send("{\"one\":1}\n{\"two\":2}\n{\"three\":3}\n")
        source.finish()

        let records = try await collect(stream)
        XCTAssertEqual(
            records,
            ["{\"one\":1}", "{\"two\":2}", "{\"three\":3}"]
        )
        let requests = await loader.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, origin + "/api/chat")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].httpBody, body)
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
    }

    func testStreamDeliversEachRecordWhileTheProducerStaysSuspended() async throws {
        let source = ControlledByteSource()
        let transport = OllamaTransport.testInstance(
            streamLoader: ByteStreamLoaderSpy(source: source),
            endpoint: endpoint
        )

        let stream = try await transport.stream(
            path: "/api/chat",
            method: "POST",
            body: Data("{}".utf8)
        )
        var iterator = stream.makeAsyncIterator()

        source.send("{\"index\":1}\n")
        let first = try await iterator.next()
        XCTAssertEqual(first.map(text), "{\"index\":1}")
        var terminated = await source.isTerminated()
        XCTAssertFalse(terminated)

        source.send("{\"index\":2}\n")
        let second = try await iterator.next()
        XCTAssertEqual(second.map(text), "{\"index\":2}")
        terminated = await source.isTerminated()
        XCTAssertFalse(terminated)

        source.finish()
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testStreamIgnoresBlankLinesAndCarriageReturns() async throws {
        let source = ControlledByteSource()
        let transport = OllamaTransport.testInstance(
            streamLoader: ByteStreamLoaderSpy(source: source),
            endpoint: endpoint
        )

        let stream = try await transport.stream(
            path: "/api/chat",
            method: "POST",
            body: Data("{}".utf8)
        )
        source.send("\n\r\n{\"one\":1}\r\n   \n\t\n{\"two\":2}\r\n\n")
        source.finish()

        let records = try await collect(stream)
        XCTAssertEqual(records, ["{\"one\":1}", "{\"two\":2}"])
    }

    func testStreamReassemblesRecordsSplitAcrossChunksAndFlushesTheLast() async throws {
        let source = ControlledByteSource()
        let transport = OllamaTransport.testInstance(
            streamLoader: ByteStreamLoaderSpy(source: source),
            endpoint: endpoint
        )

        let stream = try await transport.stream(
            path: "/api/chat",
            method: "POST",
            body: Data("{}".utf8)
        )
        source.send("{\"one\"")
        source.send(":1}\n{\"two\"")
        source.send(":2}")
        source.finish()

        let records = try await collect(stream)
        XCTAssertEqual(records, ["{\"one\":1}", "{\"two\":2}"])
    }

    func testStreamRejectsAnOversizedRecordBeforeYieldingOrDecodingIt() async throws {
        let secret = "oversized-record-must-not-escape"
        let oversized = secret + String(
            repeating: "a",
            count: OllamaStreamLimits.maxRecordBytes
        )

        for terminatesLine in [true, false] {
            let source = ControlledByteSource()
            let transport = OllamaTransport.testInstance(
                streamLoader: ByteStreamLoaderSpy(source: source),
                endpoint: endpoint
            )

            let stream = try await transport.stream(
                path: "/api/chat",
                method: "POST",
                body: Data("{}".utf8)
            )
            source.send(terminatesLine ? oversized + "\n" : oversized)

            let outcome = await outcome(of: stream)
            XCTAssertTrue(outcome.records.isEmpty, "\(terminatesLine)")
            XCTAssertEqual(
                outcome.error as? LocalAIError,
                .malformedResponse,
                "\(terminatesLine)"
            )
            XCTAssertFalse(
                String(describing: outcome.error).contains(secret)
            )
        }
    }

    func testStreamRejectsAnOversizedCumulativeResponse() async throws {
        let source = ControlledByteSource()
        let transport = OllamaTransport.testInstance(
            streamLoader: ByteStreamLoaderSpy(source: source),
            endpoint: endpoint
        )
        let record = "{\"chunk\":\""
            + String(repeating: "a", count: 32 * 1024)
            + "\"}\n"
        let recordCount = OllamaStreamLimits.maxTotalBytes
            / record.utf8.count + 1

        let stream = try await transport.stream(
            path: "/api/chat",
            method: "POST",
            body: Data("{}".utf8)
        )
        for _ in 0..<recordCount {
            source.send(record)
        }
        source.finish()

        let outcome = await outcome(of: stream)
        XCTAssertEqual(outcome.error as? LocalAIError, .malformedResponse)
        XCTAssertLessThan(outcome.records.count, recordCount)
    }

    func testStreamRejectsUnsafePathsBeforeInvokingTheLoader() async {
        let loader = ByteStreamLoaderSpy()
        let transport = OllamaTransport.testInstance(
            streamLoader: loader,
            endpoint: endpoint
        )

        for path in [
            "",
            "/",
            "/api/pull",
            "/api/create",
            "/api/push",
            "/api/web_search",
            "/api/chat/",
            "/api/chat?model=remote",
            "/api/../api/chat",
            "api/chat",
            "//ollama.com/api/chat",
            "http://127.0.0.1:11435/api/chat",
        ] {
            do {
                _ = try await transport.stream(
                    path: path,
                    method: "POST",
                    body: Data("{}".utf8)
                )
                XCTFail("Expected unsafe stream path to be rejected: \(path)")
            } catch {
                XCTAssertEqual(error as? LocalAIError, .unsafeLocalEndpoint)
            }
        }

        let requests = await loader.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testStreamRejectsNonHTTPResponseAsMalformed() async {
        let transport = OllamaTransport.testInstance(
            streamLoader: ByteStreamLoaderSpy(response: .nonHTTP),
            endpoint: endpoint
        )

        do {
            _ = try await transport.stream(
                path: "/api/chat",
                method: "POST",
                body: Data("{}".utf8)
            )
            XCTFail("Expected non-HTTP streamed response to be rejected")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .malformedResponse)
        }
    }

    func testStreamRejectsFinalResponseURLOutsideLeasedOriginBeforeReturning() async {
        let unsafeFinalURLs: [FinalResponseURL] = [
            .explicit(URL(string: "https://ollama.com/api/chat")!),
            .explicit(URL(string: "http://127.0.0.1:11434/api/chat")!),
            .explicit(URL(string: "http://localhost:11435/api/chat")!),
            .explicit(URL(string: "http://127.0.0.1:11435/api/pull")!),
            .explicit(URL(string: "http://127.0.0.1:11435/api/tags")!),
            .explicit(URL(string: "not-an-absolute-http-url")!),
            .missing,
        ]

        for finalURL in unsafeFinalURLs {
            let source = ControlledByteSource()
            source.send("{\"must\":\"not-be-exposed\"}\n")
            let transport = OllamaTransport.testInstance(
                streamLoader: ByteStreamLoaderSpy(
                    response: .http(statusCode: 200, finalURL: finalURL),
                    source: source
                ),
                endpoint: endpoint
            )

            do {
                _ = try await transport.stream(
                    path: "/api/chat",
                    method: "POST",
                    body: Data("{}".utf8)
                )
                XCTFail("Expected unsafe streamed final URL to be rejected")
            } catch {
                XCTAssertEqual(error as? LocalAIError, .unsafeLocalEndpoint)
            }
        }
    }

    func testStreamRejectsEveryRedirectStatusAsUnsafe() async {
        for statusCode in [300, 302, 307, 308, 399] {
            let transport = OllamaTransport.testInstance(
                streamLoader: ByteStreamLoaderSpy(
                    response: .http(statusCode: statusCode)
                ),
                endpoint: endpoint
            )

            do {
                _ = try await transport.stream(
                    path: "/api/chat",
                    method: "POST",
                    body: Data("{}".utf8)
                )
                XCTFail("Expected streamed status \(statusCode) to be rejected")
            } catch {
                XCTAssertEqual(error as? LocalAIError, .unsafeLocalEndpoint)
            }
        }
    }

    func testStreamHTTPErrorContainsOnlyBoundedMetadata() async {
        let secret = "streamed-request-secret-that-must-not-escape"
        let source = ControlledByteSource()
        source.send("{\"error\":\"server echoed \(secret)\"}\n")
        let transport = OllamaTransport.testInstance(
            streamLoader: ByteStreamLoaderSpy(
                response: .http(statusCode: 500),
                source: source
            ),
            endpoint: endpoint
        )

        do {
            _ = try await transport.stream(
                path: "/api/chat",
                method: "POST",
                body: Data(secret.utf8)
            )
            XCTFail("Expected streamed HTTP error")
        } catch let error as OllamaHTTPError {
            XCTAssertEqual(error.statusCode, 500)
            XCTAssertFalse(error.hasAPIMessage)
            XCTAssertEqual(
                Set(Mirror(reflecting: error).children.compactMap(\.label)),
                ["statusCode", "hasAPIMessage"]
            )
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
        } catch {
            XCTFail("Expected OllamaHTTPError, got \(error)")
        }
    }

    func testStreamLoaderCancellationRemainsCancellationError() async {
        let transport = OllamaTransport.testInstance(
            streamLoader: ByteStreamLoaderSpy(response: .cancellation),
            endpoint: endpoint
        )

        do {
            _ = try await transport.stream(
                path: "/api/chat",
                method: "POST",
                body: Data("{}".utf8)
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testStreamMapsCancelledURLErrorMidStreamToCancellationError() async throws {
        let source = ControlledByteSource()
        let transport = OllamaTransport.testInstance(
            streamLoader: ByteStreamLoaderSpy(source: source),
            endpoint: endpoint
        )

        let stream = try await transport.stream(
            path: "/api/chat",
            method: "POST",
            body: Data("{}".utf8)
        )
        source.send("{\"one\":1}\n")
        source.fail(URLError(.cancelled))

        let outcome = await outcome(of: stream)
        XCTAssertEqual(outcome.records, ["{\"one\":1}"])
        XCTAssertTrue(
            outcome.error is CancellationError,
            "Expected CancellationError, got \(String(describing: outcome.error))"
        )
    }

    func testStreamPropagatesOtherMidStreamFailuresUnchanged() async throws {
        let source = ControlledByteSource()
        let transport = OllamaTransport.testInstance(
            streamLoader: ByteStreamLoaderSpy(source: source),
            endpoint: endpoint
        )

        let stream = try await transport.stream(
            path: "/api/chat",
            method: "POST",
            body: Data("{}".utf8)
        )
        source.fail(URLError(.networkConnectionLost))

        let outcome = await outcome(of: stream)
        XCTAssertTrue(outcome.records.isEmpty)
        XCTAssertEqual((outcome.error as? URLError)?.code, .networkConnectionLost)
    }

    func testConsumerCancellationStopsTheUpstreamProducer() async throws {
        let source = ControlledByteSource()
        let transport = OllamaTransport.testInstance(
            streamLoader: ByteStreamLoaderSpy(source: source),
            endpoint: endpoint
        )
        let received = AsyncOneShotSignal()

        let stream = try await transport.stream(
            path: "/api/chat",
            method: "POST",
            body: Data("{}".utf8)
        )
        let consumer = Task {
            for try await _ in stream {
                await received.signal()
            }
        }
        source.send("{\"one\":1}\n")
        await received.wait()

        let stopped = expectation(description: "upstream producer stopped")
        Task {
            await source.waitUntilTerminated()
            stopped.fulfill()
        }
        consumer.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        _ = try? await consumer.value
    }

    func testTransportSourceExposesNoArbitraryOriginOrSharedSessionInitializer() throws {
        let text = try transportSource()

        XCTAssertFalse(text.contains("11434"))
        XCTAssertFalse(text.contains("URLSession.shared"))
        XCTAssertFalse(text.contains("static let baseURL"))
        XCTAssertEqual(
            releaseVisibleInitializers(in: text),
            ["init(lease: OllamaServiceLease) {"]
        )
        XCTAssertTrue(text.contains("#if DEBUG"))
        XCTAssertFalse(
            releaseVisibleSource(in: text).contains("testInstance")
        )
    }

    private func text(_ record: Data) -> String {
        String(decoding: record, as: UTF8.self)
    }

    private func collect(
        _ stream: AsyncThrowingStream<Data, any Error>
    ) async throws -> [String] {
        var records: [String] = []
        for try await record in stream {
            records.append(text(record))
        }
        return records
    }

    private func outcome(
        of stream: AsyncThrowingStream<Data, any Error>
    ) async -> (records: [String], error: (any Error)?) {
        var records: [String] = []
        do {
            for try await record in stream {
                records.append(text(record))
            }
            return (records, nil)
        } catch {
            return (records, error)
        }
    }

    private func transportSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DevPort/AI/OllamaTransport.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TransportSourceError.missingSource(url.path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func releaseVisibleSource(in text: String) -> String {
        var isDebugOnly = false
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "#if DEBUG" {
                    isDebugOnly = true
                    return false
                }
                if isDebugOnly, trimmed == "#endif" {
                    isDebugOnly = false
                    return false
                }
                return !isDebugOnly
            }
            .joined(separator: "\n")
    }

    private func releaseVisibleInitializers(in text: String) -> [String] {
        releaseVisibleSource(in: text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("init(") }
    }

    private func redirectedRequest(
        delegate: OllamaRedirectDelegate,
        session: URLSession,
        task: URLSessionTask,
        response: HTTPURLResponse,
        destination: String
    ) async -> URLRequest? {
        await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: destination)!)
            ) { request in
                continuation.resume(returning: request)
            }
        }
    }

    private func authenticationChallenge() -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: "127.0.0.1",
                port: 11435,
                protocol: "http",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            ),
            proposedCredential: URLCredential(
                user: "unexpected",
                password: "credential",
                persistence: .none
            ),
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: AuthenticationChallengeSenderStub()
        )
    }
}

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

        switch response {
        case .http(let statusCode, let finalURL):
            let response: HTTPURLResponse
            switch finalURL {
            case .requestURL:
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            case .explicit(let url):
                response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            case .missing:
                response = NilURLHTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            }
            return (data, response)
        case .nonHTTP:
            return (
                data,
                URLResponse(
                    url: request.url!,
                    mimeType: nil,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
            )
        case .cancellation:
            throw CancellationError()
        }
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

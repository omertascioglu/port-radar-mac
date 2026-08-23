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

private enum LoaderResponse: Sendable {
    case http(statusCode: Int)
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
        case .http(let statusCode):
            return (
                data,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
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

final class OllamaTransportTests: XCTestCase {
    private let policy = OllamaOriginPolicy()

    func testAllowsOnlyExactOriginAndKnownPaths() {
        let allowed = [
            "http://127.0.0.1:11434/api/version",
            "http://127.0.0.1:11434/api/tags",
            "http://127.0.0.1:11434/api/show",
            "http://127.0.0.1:11434/api/chat",
        ]
        let rejected = [
            "https://127.0.0.1:11434/api/chat",
            "http://localhost:11434/api/chat",
            "http://127.0.0.1:11435/api/chat",
            "http://127.0.0.1:011434/api/chat",
            "http://ollama.com/api/chat",
            "http://127.0.0.1:11434/api/pull",
            "http://user@127.0.0.1:11434/api/chat",
            "http://user:password@127.0.0.1:11434/api/chat",
            "http://127.0.0.1:11434/api/chat?model=remote",
            "http://127.0.0.1:11434/api/chat#remote",
            "http://127.0.0.1:11434/api/chat/",
            "http://127.0.0.1:11434/api%2Fchat",
            "http://127.0.0.1:11434/api/../api/chat",
        ]

        for url in allowed {
            XCTAssertTrue(policy.allows(URL(string: url)!), url)
        }
        for url in rejected {
            XCTAssertFalse(policy.allows(URL(string: url)!), url)
        }
    }

    func testRedirectPolicyUsesTheSameExactBoundary() {
        XCTAssertTrue(policy.allowsRedirect(to: URL(string:
            "http://127.0.0.1:11434/api/chat")!))
        XCTAssertFalse(policy.allowsRedirect(to: URL(string:
            "https://ollama.com/api/chat")!))
        XCTAssertFalse(policy.allowsRedirect(to: URL(string:
            "http://127.0.0.1:11434/api/pull")!))
        XCTAssertFalse(policy.allowsRedirect(to: URL(string:
            "http://127.0.0.1:11434/api/chat?redirect=true")!))
    }

    func testSessionDisablesPersistenceCredentialsAndProxying() {
        let session = OllamaSessionFactory.make()
        let configuration = session.configuration

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 5)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 120)
    }

    func testRedirectDelegateAllowsOnlyPolicyApprovedDestinations() async {
        let delegate = OllamaRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string:
            "http://127.0.0.1:11434/api/chat")!)
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:11434/api/chat")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!

        let allowed = await redirectedRequest(
            delegate: delegate,
            session: session,
            task: task,
            response: response,
            destination: "http://127.0.0.1:11434/api/tags"
        )
        let rejected = await redirectedRequest(
            delegate: delegate,
            session: session,
            task: task,
            response: response,
            destination: "http://127.0.0.1:11434/api/pull"
        )

        XCTAssertEqual(allowed?.url?.path, "/api/tags")
        XCTAssertNil(rejected)
    }

    func testRedirectDelegateCancelsAuthenticationChallenges() async {
        let protectionSpace = URLProtectionSpace(
            host: "127.0.0.1",
            port: 11434,
            protocol: "http",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
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

        let result = await withCheckedContinuation { continuation in
            OllamaRedirectDelegate().urlSession(
                URLSession(configuration: .ephemeral),
                didReceive: challenge
            ) { disposition, credential in
                continuation.resume(returning: (disposition, credential))
            }
        }

        XCTAssertEqual(result.0, .cancelAuthenticationChallenge)
        XCTAssertNil(result.1)
    }

    func testBuildsExactRequestsAndAddsJSONContentTypeOnlyWithBody() async throws {
        let loader = LoaderSpy(data: Data("success".utf8))
        let transport = OllamaTransport(loader: loader)
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
            "http://127.0.0.1:11434/api/chat"
        )
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].httpBody, body)
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertEqual(
            requests[1].url?.absoluteString,
            "http://127.0.0.1:11434/api/tags"
        )
        XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertNil(requests[1].httpBody)
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Content-Type"))
    }

    func testRejectsUnsafePathBeforeInvokingLoader() async {
        let loader = LoaderSpy()
        let transport = OllamaTransport(loader: loader)
        let unsafePaths = [
            "/api/pull",
            "/api/../api/chat",
            "/api%2Fchat",
            "api/chat",
            "//ollama.com/api/chat",
            "http://127.0.0.1:11434/api/chat",
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
        let transport = OllamaTransport(loader: LoaderSpy(response: .nonHTTP))

        do {
            _ = try await transport.request(path: "/api/version")
            XCTFail("Expected non-HTTP response to be rejected")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .malformedResponse)
        }
    }

    func testRejectsEveryRedirectStatusAsUnsafe() async {
        for statusCode in [300, 302, 307, 308, 399] {
            let transport = OllamaTransport(
                loader: LoaderSpy(response: .http(statusCode: statusCode))
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
        let transport = OllamaTransport(
            loader: LoaderSpy(response: .http(statusCode: 500), data: body)
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
            let transport = OllamaTransport(
                loader: LoaderSpy(response: .http(statusCode: 404), data: data)
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
        let transport = OllamaTransport(loader: LoaderSpy(response: .cancellation))

        do {
            _ = try await transport.request(path: "/api/chat")
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
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
}

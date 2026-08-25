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

enum OllamaSessionFactory {
    /// Configuration for short buffered control requests. Streaming responses
    /// carry their own configuration and must not inherit these deadlines.
    static func makeControlSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 120
        return URLSession(
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

protocol OllamaTransporting: Sendable {
    func request(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Data
}

struct OllamaHTTPError: Error, Sendable {
    let statusCode: Int
    let hasAPIMessage: Bool
}

struct OllamaTransport: OllamaTransporting, Sendable {
    private let loader: any OllamaDataLoading
    private let policy: OllamaOriginPolicy

    init(lease: OllamaServiceLease) {
        loader = OllamaSessionFactory.makeControlSession()
        policy = OllamaOriginPolicy(endpoint: lease.endpoint)
    }

    private init(
        loader: any OllamaDataLoading,
        endpoint: OllamaServiceEndpoint
    ) {
        self.loader = loader
        self.policy = OllamaOriginPolicy(endpoint: endpoint)
    }

    #if DEBUG
    static func testInstance(
        loader: any OllamaDataLoading,
        endpoint: OllamaServiceEndpoint
    ) -> Self {
        Self(loader: loader, endpoint: endpoint)
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

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }

        let (data, response) = try await loader.data(for: request)
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
            let hasAPIMessage = (try? JSONDecoder()
                .decode(OllamaAPIErrorResponse.self, from: data)
                .error.isEmpty) == false
            throw OllamaHTTPError(
                statusCode: http.statusCode,
                hasAPIMessage: hasAPIMessage
            )
        }
        return data
    }
}

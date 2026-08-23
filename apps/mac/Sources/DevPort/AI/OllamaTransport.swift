import Foundation

struct OllamaOriginPolicy: Sendable {
    static let baseURL = URL(string: "http://127.0.0.1:11434")!
    static let allowedPaths: Set<String> = [
        "/api/version",
        "/api/tags",
        "/api/show",
        "/api/chat",
    ]

    func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: true
        ) else {
            return false
        }
        let expectedURLString = Self.baseURL.absoluteString + components.path

        return components.scheme == "http"
            && components.host == "127.0.0.1"
            && components.port == 11434
            && Self.allowedPaths.contains(components.path)
            && components.percentEncodedPath == components.path
            && url.absoluteString == expectedURLString
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    func allowsRedirect(to url: URL) -> Bool {
        allows(url)
    }
}

final class OllamaRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    URLSessionDelegate,
    @unchecked Sendable
{
    private let policy = OllamaOriginPolicy()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, policy.allowsRedirect(to: url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
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
    static func make() -> URLSession {
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

struct OllamaHTTPError: Error, Sendable {
    let statusCode: Int
    let hasAPIMessage: Bool
}

struct OllamaTransport: Sendable {
    private let loader: any OllamaDataLoading
    private let policy = OllamaOriginPolicy()

    init() {
        loader = OllamaSessionFactory.make()
    }

    private init(loader: any OllamaDataLoading) {
        self.loader = loader
    }

    #if DEBUG
    static func testInstance(loader: any OllamaDataLoading) -> Self {
        Self(loader: loader)
    }
    #endif

    func request(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Data {
        guard OllamaOriginPolicy.allowedPaths.contains(path),
              let url = URL(
                string: OllamaOriginPolicy.baseURL.absoluteString + path
              ),
              policy.allows(url)
        else {
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
        guard let finalURL = http.url, policy.allows(finalURL) else {
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

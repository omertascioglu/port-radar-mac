import Foundation
import XCTest
@testable import DevPort

private struct CapturedOllamaRequest: Equatable, Sendable {
    let path: String
    let method: String
    let body: Data?
}

private enum QueuedTransportResult: @unchecked Sendable {
    case success(Data)
    case failure(any Error)
}

private actor QueueTransport: OllamaTransporting {
    private var queuedResults: [QueuedTransportResult]
    private var requests: [CapturedOllamaRequest] = []

    init(_ queuedResults: [QueuedTransportResult]) {
        self.queuedResults = queuedResults
    }

    func request(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Data {
        requests.append(.init(path: path, method: method, body: body))
        guard !queuedResults.isEmpty else {
            throw URLError(.badServerResponse)
        }

        switch queuedResults.removeFirst() {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func capturedRequests() -> [CapturedOllamaRequest] {
        requests
    }
}

private enum ClientSourceError: Error {
    case missingSource(String)
}

final class OllamaClientTests: XCTestCase {
    func testPrivateServiceClientBindsItsTransportToTheLeasedEndpoint() throws {
        let endpoint = OllamaServiceEndpoint(
            baseURL: URL(string: "http://127.0.0.1:11435")!,
            processIdentifier: 7788
        )
        let lease = OllamaServiceLease.testInstance(endpoint: endpoint)

        let client = PrivateServiceOllamaClient.factory(lease)

        let transport = try XCTUnwrap(
            (client as? OllamaClient)?.transport as? OllamaTransport
        )
        XCTAssertEqual(transport.endpointForTesting, endpoint)
    }

    func testClientSourceExposesNoDefaultTransportForAGlobalService() throws {
        let text = try clientSource()

        XCTAssertFalse(text.contains("11434"))
        XCTAssertFalse(text.contains("URLSession.shared"))
        XCTAssertFalse(text.contains("OllamaTransport()"))
        XCTAssertEqual(
            releaseVisibleInitializers(in: text),
            ["init(transport: any OllamaTransporting) {"]
        )
    }

    func testVersionUsesExactServiceDiscoveryRequest() async throws {
        let transport = QueueTransport([
            .success(Data("{\"version\":\"0.11.8\"}".utf8)),
        ])
        let client = OllamaClient(transport: transport)

        let version = try await client.version()

        XCTAssertEqual(version, "0.11.8")
        let requests = await transport.capturedRequests()
        XCTAssertEqual(
            requests,
            [.init(path: "/api/version", method: "GET", body: nil)]
        )
    }

    func testMalformedVersionMapsToBoundedError() async {
        let secret = "synthetic-version-body-must-not-escape"
        let client = OllamaClient(transport: QueueTransport([
            .success(Data("not-json-\(secret)".utf8)),
        ]))

        do {
            _ = try await client.version()
            XCTFail("Expected malformed version JSON")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .malformedResponse)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertTrue(Mirror(reflecting: error).children.isEmpty)
        }
    }

    func testListModelsReturnsOnlyProvenLocalEntries() async throws {
        let transport = QueueTransport([.success(Data(
            """
            {"models":[
              {
                "name":"qwen3:4b",
                "model":"qwen3:4b",
                "size":2500000000,
                "digest":"sha256-local",
                "details":{"format":"gguf"}
              },
              {
                "name":"remote:cloud",
                "model":"remote:cloud",
                "remote_host":"https://ollama.com:443",
                "size":42,
                "digest":"sha256-remote",
                "details":{"format":"gguf"}
              },
              {
                "name":"ambiguous:latest",
                "model":"ambiguous:latest",
                "size":0,
                "digest":"",
                "details":{}
              }
            ]}
            """.utf8
        ))])
        let client = OllamaClient(transport: transport)

        let models = try await client.localModels()

        XCTAssertEqual(
            models,
            [.init(id: "qwen3:4b", size: 2_500_000_000, format: "gguf")]
        )
        let requests = await transport.capturedRequests()
        XCTAssertEqual(
            requests,
            [.init(path: "/api/tags", method: "GET", body: nil)]
        )
    }

    func testValidateModelUsesShowAndRejectsRemoteMetadata() async throws {
        let transport = QueueTransport([
            .success(localTagsData()),
            .success(Data(
                """
                {
                  "remote_host":"https://ollama.com:443",
                  "details":{"format":"gguf"}
                }
                """.utf8
            )),
        ])
        let client = OllamaClient(transport: transport)

        do {
            try await client.validateLocalModel("qwen3:4b")
            XCTFail("Expected remote show metadata to be rejected")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .remoteModelRejected)
        }

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.path), ["/api/tags", "/api/show"])
        XCTAssertEqual(requests.map(\.method), ["GET", "POST"])
        let body = try jsonObject(try XCTUnwrap(requests.last?.body))
        XCTAssertEqual(Set(body.keys), ["model"])
        XCTAssertEqual(body["model"] as? String, "qwen3:4b")
    }

    func testValidateModelRequiresListMembershipBeforeShow() async {
        let transport = QueueTransport([.success(Data("{\"models\":[]}".utf8))])
        let client = OllamaClient(transport: transport)

        do {
            try await client.validateLocalModel("missing:latest")
            XCTFail("Expected missing model to be rejected")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .ollamaModelUnavailable)
        }

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.path), ["/api/tags"])
    }

    func testChatEncodesNoToolsAndUsesTwoMinuteKeepAlive() async throws {
        let transport = QueueTransport([.success(Data(
            """
            {"message":{"role":"assistant","content":"Local answer"}}
            """.utf8
        ))])
        let client = OllamaClient(transport: transport)
        let messages = [OllamaChatMessage(
            role: "user",
            content: "What owns port 3000?"
        )]

        let response = try await client.chat(
            model: "qwen3:4b",
            messages: messages
        )

        XCTAssertEqual(response, "Local answer")
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].path, "/api/chat")
        XCTAssertEqual(requests[0].method, "POST")
        let body = try jsonObject(try XCTUnwrap(requests[0].body))
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["model"] as? String, "qwen3:4b")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? String, "2m")
        XCTAssertEqual(
            body["messages"] as? [[String: String]],
            [["role": "user", "content": "What owns port 3000?"]]
        )
    }

    func testUnloadUsesEmptyMessagesAndZeroKeepAlive() async throws {
        let transport = QueueTransport([.success(Data())])
        let client = OllamaClient(transport: transport)

        await client.unload(model: "qwen3:4b")

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].path, "/api/chat")
        XCTAssertEqual(requests[0].method, "POST")
        let body = try jsonObject(try XCTUnwrap(requests[0].body))
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["model"] as? String, "qwen3:4b")
        XCTAssertEqual(body["messages"] as? [[String: String]], [])
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? Int, 0)
    }

    func testUnloadIsBestEffortAndDoesNotThrow() async {
        let transport = QueueTransport([
            .failure(URLError(.cannotConnectToHost)),
        ])
        let client = OllamaClient(transport: transport)

        await client.unload(model: "qwen3:4b")

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testConnectionFailuresMapToNotRunning() async {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .cannotConnectToHost,
            .networkConnectionLost,
        ]

        for code in codes {
            let transport = QueueTransport([.failure(URLError(code))])
            let client = OllamaClient(transport: transport)

            do {
                _ = try await client.localModels()
                XCTFail("Expected \(code) to fail")
            } catch {
                XCTAssertEqual(error as? LocalAIError, .ollamaNotRunning)
            }
        }
    }

    func testTimeoutMapsToTimedOut() async {
        let client = OllamaClient(transport: QueueTransport([
            .failure(URLError(.timedOut)),
        ]))

        do {
            _ = try await client.localModels()
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .timedOut)
        }
    }

    func testCancellationRemainsCancellation() async {
        let client = OllamaClient(transport: QueueTransport([
            .failure(CancellationError()),
        ]))

        do {
            _ = try await client.localModels()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCancelledURLErrorBecomesCancellation() async {
        let client = OllamaClient(transport: QueueTransport([
            .failure(URLError(.cancelled)),
        ]))

        do {
            _ = try await client.localModels()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testHTTPErrorMapsToBoundedError() async {
        let secret = "synthetic-server-secret-must-not-escape"
        let client = OllamaClient(transport: QueueTransport([
            .failure(OllamaHTTPError(statusCode: 500, hasAPIMessage: true)),
        ]))

        do {
            _ = try await client.chat(
                model: "qwen3:4b",
                messages: [.init(role: "user", content: secret)]
            )
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .malformedResponse)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertTrue(Mirror(reflecting: error).children.isEmpty)
        }
    }

    func testMalformedJSONMapsToBoundedError() async {
        let secret = "synthetic-response-secret-must-not-escape"
        let client = OllamaClient(transport: QueueTransport([
            .success(Data("not-json-\(secret)".utf8)),
        ]))

        do {
            _ = try await client.localModels()
            XCTFail("Expected malformed JSON")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .malformedResponse)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertTrue(Mirror(reflecting: error).children.isEmpty)
        }
    }

    private func clientSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DevPort/AI/OllamaClient.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClientSourceError.missingSource(url.path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func releaseVisibleInitializers(in text: String) -> [String] {
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
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("init(") }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

private func localTagsData() -> Data {
    Data(
        """
        {"models":[{
          "name":"qwen3:4b",
          "model":"qwen3:4b",
          "size":2500000000,
          "digest":"sha256-local",
          "details":{"format":"gguf"}
        }]}
        """.utf8
    )
}

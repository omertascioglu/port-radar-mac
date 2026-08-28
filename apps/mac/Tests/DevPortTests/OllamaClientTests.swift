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

private actor RecordSourceSignal {
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

/// A record stream the test drives: records arrive only when the test sends
/// them, and the stream stays open until the test closes it.
private final class ControlledRecordSource: Sendable {
    let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let termination = RecordSourceSignal()

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

    func send(_ record: String) {
        continuation.yield(Data(record.utf8))
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

private enum QueuedStreamResult: @unchecked Sendable {
    case records([String])
    case recordsThenFailure([String], any Error)
    case source(ControlledRecordSource)
    case failure(any Error)
    case suspendedUntilCancelled
}

private actor QueueTransport: OllamaTransporting {
    private var queuedResults: [QueuedTransportResult]
    private let streamResult: QueuedStreamResult
    private var requests: [CapturedOllamaRequest] = []
    private var streamRequests: [CapturedOllamaRequest] = []
    private var suspendedStream: CheckedContinuation<
        AsyncThrowingStream<Data, any Error>,
        any Error
    >?
    private var didCancelSuspendedStream = false

    init(
        _ queuedResults: [QueuedTransportResult] = [],
        stream streamResult: QueuedStreamResult = .records([])
    ) {
        self.queuedResults = queuedResults
        self.streamResult = streamResult
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

    func stream(
        path: String,
        method: String,
        body: Data?
    ) async throws -> AsyncThrowingStream<Data, any Error> {
        streamRequests.append(.init(path: path, method: method, body: body))

        switch streamResult {
        case .records(let records):
            return finishedStream(records, failure: nil)
        case .recordsThenFailure(let records, let error):
            return finishedStream(records, failure: error)
        case .source(let source):
            return source.stream
        case .failure(let error):
            throw error
        case .suspendedUntilCancelled:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if didCancelSuspendedStream {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        suspendedStream = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelSuspendedStream() }
            }
        }
    }

    func capturedRequests() -> [CapturedOllamaRequest] {
        requests
    }

    func capturedStreamRequests() -> [CapturedOllamaRequest] {
        streamRequests
    }

    private func cancelSuspendedStream() {
        didCancelSuspendedStream = true
        suspendedStream?.resume(throwing: CancellationError())
        suspendedStream = nil
    }

    private func finishedStream(
        _ records: [String],
        failure: (any Error)?
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream<Data, any Error> { continuation in
            for record in records {
                continuation.yield(Data(record.utf8))
            }
            continuation.finish(throwing: failure)
        }
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

    func testChatStreamAsksForStreamingAndKeepsTheModelLoadedPastTheStream() async throws {
        let transport = QueueTransport(stream: .records([
            contentRecord("Local answer"),
            finalRecord,
        ]))
        let client = OllamaClient(transport: transport)
        let messages = [OllamaChatMessage(
            role: "user",
            content: "What owns port 3000?"
        )]

        let chunks = try await collect(
            try await client.chatStream(
                model: "qwen3:4b",
                messages: messages
            )
        )

        XCTAssertEqual(chunks, ["Local answer"])
        let bufferedRequests = await transport.capturedRequests()
        XCTAssertTrue(bufferedRequests.isEmpty)
        let requests = await transport.capturedStreamRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].path, "/api/chat")
        XCTAssertEqual(requests[0].method, "POST")
        let body = try jsonObject(try XCTUnwrap(requests[0].body))
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["model"] as? String, "qwen3:4b")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["keep_alive"] as? String, "2m")
        XCTAssertNotEqual(body["keep_alive"] as? Int, 0)
        XCTAssertEqual(
            body["messages"] as? [[String: String]],
            [["role": "user", "content": "What owns port 3000?"]]
        )
    }

    func testChatStreamYieldsAssistantChunksInOrderBeforeTheFinalMarker() async throws {
        let transport = QueueTransport(stream: .records([
            contentRecord("Hel"),
            "",
            "   ",
            contentRecord(""),
            contentRecord("lo"),
            "{\"created_at\":\"2026-08-25T00:00:00Z\"}",
            contentRecord("!"),
            finalRecord,
            contentRecord("must-not-be-yielded"),
        ]))
        let client = OllamaClient(transport: transport)

        let chunks = try await collect(
            try await client.chatStream(
                model: "qwen3:4b",
                messages: [.init(role: "user", content: "Explain it")]
            )
        )

        XCTAssertEqual(chunks, ["Hel", "lo", "!"])
    }

    func testChatStreamDeliversTheFirstChunkWhileTheStreamStaysOpen() async throws {
        let source = ControlledRecordSource()
        let client = OllamaClient(
            transport: QueueTransport(stream: .source(source))
        )

        let stream = try await client.chatStream(
            model: "qwen3:4b",
            messages: [.init(role: "user", content: "Explain it")]
        )
        var iterator = stream.makeAsyncIterator()

        source.send(contentRecord("Hel"))
        let first = try await iterator.next()
        XCTAssertEqual(first, "Hel")
        let terminatedAfterFirst = await source.isTerminated()
        XCTAssertFalse(terminatedAfterFirst)

        source.send(contentRecord("lo"))
        let second = try await iterator.next()
        XCTAssertEqual(second, "lo")

        source.send(finalRecord)
        source.finish()
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testChatStreamRejectsAPIErrorRecordWithoutExposingTheServerBody() async throws {
        let secret = "synthetic-stream-error-must-not-escape"
        let client = OllamaClient(transport: QueueTransport(stream: .records([
            contentRecord("Hel"),
            "{\"error\":\"\(secret)\"}",
            finalRecord,
        ])))

        let outcome = await outcome(
            of: try await client.chatStream(
                model: "qwen3:4b",
                messages: []
            )
        )

        XCTAssertEqual(outcome.chunks, ["Hel"])
        XCTAssertEqual(outcome.error as? LocalAIError, .malformedResponse)
        XCTAssertFalse(String(describing: outcome.error).contains(secret))
        XCTAssertFalse(String(reflecting: outcome.error).contains(secret))
    }

    func testChatStreamRejectsUnreadableRecordWithoutExposingIt() async throws {
        let secret = "synthetic-stream-body-must-not-escape"
        let client = OllamaClient(transport: QueueTransport(stream: .records([
            contentRecord("Hel"),
            "not-json-\(secret)",
            finalRecord,
        ])))

        let outcome = await outcome(
            of: try await client.chatStream(
                model: "qwen3:4b",
                messages: []
            )
        )

        XCTAssertEqual(outcome.chunks, ["Hel"])
        XCTAssertEqual(outcome.error as? LocalAIError, .malformedResponse)
        XCTAssertFalse(String(describing: outcome.error).contains(secret))
    }

    func testChatStreamRequiresTheFinalDoneRecord() async throws {
        let client = OllamaClient(transport: QueueTransport(stream: .records([
            contentRecord("Hel"),
            contentRecord("lo"),
        ])))

        let outcome = await outcome(
            of: try await client.chatStream(
                model: "qwen3:4b",
                messages: []
            )
        )

        XCTAssertEqual(outcome.chunks, ["Hel", "lo"])
        XCTAssertEqual(outcome.error as? LocalAIError, .malformedResponse)
    }

    func testChatStreamMapsCancelledURLErrorMidStreamToCancellation() async throws {
        let client = OllamaClient(transport: QueueTransport(
            stream: .recordsThenFailure(
                [contentRecord("Hel")],
                URLError(.cancelled)
            )
        ))

        let outcome = await outcome(
            of: try await client.chatStream(
                model: "qwen3:4b",
                messages: []
            )
        )

        XCTAssertEqual(outcome.chunks, ["Hel"])
        XCTAssertTrue(
            outcome.error is CancellationError,
            "Expected CancellationError, got \(String(describing: outcome.error))"
        )
    }

    func testChatStreamMapsMidStreamTransportFailuresToBoundedErrors() async throws {
        let cases: [(any Error, LocalAIError)] = [
            (URLError(.cannotConnectToHost), .ollamaNotRunning),
            (URLError(.timedOut), .timedOut),
            (URLError(.badServerResponse), .malformedResponse),
            (OllamaHTTPError(statusCode: 500, hasAPIMessage: true), .malformedResponse),
        ]

        for (failure, expected) in cases {
            let client = OllamaClient(transport: QueueTransport(
                stream: .recordsThenFailure([], failure)
            ))

            let outcome = await outcome(
                of: try await client.chatStream(
                    model: "qwen3:4b",
                    messages: []
                )
            )

            XCTAssertTrue(outcome.chunks.isEmpty)
            XCTAssertEqual(outcome.error as? LocalAIError, expected)
        }
    }

    func testChatStreamMapsFailureToOpenTheStreamToBoundedError() async {
        let secret = "synthetic-server-secret-must-not-escape"
        let client = OllamaClient(transport: QueueTransport(
            stream: .failure(OllamaHTTPError(statusCode: 500, hasAPIMessage: true))
        ))

        do {
            _ = try await client.chatStream(
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

    func testChatStreamCancellationWhileOpeningTheStreamYieldsCancellation() async {
        let transport = QueueTransport(stream: .suspendedUntilCancelled)
        let client = OllamaClient(transport: transport)
        let started = expectation(description: "chat stream requested")

        let task = Task {
            started.fulfill()
            return try await client.chatStream(
                model: "qwen3:4b",
                messages: []
            )
        }
        await fulfillment(of: [started], timeout: 5)
        while await transport.capturedStreamRequests().isEmpty {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testChatStreamConsumerCancellationStopsTheUpstreamRecords() async throws {
        let source = ControlledRecordSource()
        let client = OllamaClient(
            transport: QueueTransport(stream: .source(source))
        )
        let received = RecordSourceSignal()

        let stream = try await client.chatStream(
            model: "qwen3:4b",
            messages: []
        )
        let consumer = Task {
            for try await _ in stream {
                await received.signal()
            }
        }
        source.send(contentRecord("Hel"))
        await received.wait()

        let stopped = expectation(description: "upstream records stopped")
        Task {
            await source.waitUntilTerminated()
            stopped.fulfill()
        }
        consumer.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        _ = try? await consumer.value
    }

    func testControlCallsAndUnloadStayBufferedBoundedRequests() async throws {
        let transport = QueueTransport([
            .success(Data("{\"version\":\"0.11.8\"}".utf8)),
            .success(localTagsData()),
            .success(localTagsData()),
            .success(Data("{\"details\":{\"format\":\"gguf\"}}".utf8)),
            .success(Data()),
        ])
        let client = OllamaClient(transport: transport)

        _ = try await client.version()
        _ = try await client.localModels()
        try await client.validateLocalModel("qwen3:4b")
        await client.unload(model: "qwen3:4b")

        let requests = await transport.capturedRequests()
        XCTAssertEqual(
            requests.map(\.path),
            ["/api/version", "/api/tags", "/api/tags", "/api/show", "/api/chat"]
        )
        let streamRequests = await transport.capturedStreamRequests()
        XCTAssertTrue(streamRequests.isEmpty)
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
            _ = try await client.validateLocalModel(secret)
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

    private var finalRecord: String {
        "{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}"
    }

    private func contentRecord(_ content: String) -> String {
        """
        {"model":"qwen3:4b","message":{"role":"assistant","content":"\(content)"},"done":false}
        """
    }

    private func collect(
        _ stream: LocalAITextStream
    ) async throws -> [String] {
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    private func outcome(
        of stream: LocalAITextStream
    ) async -> (chunks: [String], error: (any Error)?) {
        var chunks: [String] = []
        do {
            for try await chunk in stream {
                chunks.append(chunk)
            }
            return (chunks, nil)
        } catch {
            return (chunks, error)
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

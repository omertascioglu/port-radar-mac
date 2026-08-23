# Local Ollama Fallback Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an optional, strictly local Ollama fallback to Port Radar's process chat while preserving Apple's on-device model as the Automatic-mode preference.

**Architecture:** A provider-neutral conversation layer separates SwiftUI from Apple Foundation Models and Ollama. The resolver chooses Apple or a validated local Ollama model, while a single sanitizer and a strict loopback-only transport enforce the privacy boundary.

**Tech Stack:** Swift 6, SwiftUI, Observation, Foundation URLSession, FoundationModels behind conditional compilation, XCTest, Swift Package Manager.

---

## Working rules

- Work only on branch feature/local-ollama-fallback in the isolated repository.
- Use @superpowers:test-driven-development for every behavior change.
- Use @superpowers:systematic-debugging for any unexpected compiler or test
  failure.
- Use @superpowers:verification-before-completion before each commit and before
  the final handoff.
- Do not install, launch, stop, or download Ollama during automated tests.
- Do not modify Cloudflare tunnel code in this branch.
- Do not rename Port Radar or change LICENSE/NOTICE ownership.
- Keep each commit limited to the task named below.

Run all Swift commands from the repository root unless a step says otherwise.
The package path is apps/mac.

## Task 1: Establish the test target and SDK compatibility seam

**Files:**

- Modify: apps/mac/Package.swift
- Modify: apps/mac/Sources/DevPort/Actions/ProcessAgent.swift
- Modify: apps/mac/Sources/DevPort/Views/AgentChatView.swift
- Modify: apps/mac/Sources/DevPort/Views/ContentView.swift:136
- Create: apps/mac/Tests/DevPortTests/BuildSmokeTests.swift

**Step 1: Add a test target and the first smoke test**

Add DevPortTests beside the executable target:

    // Add a trailing comma after the existing executableTarget.
    .testTarget(
        name: "DevPortTests",
        dependencies: ["DevPort"],
        path: "Tests/DevPortTests"
    )

Create BuildSmokeTests.swift:

    import XCTest
    @testable import DevPort

    final class BuildSmokeTests: XCTestCase {
        func testProviderPreferenceDefaultsToAutomatic() {
            XCTAssertEqual(
                LocalAIProviderPreference.persistedValue(nil),
                .automatic
            )
        }
    }

The type intentionally does not exist yet.

**Step 2: Run the test and capture the expected failure**

Run:

    swift test --package-path apps/mac --filter BuildSmokeTests

Expected: FAIL. On an SDK without FoundationModels the first compiler error is
No such module 'FoundationModels'; on a newer SDK the missing
LocalAIProviderPreference error is sufficient red evidence.

**Step 3: Add the minimum compile-time framework guards**

In ProcessAgent.swift, wrap the FoundationModels import and the entire
ProcessAgent declaration in canImport:

    import Foundation

    #if canImport(FoundationModels)
    import FoundationModels

    @available(macOS 26.0, *)
    enum ProcessAgent {
        // Keep the existing implementation unchanged for now.
    }
    #endif

Keep the DevServer context extension outside the guard because both providers
will need it.

In AgentChatView.swift, keep AgentMessage and AgentUnavailableModal outside the
guard, but wrap the import and current AgentChatModal:

    import SwiftUI

    #if canImport(FoundationModels)
    import FoundationModels

    @available(macOS 26.0, *)
    struct AgentChatModal: View {
        // Keep the existing implementation unchanged for now.
    }
    #endif

In ContentView.swift, make the current presentation compile on either SDK:

    } else if let agentServer {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            AgentChatModal(
                server: agentServer,
                onDismiss: { self.agentServer = nil }
            )
        } else {
            AgentUnavailableModal(
                server: agentServer,
                onDismiss: { self.agentServer = nil }
            )
        }
        #else
        AgentUnavailableModal(
            server: agentServer,
            onDismiss: { self.agentServer = nil }
        )
        #endif

**Step 4: Add the minimal preference enum**

Create a temporary definition at the bottom of Preferences.swift; Task 2 moves
it into the domain file:

    enum LocalAIProviderPreference: String, Equatable, Sendable {
        case automatic
        case apple
        case ollama

        static func persistedValue(_ rawValue: String?) -> Self {
            rawValue.flatMap(Self.init(rawValue:)) ?? .automatic
        }
    }

**Step 5: Run the focused and full suites**

Run:

    swift test --package-path apps/mac --filter BuildSmokeTests
    swift test --package-path apps/mac

Expected: both commands PASS on the current macOS 15 SDK without importing
FoundationModels.

**Step 6: Commit**

    git add apps/mac/Package.swift \
      apps/mac/Sources/DevPort/Actions/ProcessAgent.swift \
      apps/mac/Sources/DevPort/Views/AgentChatView.swift \
      apps/mac/Sources/DevPort/Views/ContentView.swift \
      apps/mac/Sources/DevPort/State/Preferences.swift \
      apps/mac/Tests/DevPortTests/BuildSmokeTests.swift
    git commit -m "test: add local AI test target"

## Task 2: Define provider-neutral types and deterministic resolution

**Files:**

- Create: apps/mac/Sources/DevPort/AI/LocalAIProvider.swift
- Create: apps/mac/Sources/DevPort/AI/LocalAIError.swift
- Create: apps/mac/Sources/DevPort/AI/AIProviderResolver.swift
- Create: apps/mac/Tests/DevPortTests/AIProviderResolverTests.swift
- Modify: apps/mac/Sources/DevPort/State/Preferences.swift
- Modify: apps/mac/Tests/DevPortTests/BuildSmokeTests.swift

**Step 1: Write resolver spies and failing selection tests**

AIProviderResolverTests.swift should define an actor-backed spy:

    import XCTest
    @testable import DevPort

    private actor ProviderSpy: LocalAIProvider {
        nonisolated let id: LocalAIProviderID
        private let result: LocalAIAvailability
        private(set) var availabilityCalls = 0

        init(id: LocalAIProviderID, result: LocalAIAvailability) {
            self.id = id
            self.result = result
        }

        func availability(modelID: String?) async -> LocalAIAvailability {
            availabilityCalls += 1
            return result
        }

        func makeConversation(
            context: SanitizedProcessContext,
            modelID: String?
        ) async throws -> any LocalAIConversation {
            ConversationStub(providerID: id)
        }

        func callCount() -> Int { availabilityCalls }
    }

    private actor ConversationStub: LocalAIConversation {
        nonisolated let providerID: LocalAIProviderID
        init(providerID: LocalAIProviderID) {
            self.providerID = providerID
        }
        func respond(to prompt: String) async throws -> String { "stub" }
        func close() async {}
    }

Add these tests:

    final class AIProviderResolverTests: XCTestCase {
        private let context = SanitizedProcessContext(text: "port: 3000")

        func testAutomaticPrefersAppleWithoutProbingOllama() async throws {
            let apple = ProviderSpy(id: .apple, result: .available)
            let ollama = ProviderSpy(id: .ollama, result: .available)
            let resolver = AIProviderResolver(apple: apple, ollama: ollama)

            let resolved = try await resolver.resolve(
                preference: .automatic,
                ollamaModelID: "qwen3:4b",
                context: context
            )

            XCTAssertEqual(resolved.providerID, .apple)
            let appleCalls = await apple.callCount()
            let ollamaCalls = await ollama.callCount()
            XCTAssertEqual(appleCalls, 1)
            XCTAssertEqual(ollamaCalls, 0)
        }

        func testAutomaticFallsBackToOllama() async throws {
            let apple = ProviderSpy(
                id: .apple,
                result: .unavailable(.appleUnavailable("disabled"))
            )
            let ollama = ProviderSpy(id: .ollama, result: .available)
            let resolver = AIProviderResolver(apple: apple, ollama: ollama)

            let resolved = try await resolver.resolve(
                preference: .automatic,
                ollamaModelID: "qwen3:4b",
                context: context
            )

            XCTAssertEqual(resolved.providerID, .ollama)
        }

        func testForcedAppleNeverProbesOllama() async {
            let apple = ProviderSpy(
                id: .apple,
                result: .unavailable(.appleUnavailable("disabled"))
            )
            let ollama = ProviderSpy(id: .ollama, result: .available)
            let resolver = AIProviderResolver(apple: apple, ollama: ollama)

            do {
                _ = try await resolver.resolve(
                    preference: .apple,
                    ollamaModelID: "qwen3:4b",
                    context: self.context
                )
                XCTFail("Expected forced Apple to stay unavailable")
            } catch {
                // Expected.
            }
            let ollamaCalls = await ollama.callCount()
            XCTAssertEqual(ollamaCalls, 0)
        }

        func testForcedOllamaWinsWhenAppleIsAvailable() async throws {
            let apple = ProviderSpy(id: .apple, result: .available)
            let ollama = ProviderSpy(id: .ollama, result: .available)
            let resolver = AIProviderResolver(apple: apple, ollama: ollama)

            let resolved = try await resolver.resolve(
                preference: .ollama,
                ollamaModelID: "qwen3:4b",
                context: context
            )

            XCTAssertEqual(resolved.providerID, .ollama)
            let appleCalls = await apple.callCount()
            XCTAssertEqual(appleCalls, 0)
        }
    }

**Step 2: Run the resolver tests**

Run:

    swift test --package-path apps/mac --filter AIProviderResolverTests

Expected: FAIL because the provider-neutral types and resolver do not exist.

**Step 3: Implement the domain contracts**

Move LocalAIProviderPreference from Preferences.swift into
AI/LocalAIProvider.swift and complete the file:

    import Foundation

    enum LocalAIProviderID: String, Equatable, Sendable {
        case apple
        case ollama

        var badgeText: String {
            switch self {
            case .apple: "Apple · On-device"
            case .ollama: "Ollama · Local"
            }
        }
    }

    enum LocalAIProviderPreference: String, CaseIterable, Identifiable, Sendable {
        case automatic
        case apple
        case ollama

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .automatic: "Automatic"
            case .apple: "Apple Intelligence"
            case .ollama: "Ollama"
            }
        }

        static func persistedValue(_ rawValue: String?) -> Self {
            rawValue.flatMap(Self.init(rawValue:)) ?? .automatic
        }
    }

    struct SanitizedProcessContext: Equatable, Sendable {
        let text: String
    }

    enum LocalAIAvailability: Equatable, Sendable {
        case available
        case unavailable(LocalAIError)
    }

    protocol LocalAIConversation: Sendable {
        var providerID: LocalAIProviderID { get }
        func respond(to prompt: String) async throws -> String
        func close() async
    }

    protocol LocalAIProvider: Sendable {
        var id: LocalAIProviderID { get }
        func availability(modelID: String?) async -> LocalAIAvailability
        func makeConversation(
            context: SanitizedProcessContext,
            modelID: String?
        ) async throws -> any LocalAIConversation
    }

    struct ResolvedLocalAIConversation: Sendable {
        let providerID: LocalAIProviderID
        let conversation: any LocalAIConversation

        var badgeText: String { providerID.badgeText }
    }

Implement LocalAIError.swift:

    import Foundation

    enum LocalAIError: Error, Equatable, LocalizedError, Sendable {
        case appleUnavailable(String)
        case ollamaNotRunning
        case ollamaModelRequired
        case ollamaModelUnavailable
        case remoteModelRejected
        case unsafeLocalEndpoint
        case timedOut
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .appleUnavailable(let reason): reason
            case .ollamaNotRunning: "Ollama is not running."
            case .ollamaModelRequired: "Choose an installed local Ollama model."
            case .ollamaModelUnavailable:
                "The selected local Ollama model is no longer available."
            case .remoteModelRejected:
                "Cloud and remote Ollama models are not allowed."
            case .unsafeLocalEndpoint:
                "Ollama redirected outside Port Radar's local-only boundary."
            case .timedOut: "The local model took too long to respond."
            case .malformedResponse:
                "Ollama returned an unreadable response."
            }
        }
    }

**Step 4: Implement the resolver**

AIProviderResolver.swift:

    struct AIProviderResolver: Sendable {
        let apple: any LocalAIProvider
        let ollama: any LocalAIProvider

        func resolve(
            preference: LocalAIProviderPreference,
            ollamaModelID: String?,
            context: SanitizedProcessContext
        ) async throws -> ResolvedLocalAIConversation {
            switch preference {
            case .automatic:
                if case .available = await apple.availability(modelID: nil) {
                    return try await make(apple, context: context, modelID: nil)
                }
                return try await require(
                    ollama,
                    context: context,
                    modelID: ollamaModelID
                )
            case .apple:
                return try await require(apple, context: context, modelID: nil)
            case .ollama:
                return try await require(
                    ollama,
                    context: context,
                    modelID: ollamaModelID
                )
            }
        }

        private func require(
            _ provider: any LocalAIProvider,
            context: SanitizedProcessContext,
            modelID: String?
        ) async throws -> ResolvedLocalAIConversation {
            switch await provider.availability(modelID: modelID) {
            case .available:
                return try await make(
                    provider,
                    context: context,
                    modelID: modelID
                )
            case .unavailable(let error):
                throw error
            }
        }

        private func make(
            _ provider: any LocalAIProvider,
            context: SanitizedProcessContext,
            modelID: String?
        ) async throws -> ResolvedLocalAIConversation {
            ResolvedLocalAIConversation(
                providerID: provider.id,
                conversation: try await provider.makeConversation(
                    context: context,
                    modelID: modelID
                )
            )
        }
    }

**Step 5: Run focused and full tests**

    swift test --package-path apps/mac --filter AIProviderResolverTests
    swift test --package-path apps/mac

Expected: PASS.

**Step 6: Commit**

    git add apps/mac/Sources/DevPort/AI \
      apps/mac/Sources/DevPort/State/Preferences.swift \
      apps/mac/Tests/DevPortTests
    git commit -m "feat: add local AI provider resolver"

## Task 3: Sanitize one process snapshot for both providers

**Files:**

- Create: apps/mac/Sources/DevPort/AI/ProcessContextSanitizer.swift
- Create: apps/mac/Tests/DevPortTests/ProcessContextSanitizerTests.swift
- Modify: apps/mac/Sources/DevPort/Actions/ProcessAgent.swift

**Step 1: Write failing sanitizer tests**

Create ProcessContextSanitizerTests.swift with synthetic values only:

    import XCTest
    @testable import DevPort

    final class ProcessContextSanitizerTests: XCTestCase {
        func testRedactsEnvironmentAndCLISecrets() {
            let raw = """
            command: API_KEY=sk-test-secret node app.js \
            --token ghp_examplevalue --password=hunter2 --port 3000
            """

            let value = ProcessContextSanitizer.sanitize(raw).text

            XCTAssertFalse(value.contains("sk-test-secret"))
            XCTAssertFalse(value.contains("ghp_examplevalue"))
            XCTAssertFalse(value.contains("hunter2"))
            XCTAssertTrue(value.contains("API_KEY=[REDACTED]"))
            XCTAssertTrue(value.contains("--port 3000"))
        }

        func testRedactsBearerURLCredentialsAndSecretQuery() {
            let raw = """
            Authorization: Bearer abc.def.ghi
            DATABASE_URL=https://alice:secret@example.test/db?token=query-secret
            """

            let value = ProcessContextSanitizer.sanitize(raw).text

            XCTAssertFalse(value.contains("abc.def.ghi"))
            XCTAssertFalse(value.contains("alice:secret"))
            XCTAssertFalse(value.contains("query-secret"))
        }

        func testSanitizationIsIdempotentAndPreservesSafeContext() {
            let raw = "port: 5173\npid: 42\nframework: Vite\ncommand: vite --host"
            let once = ProcessContextSanitizer.sanitize(raw)
            let twice = ProcessContextSanitizer.sanitize(once.text)

            XCTAssertEqual(once, twice)
            XCTAssertTrue(once.text.contains("port: 5173"))
            XCTAssertTrue(once.text.contains("framework: Vite"))
        }
    }

**Step 2: Run the tests**

    swift test --package-path apps/mac --filter ProcessContextSanitizerTests

Expected: FAIL because ProcessContextSanitizer does not exist.

**Step 3: Implement ordered, bounded redaction**

ProcessContextSanitizer.swift:

    import Foundation

    enum ProcessContextSanitizer {
        private static let sensitiveName =
            "(?:token|secret|password|passwd|api[_-]?key|access[_-]?key|" +
            "private[_-]?key|client[_-]?secret|authorization|cookie)"

        static func sanitize(_ raw: String) -> SanitizedProcessContext {
            var value = raw
            value = replacing(
                #"(?i)\b(\#(sensitiveName))=([^\s]+)"#,
                in: value,
                with: "$1=[REDACTED]"
            )
            value = replacing(
                #"(?i)(--\#(sensitiveName))(?:=|\s+)([^\s]+)"#,
                in: value,
                with: "$1=[REDACTED]"
            )
            value = replacing(
                #"(?i)\bBearer\s+[A-Za-z0-9._~+/\-=]+"#,
                in: value,
                with: "Bearer [REDACTED]"
            )
            value = replacing(
                #"(?i)(https?://)[^/\s:@]+:[^@\s/]+@"#,
                in: value,
                with: "$1[REDACTED]@"
            )
            value = replacing(
                #"(?i)([?&]\#(sensitiveName)=)[^&#\s]+"#,
                in: value,
                with: "$1[REDACTED]"
            )
            value = replacing(
                #"\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]+|xox[baprs]-[A-Za-z0-9-]+|sk-[A-Za-z0-9_-]{12,})\b"#,
                in: value,
                with: "[REDACTED]"
            )
            return SanitizedProcessContext(text: value)
        }

        private static func replacing(
            _ pattern: String,
            in value: String,
            with template: String
        ) -> String {
            guard let expression = try? NSRegularExpression(pattern: pattern)
            else { return value }
            let range = NSRange(value.startIndex..., in: value)
            return expression.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: template
            )
        }
    }

During implementation, do not paste this blindly: Swift raw-string interpolation
must compile to the intended regular expression. Assert each pattern through the
tests before adding the next. Preserve [REDACTED] so a second pass is unchanged.

**Step 4: Move process context construction**

Rename the DevServer property in ProcessAgent.swift from agentContext to
rawAgentContext and make its documentation provider-neutral:

    extension DevServer {
        var rawAgentContext: String {
            // Keep the existing field construction exactly as-is.
        }

        var sanitizedAgentContext: SanitizedProcessContext {
            ProcessContextSanitizer.sanitize(rawAgentContext)
        }
    }

Update the temporary Apple ProcessAgent to interpolate
server.sanitizedAgentContext.text.

**Step 5: Run tests and inspect for accidental secret output**

    swift test --package-path apps/mac --filter ProcessContextSanitizerTests
    swift test --package-path apps/mac
    rg -n "print\\(|debugPrint\\(|NSLog\\(|os_log" apps/mac/Sources/DevPort/AI

Expected: tests PASS and the search returns no request, prompt, response, or
sanitizer logging.

**Step 6: Commit**

    git add apps/mac/Sources/DevPort/AI/ProcessContextSanitizer.swift \
      apps/mac/Sources/DevPort/Actions/ProcessAgent.swift \
      apps/mac/Tests/DevPortTests/ProcessContextSanitizerTests.swift
    git commit -m "feat: redact secrets from process context"

## Task 4: Model Ollama responses and reject remote models

**Files:**

- Create: apps/mac/Sources/DevPort/AI/OllamaModels.swift
- Create: apps/mac/Tests/DevPortTests/OllamaModelValidationTests.swift

**Step 1: Write failing decoding and validation tests**

Use JSON fixtures inline and keep them free of real machine data:

    import XCTest
    @testable import DevPort

    final class OllamaModelValidationTests: XCTestCase {
        func testDecodesProvenLocalModel() throws {
            let data = Data("""
            {"models":[{
              "name":"qwen3:4b",
              "model":"qwen3:4b",
              "size":2500000000,
              "digest":"sha256-local",
              "details":{"format":"gguf"}
            }]}
            """.utf8)

            let response = try JSONDecoder().decode(
                OllamaTagsResponse.self,
                from: data
            )

            XCTAssertEqual(response.validatedLocalModels.map(\.id), ["qwen3:4b"])
        }

        func testRejectsRemoteMetadataAndCloudSuffixes() throws {
            let data = Data("""
            {"models":[
              {
                "name":"glm:cloud",
                "model":"glm:cloud",
                "remote_model":"glm",
                "remote_host":"https://ollama.com:443",
                "size":123,
                "digest":"stub",
                "details":{"format":"gguf"}
              },
              {
                "name":"qwen:397b-cloud",
                "model":"qwen:397b-cloud",
                "size":123,
                "digest":"stub",
                "details":{"format":"gguf"}
              }
            ]}
            """.utf8)

            let response = try JSONDecoder().decode(
                OllamaTagsResponse.self,
                from: data
            )

            XCTAssertTrue(response.validatedLocalModels.isEmpty)
        }

        func testRejectsAmbiguousLocalEvidence() throws {
            let entry = OllamaModelSummary(
                name: "alias",
                model: "alias",
                remoteModel: nil,
                remoteHost: nil,
                size: 0,
                digest: "",
                details: .init(format: "")
            )
            XCTAssertFalse(entry.isProvenLocal)
        }
    }

**Step 2: Run the tests**

    swift test --package-path apps/mac --filter OllamaModelValidationTests

Expected: FAIL because the response types do not exist.

**Step 3: Implement defensive DTOs**

OllamaModels.swift:

    import Foundation

    struct OllamaModel: Identifiable, Equatable, Sendable {
        let id: String
        let size: Int64
        let format: String
    }

    struct OllamaModelDetails: Decodable, Equatable, Sendable {
        let format: String?
    }

    struct OllamaModelSummary: Decodable, Equatable, Sendable {
        let name: String
        let model: String
        let remoteModel: String?
        let remoteHost: String?
        let size: Int64?
        let digest: String?
        let details: OllamaModelDetails?

        enum CodingKeys: String, CodingKey {
            case name, model, size, digest, details
            case remoteModel = "remote_model"
            case remoteHost = "remote_host"
        }

        var isProvenLocal: Bool {
            let identifier = model.isEmpty ? name : model
            let lower = identifier.lowercased()
            return remoteModel.nilOrEmpty
                && remoteHost.nilOrEmpty
                && !lower.hasSuffix(":cloud")
                && !lower.hasSuffix("-cloud")
                && (size ?? 0) > 0
                && !(digest ?? "").isEmpty
                && !(details?.format ?? "").isEmpty
        }

        var localModel: OllamaModel? {
            guard isProvenLocal else { return nil }
            return OllamaModel(
                id: model.isEmpty ? name : model,
                size: size ?? 0,
                format: details?.format ?? ""
            )
        }
    }

    struct OllamaTagsResponse: Decodable, Sendable {
        let models: [OllamaModelSummary]
        var validatedLocalModels: [OllamaModel] {
            models.compactMap(\.localModel)
        }
    }

    struct OllamaShowResponse: Decodable, Sendable {
        let remoteModel: String?
        let remoteHost: String?
        let details: OllamaModelDetails?

        enum CodingKeys: String, CodingKey {
            case details
            case remoteModel = "remote_model"
            case remoteHost = "remote_host"
        }

        var confirmsLocalExecution: Bool {
            remoteModel.nilOrEmpty
                && remoteHost.nilOrEmpty
                && !(details?.format ?? "").isEmpty
        }
    }

    private extension Optional where Wrapped == String {
        var nilOrEmpty: Bool { self?.isEmpty != false }
    }

Also define the minimal version, chat request, chat response, and API error DTOs
in this file. Chat request must encode model, messages, stream, and keep_alive,
and it must have no tools property:

    struct OllamaChatMessage: Codable, Equatable, Sendable {
        let role: String
        let content: String
    }

    struct OllamaChatRequest: Encodable, Sendable {
        let model: String
        let messages: [OllamaChatMessage]
        let stream: Bool
        let keepAlive: OllamaKeepAlive

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case keepAlive = "keep_alive"
        }
    }

    struct OllamaVersionResponse: Decodable, Sendable {
        let version: String
    }

    struct OllamaChatResponse: Decodable, Sendable {
        let message: OllamaChatMessage
    }

    struct OllamaAPIErrorResponse: Decodable, Sendable {
        let error: String
    }

    enum OllamaKeepAlive: Encodable, Sendable {
        case duration(String)
        case seconds(Int)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .duration(let value): try container.encode(value)
            case .seconds(let value): try container.encode(value)
            }
        }
    }

**Step 4: Run focused and full tests**

    swift test --package-path apps/mac --filter OllamaModelValidationTests
    swift test --package-path apps/mac

Expected: PASS.

**Step 5: Commit**

    git add apps/mac/Sources/DevPort/AI/OllamaModels.swift \
      apps/mac/Tests/DevPortTests/OllamaModelValidationTests.swift
    git commit -m "feat: reject remote Ollama models"

## Task 5: Enforce the exact loopback transport boundary

**Files:**

- Create: apps/mac/Sources/DevPort/AI/OllamaTransport.swift
- Create: apps/mac/Tests/DevPortTests/OllamaTransportTests.swift

**Step 1: Write failing origin and request tests**

OllamaTransportTests.swift:

    import XCTest
    @testable import DevPort

    final class OllamaTransportTests: XCTestCase {
        private let policy = OllamaOriginPolicy()

        func testAllowsOnlyExactOriginAndKnownPaths() {
            XCTAssertTrue(policy.allows(URL(string:
                "http://127.0.0.1:11434/api/tags")!))
            XCTAssertTrue(policy.allows(URL(string:
                "http://127.0.0.1:11434/api/chat")!))

            XCTAssertFalse(policy.allows(URL(string:
                "https://127.0.0.1:11434/api/chat")!))
            XCTAssertFalse(policy.allows(URL(string:
                "http://localhost:11434/api/chat")!))
            XCTAssertFalse(policy.allows(URL(string:
                "http://127.0.0.1:11435/api/chat")!))
            XCTAssertFalse(policy.allows(URL(string:
                "http://ollama.com/api/chat")!))
            XCTAssertFalse(policy.allows(URL(string:
                "http://127.0.0.1:11434/api/pull")!))
        }

        func testRedirectPolicyRejectsChangedOriginOrPath() {
            XCTAssertTrue(policy.allowsRedirect(to: URL(string:
                "http://127.0.0.1:11434/api/chat")!))
            XCTAssertFalse(policy.allowsRedirect(to: URL(string:
                "https://ollama.com/api/chat")!))
            XCTAssertFalse(policy.allowsRedirect(to: URL(string:
                "http://127.0.0.1:11434/api/pull")!))
        }
    }

**Step 2: Run the tests**

    swift test --package-path apps/mac --filter OllamaTransportTests

Expected: FAIL because the policy and transport do not exist.

**Step 3: Implement the pure policy**

OllamaTransport.swift begins with:

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
            url.scheme == "http"
                && url.host == "127.0.0.1"
                && url.port == 11434
                && Self.allowedPaths.contains(url.path)
                && url.user == nil
                && url.password == nil
                && url.query == nil
                && url.fragment == nil
        }

        func allowsRedirect(to url: URL) -> Bool {
            allows(url)
        }
    }

**Step 4: Implement the production session and redirect delegate**

Add:

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
    }

    enum OllamaSessionFactory {
        static func make() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
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

Define an injectable loader and transport:

    protocol OllamaDataLoading: Sendable {
        func data(for request: URLRequest) async throws -> (Data, URLResponse)
    }

    extension URLSession: OllamaDataLoading {}

    struct OllamaTransport: Sendable {
        let loader: any OllamaDataLoading
        private let policy = OllamaOriginPolicy()

        init(loader: any OllamaDataLoading = OllamaSessionFactory.make()) {
            self.loader = loader
        }

        func request(
            path: String,
            method: String = "GET",
            body: Data? = nil
        ) async throws -> Data {
            guard let url = URL(
                string: path,
                relativeTo: OllamaOriginPolicy.baseURL
            )?.absoluteURL,
            policy.allows(url)
            else { throw LocalAIError.unsafeLocalEndpoint }

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

Define OllamaHTTPError as an internal Sendable error that is not LocalizedError.
It contains only statusCode and hasAPIMessage, never the API message, request
data, or raw response body. OllamaClient maps it to LocalAIError before UI
presentation.

If URLSession does not satisfy OllamaDataLoading due to the delegate parameter
on the SDK's async overload, add a tiny URLSessionLoader wrapper instead of
weakening the abstraction.

**Step 5: Add request-capture coverage**

Add an actor LoaderSpy that records URLRequest and returns a synthetic
HTTPURLResponse. Assert:

- POST bodies receive application/json.
- /api/pull throws before loader invocation.
- the body does not appear in any error description.
- cancellation from the loader propagates as CancellationError.

**Step 6: Run tests**

    swift test --package-path apps/mac --filter OllamaTransportTests
    swift test --package-path apps/mac

Expected: PASS.

**Step 7: Commit**

    git add apps/mac/Sources/DevPort/AI/OllamaTransport.swift \
      apps/mac/Tests/DevPortTests/OllamaTransportTests.swift
    git commit -m "feat: restrict Ollama transport to loopback"

## Task 6: Implement Ollama discovery, chat, and unload lifecycle

**Files:**

- Create: apps/mac/Sources/DevPort/AI/OllamaClient.swift
- Create: apps/mac/Sources/DevPort/AI/OllamaProvider.swift
- Create: apps/mac/Tests/DevPortTests/OllamaClientTests.swift
- Create: apps/mac/Tests/DevPortTests/OllamaConversationTests.swift

**Step 1: Write failing client tests**

Create a QueueTransport actor conforming to a small OllamaTransporting protocol.
It returns queued JSON and records path, method, and body.

Test these exact behaviors:

    func testListModelsReturnsOnlyProvenLocalEntries() async throws
    func testValidateModelUsesShowAndRejectsRemoteMetadata() async throws
    func testChatEncodesNoToolsAndUsesTwoMinuteKeepAlive() async throws
    func testUnloadUsesEmptyMessagesAndZeroKeepAlive() async throws
    func testConnectionRefusedMapsToNotRunning() async
    func testMalformedJSONMapsToBoundedError() async

For the chat body, decode the captured JSON into a dictionary and assert:

    XCTAssertNil(body["tools"])
    XCTAssertEqual(body["stream"] as? Bool, false)
    XCTAssertEqual(body["keep_alive"] as? String, "2m")

For unload:

    XCTAssertEqual(body["messages"] as? [[String: String]], [])
    XCTAssertEqual(body["keep_alive"] as? Int, 0)

**Step 2: Run the client tests**

    swift test --package-path apps/mac --filter OllamaClientTests

Expected: FAIL because OllamaClient does not exist.

**Step 3: Implement the client**

Define OllamaTransporting in OllamaTransport.swift:

    protocol OllamaTransporting: Sendable {
        func request(
            path: String,
            method: String,
            body: Data?
        ) async throws -> Data
    }

Make OllamaTransport conform and implement OllamaClient:

    protocol OllamaClientProtocol: Sendable {
        func localModels() async throws -> [OllamaModel]
        func validateLocalModel(_ id: String) async throws
        func chat(
            model: String,
            messages: [OllamaChatMessage]
        ) async throws -> String
        func unload(model: String) async
    }

    struct OllamaClient: OllamaClientProtocol, Sendable {
        let transport: any OllamaTransporting

        init(transport: any OllamaTransporting = OllamaTransport()) {
            self.transport = transport
        }

        func localModels() async throws -> [OllamaModel] {
            let data = try await transport.request(
                path: "/api/tags",
                method: "GET",
                body: nil
            )
            return try decode(OllamaTagsResponse.self, from: data)
                .validatedLocalModels
        }

        func validateLocalModel(_ id: String) async throws {
            guard try await localModels().contains(where: { $0.id == id })
            else { throw LocalAIError.ollamaModelUnavailable }

            let body = try JSONEncoder().encode(["model": id])
            let data = try await transport.request(
                path: "/api/show",
                method: "POST",
                body: body
            )
            guard try decode(OllamaShowResponse.self, from: data)
                .confirmsLocalExecution
            else { throw LocalAIError.remoteModelRejected }
        }

        func chat(
            model: String,
            messages: [OllamaChatMessage]
        ) async throws -> String {
            let request = OllamaChatRequest(
                model: model,
                messages: messages,
                stream: false,
                keepAlive: .duration("2m")
            )
            let data = try await transport.request(
                path: "/api/chat",
                method: "POST",
                body: try JSONEncoder().encode(request)
            )
            return try decode(OllamaChatResponse.self, from: data)
                .message.content
        }

        func unload(model: String) async {
            let request = OllamaChatRequest(
                model: model,
                messages: [],
                stream: false,
                keepAlive: .seconds(0)
            )
            _ = try? await transport.request(
                path: "/api/chat",
                method: "POST",
                body: try? JSONEncoder().encode(request)
            )
        }

        private func decode<T: Decodable>(
            _ type: T.Type,
            from data: Data
        ) throws -> T {
            do { return try JSONDecoder().decode(type, from: data) }
            catch { throw LocalAIError.malformedResponse }
        }
    }

Map URLError.notConnectedToInternet, cannotConnectToHost, and networkConnectionLost
to ollamaNotRunning; map timedOut to timedOut; preserve CancellationError. Do
not include Data or prompt strings in mapped errors.

**Step 4: Write failing conversation tests**

Use an OllamaClientProtocol spy and verify:

- conversation starts with one system message containing only the sanitized
  context.
- a successful response commits user and assistant messages to history.
- a failed response does not commit a partial assistant response.
- close cancels future use and invokes unload exactly once.
- calling close before the first response does not unload a model Port Radar
  never loaded.

**Step 5: Implement OllamaProvider and OllamaConversation**

OllamaProvider:

    struct OllamaProvider: LocalAIProvider {
        let id: LocalAIProviderID = .ollama
        let client: any OllamaClientProtocol

        init(client: any OllamaClientProtocol = OllamaClient()) {
            self.client = client
        }

        func availability(modelID: String?) async -> LocalAIAvailability {
            guard let modelID, !modelID.isEmpty else {
                return .unavailable(.ollamaModelRequired)
            }
            do {
                try await client.validateLocalModel(modelID)
                return .available
            } catch let error as LocalAIError {
                return .unavailable(error)
            } catch {
                return .unavailable(.ollamaNotRunning)
            }
        }

        func makeConversation(
            context: SanitizedProcessContext,
            modelID: String?
        ) async throws -> any LocalAIConversation {
            guard let modelID, !modelID.isEmpty else {
                throw LocalAIError.ollamaModelRequired
            }
            try await client.validateLocalModel(modelID)
            return OllamaConversation(
                client: client,
                modelID: modelID,
                context: context
            )
        }
    }

OllamaConversation is an actor. It stores the system message and committed
history, records that a request may have loaded the model before awaiting the
network call, rejects responses after close, and makes close idempotent:

    actor OllamaConversation: LocalAIConversation {
        nonisolated let providerID: LocalAIProviderID = .ollama
        private let client: any OllamaClientProtocol
        private let modelID: String
        private var messages: [OllamaChatMessage]
        private var didStartRequest = false
        private var isClosed = false

        init(
            client: any OllamaClientProtocol,
            modelID: String,
            context: SanitizedProcessContext
        ) {
            self.client = client
            self.modelID = modelID
            self.messages = [.init(
                role: "system",
                content: LocalAIPrompt.instructions(context: context)
            )]
        }

        func respond(to prompt: String) async throws -> String {
            guard !isClosed else { throw CancellationError() }
            let candidate = messages + [.init(role: "user", content: prompt)]
            didStartRequest = true
            let response = try await client.chat(
                model: modelID,
                messages: candidate
            )
            guard !isClosed else { throw CancellationError() }
            messages = candidate + [.init(role: "assistant", content: response)]
            return response
        }

        func close() async {
            guard !isClosed else { return }
            isClosed = true
            if didStartRequest {
                await client.unload(model: modelID)
            }
        }
    }

LocalAIPrompt is a provider-neutral enum in LocalAIProvider.swift. Its
instructions method contains the existing concise Port Radar instructions plus
context.text. Both providers call this exact method.

**Step 6: Run focused and full suites**

    swift test --package-path apps/mac --filter OllamaClientTests
    swift test --package-path apps/mac --filter OllamaConversationTests
    swift test --package-path apps/mac

Expected: PASS. No test contacts port 11434.

**Step 7: Commit**

    git add apps/mac/Sources/DevPort/AI \
      apps/mac/Tests/DevPortTests/OllamaClientTests.swift \
      apps/mac/Tests/DevPortTests/OllamaConversationTests.swift
    git commit -m "feat: add local Ollama conversations"

## Task 7: Replace ProcessAgent with a conditional Apple provider

**Files:**

- Create: apps/mac/Sources/DevPort/AI/AppleFoundationModelProvider.swift
- Create: apps/mac/Tests/DevPortTests/AppleProviderFallbackTests.swift
- Modify: apps/mac/Sources/DevPort/AI/AIProviderResolver.swift
- Delete: apps/mac/Sources/DevPort/Actions/ProcessAgent.swift

**Step 1: Write the missing-SDK regression test**

AppleProviderFallbackTests.swift:

    import XCTest
    @testable import DevPort

    final class AppleProviderFallbackTests: XCTestCase {
        #if !canImport(FoundationModels)
        func testAppleProviderIsUnavailableWithoutFramework() async {
            let provider = AppleFoundationModelProvider()
            let availability = await provider.availability(modelID: nil)
            guard case .unavailable = availability else {
                return XCTFail("Expected unavailable without FoundationModels")
            }
        }
        #endif
    }

**Step 2: Run the test**

    swift test --package-path apps/mac --filter AppleProviderFallbackTests

Expected: FAIL because AppleFoundationModelProvider does not exist.

**Step 3: Implement the always-present provider facade**

AppleFoundationModelProvider.swift:

    import Foundation

    #if canImport(FoundationModels)
    import FoundationModels
    #endif

    struct AppleFoundationModelProvider: LocalAIProvider {
        let id: LocalAIProviderID = .apple

        func availability(modelID: String?) async -> LocalAIAvailability {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return AppleFoundationModelAvailability.current
            }
            #endif
            return .unavailable(.appleUnavailable(
                "Apple Intelligence requires macOS 26 or later."
            ))
        }

        func makeConversation(
            context: SanitizedProcessContext,
            modelID: String?
        ) async throws -> any LocalAIConversation {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                guard case .available =
                    AppleFoundationModelAvailability.current
                else {
                    throw LocalAIError.appleUnavailable(
                        "Apple Intelligence is unavailable."
                    )
                }
                return AppleFoundationModelConversation(context: context)
            }
            #endif
            throw LocalAIError.appleUnavailable(
                "Apple Intelligence requires macOS 26 or later."
            )
        }
    }

Inside the framework guard, map every current SystemLanguageModel.default
availability reason to the existing user-facing strings. Construct the session
explicitly with the on-device model:

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private actor AppleFoundationModelConversation: LocalAIConversation {
        nonisolated let providerID: LocalAIProviderID = .apple
        private var session: LanguageModelSession?

        init(context: SanitizedProcessContext) {
            session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: LocalAIPrompt.instructions(context: context)
            )
        }

        func respond(to prompt: String) async throws -> String {
            guard let session else { throw CancellationError() }
            return try await session.respond(to: prompt).content
        }

        func close() async {
            session = nil
        }
    }
    #endif

If the installed macOS 26 SDK exposes a different labeled initializer, adapt
only the initializer while keeping SystemLanguageModel.default explicit. Do not
use PrivateCloudComputeLanguageModel or a generic remote model.

Add the production composition in AIProviderResolver.swift:

    extension AIProviderResolver {
        static var live: Self {
            Self(
                apple: AppleFoundationModelProvider(),
                ollama: OllamaProvider()
            )
        }
    }

**Step 4: Remove ProcessAgent**

Move the DevServer rawAgentContext extension into
ProcessContextSanitizer.swift, then delete Actions/ProcessAgent.swift. Confirm
there are no references:

    rg -n "ProcessAgent|LanguageModelSession|SystemLanguageModel" \
      apps/mac/Sources/DevPort

Expected: only AppleFoundationModelProvider.swift contains FoundationModels
session/model references.

**Step 5: Run current-SDK tests and future-SDK compile**

    swift test --package-path apps/mac

Expected on the current SDK: PASS through the no-framework branch.

On a machine or CI runner with the macOS 26 SDK, also run:

    swift test --package-path apps/mac
    swift build --package-path apps/mac

Expected: PASS and AppleFoundationModelProvider compiles with the explicit
on-device SystemLanguageModel.

**Step 6: Commit**

    git add -A apps/mac/Sources/DevPort/Actions/ProcessAgent.swift \
      apps/mac/Sources/DevPort/AI/AppleFoundationModelProvider.swift \
      apps/mac/Sources/DevPort/AI/AIProviderResolver.swift \
      apps/mac/Sources/DevPort/AI/ProcessContextSanitizer.swift \
      apps/mac/Tests/DevPortTests/AppleProviderFallbackTests.swift
    git commit -m "feat: isolate Apple on-device provider"

## Task 8: Persist provider choice and present Ollama setup state

**Files:**

- Modify: apps/mac/Sources/DevPort/State/Preferences.swift
- Create: apps/mac/Sources/DevPort/AI/OllamaSettingsModel.swift
- Create: apps/mac/Sources/DevPort/Actions/OllamaApplication.swift
- Create: apps/mac/Tests/DevPortTests/LocalAIPreferencesTests.swift
- Create: apps/mac/Tests/DevPortTests/OllamaSettingsModelTests.swift

**Step 1: Write failing preference migration tests**

Use a disposable UserDefaults suite:

    @MainActor
    final class LocalAIPreferencesTests: XCTestCase {
        func testMissingAndUnknownPreferenceBecomeAutomatic() {
            XCTAssertEqual(
                LocalAIProviderPreference.persistedValue(nil),
                .automatic
            )
            XCTAssertEqual(
                LocalAIProviderPreference.persistedValue("future-provider"),
                .automatic
            )
        }
    }

Add tests that a selected Ollama model identifier round-trips and an empty value
remains empty. Do not store model metadata, prompts, or history.

**Step 2: Extend Preferences**

Add keys:

    static let localAIProvider = "localAIProvider"
    static let ollamaModel = "ollamaModel"

Add persisted properties:

    var localAIProviderPreference: LocalAIProviderPreference {
        didSet {
            UserDefaults.standard.set(
                localAIProviderPreference.rawValue,
                forKey: Key.localAIProvider
            )
        }
    }

    var ollamaModelID: String {
        didSet {
            UserDefaults.standard.set(ollamaModelID, forKey: Key.ollamaModel)
        }
    }

Initialize with persistedValue and an empty model default. Update the Ask
property comment so it says local AI rather than Apple Intelligence.

If direct UserDefaults.standard usage blocks round-trip tests, inject a
UserDefaults instance into an internal initializer and store it as a private
property. Keep Preferences.shared using .standard.

**Step 3: Write failing settings-state tests**

OllamaSettingsModelTests covers:

- running service with two local models.
- stopped service.
- no validated local models.
- a previously selected model disappearing clears the selection.
- refresh cancellation cannot overwrite a newer state.

**Step 4: Implement OllamaSettingsModel**

Use @MainActor and @Observable:

    @MainActor
    @Observable
    final class OllamaSettingsModel {
        enum State: Equatable {
            case idle
            case loading
            case ready([OllamaModel])
            case notRunning
            case failed(String)
        }

        private let client: any OllamaClientProtocol
        private(set) var state: State = .idle
        private var refreshTask: Task<Void, Never>?

        init(client: any OllamaClientProtocol = OllamaClient()) {
            self.client = client
        }

        func refresh(selectedModelID: String) {
            refreshTask?.cancel()
            refreshTask = Task {
                state = .loading
                do {
                    let models = try await client.localModels()
                    guard !Task.isCancelled else { return }
                    state = .ready(models)
                    if !selectedModelID.isEmpty,
                       !models.contains(where: { $0.id == selectedModelID }) {
                        Preferences.shared.ollamaModelID = ""
                    }
                } catch is CancellationError {
                    return
                } catch {
                    state = .notRunning
                }
            }
        }
    }

Separate no-model from stopped-service in computed status text so the UI does
not tell a running user to reopen Ollama.

**Step 5: Implement explicit Open Ollama action**

OllamaApplication.swift:

    import AppKit

    enum OllamaApplication {
        static func open() async throws {
            guard let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.electron.ollama"
            ) else {
                throw LocalAIError.ollamaNotRunning
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try await NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            )
        }
    }

This action runs only after a user presses Open Ollama. It does not use the
ollama CLI, start ollama serve, change login items, or terminate an existing
process.

**Step 6: Run tests and commit**

    swift test --package-path apps/mac --filter LocalAIPreferencesTests
    swift test --package-path apps/mac --filter OllamaSettingsModelTests
    swift test --package-path apps/mac

Expected: PASS.

    git add apps/mac/Sources/DevPort/State/Preferences.swift \
      apps/mac/Sources/DevPort/AI/OllamaSettingsModel.swift \
      apps/mac/Sources/DevPort/Actions/OllamaApplication.swift \
      apps/mac/Tests/DevPortTests/LocalAIPreferencesTests.swift \
      apps/mac/Tests/DevPortTests/OllamaSettingsModelTests.swift
    git commit -m "feat: add local AI preferences"

## Task 9: Make chat lifecycle testable and provider-neutral

**Files:**

- Create: apps/mac/Sources/DevPort/AI/AgentChatModel.swift
- Create: apps/mac/Tests/DevPortTests/AgentChatModelTests.swift
- Modify: apps/mac/Sources/DevPort/Views/AgentChatView.swift
- Modify: apps/mac/Sources/DevPort/Views/ContentView.swift:136

**Step 1: Write failing chat-model tests**

Use resolver and conversation spies to test:

- bootstrap sanitizes context once and resolves using saved preference/model.
- initial system message and badge match Apple or Ollama.
- send trims input, appends user and assistant, and prevents concurrent send.
- cancellation adds no error bubble.
- close cancels active generation and calls conversation.close exactly once.
- a response completing after close is ignored.

The core close test:

    @MainActor
    func testCloseCancelsGenerationAndClosesConversation() async {
        let conversation = BlockingConversationSpy(providerID: .ollama)
        let model = AgentChatModel(
            server: TestFixtures.devServer(command: "node app.js"),
            resolver: ResolverStub(conversation: conversation),
            preference: .ollama,
            ollamaModelID: "qwen3:4b"
        )

        await model.bootstrap()
        model.draft = "What is this?"
        model.send()
        await model.close()

        let wasClosed = await conversation.wasClosed()
        XCTAssertTrue(wasClosed)
        XCTAssertFalse(model.messages.contains {
            $0.role == .system && $0.text.contains("cancel")
        })
    }

**Step 2: Run the tests**

    swift test --package-path apps/mac --filter AgentChatModelTests

Expected: FAIL because AgentChatModel does not exist.

**Step 3: Implement AgentChatModel**

AgentChatModel is @MainActor and @Observable. It owns:

- immutable server, resolver, preference, and selected Ollama model.
- draft, messages, isSending, availabilityNote, and badgeText.
- the resolved conversation and one generation Task.
- isClosed and close-once state.

Bootstrap:

    func bootstrap() async {
        guard conversation == nil, !isClosed else { return }
        do {
            let context = server.sanitizedAgentContext
            let resolved = try await resolver.resolve(
                preference: preference,
                ollamaModelID: ollamaModelID.isEmpty ? nil : ollamaModelID,
                context: context
            )
            guard !isClosed else {
                await resolved.conversation.close()
                return
            }
            conversation = resolved.conversation
            badgeText = resolved.badgeText
            messages = [.init(
                role: .system,
                text: resolved.providerID == .apple
                    ? "Apple's on-device model has sanitized process context."
                    : "Your local Ollama model has sanitized process context."
            )]
        } catch {
            availabilityNote = error.localizedDescription
        }
    }

Send creates one Task, maps CancellationError to no message, maps other errors
to bounded LocalAIError text, and checks isClosed before appending.

Close:

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        generationTask?.cancel()
        generationTask = nil
        let active = conversation
        conversation = nil
        await active?.close()
        messages.removeAll()
    }

**Step 4: Refactor AgentChatView**

Remove every FoundationModels import and macOS 26 availability annotation.
Remove AgentUnavailableModal because provider failures now appear inside the
same modal.

Initialize the state model with:

    @State private var model: AgentChatModel

    init(server: DevServer, onDismiss: @escaping () -> Void) {
        self.server = server
        self.onDismiss = onDismiss
        _model = State(initialValue: AgentChatModel(
            server: server,
            resolver: .live,
            preference: Preferences.shared.localAIProviderPreference,
            ollamaModelID: Preferences.shared.ollamaModelID
        ))
    }

Bind existing controls to model state. Add a badge in the header only when
badgeText is non-nil:

    if let badge = model.badgeText {
        Text(badge)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.14), in: Capsule())
            .foregroundStyle(.green)
    }

Use:

    .task { await model.bootstrap() }
    .onDisappear { Task { await model.close() } }

The Close button should await close before invoking onDismiss, or invoke
onDismiss and rely on the idempotent onDisappear cleanup. Prefer one private
close action so both paths share behavior.

**Step 5: Simplify ContentView**

Replace the conditional framework/runtime block with:

    } else if let agentServer {
        AgentChatModal(
            server: agentServer,
            onDismiss: { self.agentServer = nil }
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98)))

macOS 14 users can now reach Ollama through the same modal.

**Step 6: Run tests and build**

    swift test --package-path apps/mac --filter AgentChatModelTests
    swift test --package-path apps/mac
    swift build --package-path apps/mac

Expected: PASS.

**Step 7: Commit**

    git add apps/mac/Sources/DevPort/AI/AgentChatModel.swift \
      apps/mac/Sources/DevPort/Views/AgentChatView.swift \
      apps/mac/Sources/DevPort/Views/ContentView.swift \
      apps/mac/Tests/DevPortTests/AgentChatModelTests.swift
    git commit -m "feat: make process chat provider neutral"

## Task 10: Add provider and model controls to Settings

**Files:**

- Modify: apps/mac/Sources/DevPort/Views/SettingsView.swift
- Modify: apps/mac/Sources/DevPort/AI/OllamaSettingsModel.swift
- Create: apps/mac/Tests/DevPortTests/LocalAIStatusTextTests.swift

**Step 1: Write failing status-text tests**

Test pure computed copy for:

- idle/loading.
- ready with local model count.
- ready with empty local model list.
- stopped service.
- remote-only response producing empty local list.

Example:

    func testReadyStatusCountsOnlyLocalModels() {
        let state = OllamaSettingsModel.State.ready([
            .init(id: "qwen3:4b", size: 1, format: "gguf")
        ])
        XCTAssertEqual(state.statusText, "Ollama is running · 1 local model")
    }

**Step 2: Run the focused test**

    swift test --package-path apps/mac --filter LocalAIStatusTextTests

Expected: FAIL because statusText is missing.

**Step 3: Add Settings controls**

Inside the Ask settings group, after the toggle and only when Ask is enabled,
add:

    settingsRow("AI provider") {
        Picker(
            "",
            selection: $preferences.localAIProviderPreference
        ) {
            ForEach(LocalAIProviderPreference.allCases) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

When the preference is Automatic or Ollama, add an Ollama model row:

    settingsRow("Ollama model") {
        switch ollamaSettings.state {
        case .ready(let models) where !models.isEmpty:
            Picker("", selection: $preferences.ollamaModelID) {
                Text("Choose…").tag("")
                ForEach(models) { model in
                    Text(model.id).tag(model.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        default:
            Text("None")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

Add the local-only status text below the rows. When stopped, show Open Ollama.
When Ollama cannot be located, show a user-clicked link to
https://ollama.com/download/mac rather than downloading anything.

SettingsModal owns:

    @State private var ollamaSettings = OllamaSettingsModel()

Refresh on appear only when Ollama controls are visible. Refresh again after
Open Ollama with a short bounded retry sequence, cancelling retries when the
modal disappears.

Increase the modal width/height only as much as needed and keep all controls
readable without clipping on macOS 14.

**Step 4: Add privacy copy**

Under provider controls, add:

    Text("Chat stays on this Mac. Cloud and remote Ollama models are excluded.")

Do not claim the entire app has no network activity because Cloudflare sharing
is a separate user-triggered feature.

**Step 5: Run tests and manual visual check**

    swift test --package-path apps/mac --filter LocalAIStatusTextTests
    swift test --package-path apps/mac
    make build

Expected: PASS.

Run the app and inspect:

    make run

Verify Automatic, Apple Intelligence, and Ollama labels; stopped/no-model
states; no clipped controls; and both provider badges. Do not pull a model as
part of this check.

**Step 6: Commit**

    git add apps/mac/Sources/DevPort/Views/SettingsView.swift \
      apps/mac/Sources/DevPort/AI/OllamaSettingsModel.swift \
      apps/mac/Tests/DevPortTests/LocalAIStatusTextTests.swift
    git commit -m "feat: add local AI settings"

## Task 11: Add best-effort cleanup on application termination

**Files:**

- Create: apps/mac/Sources/DevPort/AI/LocalAIConversationRegistry.swift
- Create: apps/mac/Tests/DevPortTests/LocalAIConversationRegistryTests.swift
- Modify: apps/mac/Sources/DevPort/AI/AgentChatModel.swift
- Modify: apps/mac/Sources/DevPort/DevPortApp.swift

**Step 1: Write failing registry tests**

Test:

- register then closeActive closes exactly once.
- registering a second conversation closes the first before replacing it.
- unregister only removes the matching conversation token.
- closeActive with no conversation is harmless.

Use UUID tokens so a late disappearing old modal cannot unregister the current
chat.

**Step 2: Run the tests**

    swift test --package-path apps/mac \
      --filter LocalAIConversationRegistryTests

Expected: FAIL because the registry does not exist.

**Step 3: Implement the registry**

    actor LocalAIConversationRegistry {
        static let shared = LocalAIConversationRegistry()

        private var active:
            (token: UUID, conversation: any LocalAIConversation)?

        func register(
            token: UUID,
            conversation: any LocalAIConversation
        ) async {
            if let previous = active {
                await previous.conversation.close()
            }
            active = (token, conversation)
        }

        func unregister(token: UUID) {
            guard active?.token == token else { return }
            active = nil
        }

        func closeActive() async {
            let current = active
            active = nil
            await current?.conversation.close()
        }
    }

AgentChatModel registers after resolution and unregisters after its own close.

**Step 4: Add application termination hook**

In DevPortApp.swift:

    final class AppDelegate: NSObject, NSApplicationDelegate {
        func applicationWillTerminate(_ notification: Notification) {
            Task {
                await LocalAIConversationRegistry.shared.closeActive()
            }
        }
    }

    @main
    struct DevPortApp: App {
        @NSApplicationDelegateAdaptor(AppDelegate.self)
        private var appDelegate

        // Existing initialization and scene stay unchanged.
    }

This is explicitly best-effort: normal modal close is the reliable cleanup path,
while termination may end before the async loopback request completes. Do not
block application termination and do not stop the Ollama service.

**Step 5: Run tests and commit**

    swift test --package-path apps/mac \
      --filter LocalAIConversationRegistryTests
    swift test --package-path apps/mac
    swift build --package-path apps/mac

Expected: PASS.

    git add apps/mac/Sources/DevPort/AI/LocalAIConversationRegistry.swift \
      apps/mac/Sources/DevPort/AI/AgentChatModel.swift \
      apps/mac/Sources/DevPort/DevPortApp.swift \
      apps/mac/Tests/DevPortTests/LocalAIConversationRegistryTests.swift
    git commit -m "feat: unload local model on chat close"

## Task 12: Document privacy boundaries and verify the complete branch

**Files:**

- Modify: README.md:13
- Modify: README.md:18
- Modify: README.md:23
- Modify: README.md:42
- Modify: apps/mac/README.md
- Create: docs/testing/local-ai-manual-matrix.md
- Modify: modified source files that require Apache 2.0 modification notices

**Step 1: Update README feature and requirements copy**

Replace Apple-only wording with:

    - Ask — uses Apple's on-device model when available, with an optional local
      Ollama fallback for unsupported or user-selected configurations.

Document:

- Automatic provider order.
- Apple SystemLanguageModel is on-device and requires supported macOS/hardware.
- Ollama is optional and never installed, started, or given a model silently.
- only already installed, metadata-verified local models appear.
- Ollama remote/cloud models are excluded even when accessed through localhost.
- prompts and answers stay in memory and process context is sanitized.
- the model loads on first prompt and is asked to unload on chat close.
- disable_ollama_cloud in Ollama is recommended as defense in depth.
- the chat privacy claim is separate from the explicit Cloudflare Share action.

Link only to official Apple and Ollama documentation already listed in the
approved design.

**Step 2: Add the manual test matrix**

Create docs/testing/local-ai-manual-matrix.md with checkboxes for:

- Apple available on macOS 26+.
- Apple unavailable plus local Ollama.
- forced Ollama on an Apple-capable Mac.
- service stopped and application-not-installed states.
- no local models and remote-only models.
- selection removed between Settings and chat.
- chat close and app quit during generation.
- synthetic command secrets absent from requests.
- proxy/network inspection shows chat requests only to 127.0.0.1:11434.
- Cloudflare sharing still functions and remains clearly separate.

Record date, machine, macOS, Xcode, Ollama version, selected local model, and
PASS/FAIL for every manual run. Never record prompts containing real secrets.

**Step 3: Apply license-change notices**

Read LICENSE section 4(b) and the repository README license instructions again.
Add a concise prominent notice to every existing source/documentation file
changed by this contribution, following the maintainer's existing style if one
appears before implementation. Do not alter LICENSE or remove Juan Sebastian
Solano's NOTICE attribution.

Before committing, inspect:

    git diff origin/main --name-status
    git diff origin/main -- LICENSE NOTICE

Expected: all modifications are in the local AI scope; LICENSE and NOTICE have
no removals or ownership changes.

**Step 4: Run the complete automated verification**

    swift test --package-path apps/mac
    swift build --package-path apps/mac
    make build
    git diff --check origin/main
    rg -n "https?://" apps/mac/Sources/DevPort/AI
    rg -n "/api/(pull|create|delete|push)|web_search|web_fetch" \
      apps/mac/Sources/DevPort/AI
    rg -n "print\\(|debugPrint\\(|NSLog\\(|os_log" \
      apps/mac/Sources/DevPort/AI

Expected:

- all tests PASS with zero failures.
- both builds exit zero.
- diff check prints nothing.
- the URL search finds only the fixed 127.0.0.1 base and intentional
  documentation/error text; no ollama.com runtime endpoint.
- forbidden endpoint search prints nothing.
- logging search prints nothing.

On macOS 26 SDK CI, also confirm the FoundationModels branch compiles. The
current macOS 15 SDK can verify only the fallback branch.

**Step 5: Perform the manual matrix**

Run every environment available locally and record evidence. Mark unavailable
hardware/SDK combinations as NOT RUN, never PASS. Capture Settings and chat
screenshots for the pull request only after verifying they contain no usernames,
paths, project names, commands, prompts, tokens, or other private data.

**Step 6: Review the final diff**

    git status --short
    git diff --stat origin/main
    git diff origin/main -- apps/mac README.md docs/testing
    git log --oneline --decorate origin/main..HEAD

Confirm:

- no rebrand.
- no Product Hunt material.
- no Cloudflare implementation change.
- no automatic download/start/stop.
- no remote endpoint setting.
- no prompt/history persistence.
- no unrelated generated files.

**Step 7: Commit documentation**

    git add README.md apps/mac/README.md \
      docs/testing/local-ai-manual-matrix.md \
      apps/mac/Sources/DevPort
    git commit -m "docs: explain local AI privacy"

**Step 8: Request code review**

Use @superpowers:requesting-code-review. Resolve any feedback through
@superpowers:receiving-code-review, rerun the complete verification, and only
then use @superpowers:finishing-a-development-branch to choose push/fork/PR
actions.

Do not create the public fork, push commits, or open the upstream pull request
until the user explicitly approves that external publication step.

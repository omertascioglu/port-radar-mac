import Foundation
import XCTest
@testable import DevPort

final class OllamaModelValidationTests: XCTestCase {
    func testDecodesProvenLocalModel() throws {
        let data = Data(
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

        let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)

        XCTAssertEqual(
            response.validatedLocalModels,
            [OllamaModel(id: "qwen3:4b", size: 2_500_000_000, format: "gguf")]
        )
    }

    func testRejectsNonemptyRemoteHost() throws {
        let response = try decodeTags(
            modelJSON: localModelJSON(
                extraFields: "\"remote_host\":\"https://ollama.com:443\","
            )
        )

        XCTAssertTrue(response.validatedLocalModels.isEmpty)
    }

    func testRejectsNonemptyRemoteModel() throws {
        let response = try decodeTags(
            modelJSON: localModelJSON(
                extraFields: "\"remote_model\":\"remote-qwen\","
            )
        )

        XCTAssertTrue(response.validatedLocalModels.isEmpty)
    }

    func testEmptyRemoteMetadataStillAllowsProvenLocalModel() throws {
        let response = try decodeTags(
            modelJSON: localModelJSON(
                extraFields: "\"remote_model\":\"\",\"remote_host\":\"\","
            )
        )

        XCTAssertEqual(response.validatedLocalModels.map(\.id), ["qwen3:4b"])
    }

    func testRejectsCloudSuffixOnEitherNameOrModel() throws {
        let identifiers = [
            (name: "qwen3:cloud", model: "qwen3:4b"),
            (name: "qwen3:4b", model: "qwen3:CLOUD"),
            (name: "qwen3:4b-cloud", model: "qwen3:4b"),
            (name: "qwen3:4b", model: "qwen3:4b-CLOUD"),
        ]

        for identifiers in identifiers {
            let response = try decodeTags(
                modelJSON: localModelJSON(
                    name: identifiers.name,
                    model: identifiers.model
                )
            )

            XCTAssertTrue(
                response.validatedLocalModels.isEmpty,
                "Expected \(identifiers) to be rejected"
            )
        }
    }

    func testRejectsEveryKindOfIncompleteLocalEvidence() throws {
        let entries = [
            OllamaModelSummary(
                name: "qwen3:4b",
                model: "qwen3:4b",
                remoteModel: nil,
                remoteHost: nil,
                size: nil,
                digest: "sha256-local",
                details: .init(format: "gguf")
            ),
            OllamaModelSummary(
                name: "qwen3:4b",
                model: "qwen3:4b",
                remoteModel: nil,
                remoteHost: nil,
                size: 0,
                digest: "sha256-local",
                details: .init(format: "gguf")
            ),
            OllamaModelSummary(
                name: "qwen3:4b",
                model: "qwen3:4b",
                remoteModel: nil,
                remoteHost: nil,
                size: -1,
                digest: "sha256-local",
                details: .init(format: "gguf")
            ),
            OllamaModelSummary(
                name: "qwen3:4b",
                model: "qwen3:4b",
                remoteModel: nil,
                remoteHost: nil,
                size: 42,
                digest: nil,
                details: .init(format: "gguf")
            ),
            OllamaModelSummary(
                name: "qwen3:4b",
                model: "qwen3:4b",
                remoteModel: nil,
                remoteHost: nil,
                size: 42,
                digest: "",
                details: .init(format: "gguf")
            ),
            OllamaModelSummary(
                name: "qwen3:4b",
                model: "qwen3:4b",
                remoteModel: nil,
                remoteHost: nil,
                size: 42,
                digest: "sha256-local",
                details: nil
            ),
            OllamaModelSummary(
                name: "qwen3:4b",
                model: "qwen3:4b",
                remoteModel: nil,
                remoteHost: nil,
                size: 42,
                digest: "sha256-local",
                details: .init(format: nil)
            ),
            OllamaModelSummary(
                name: "qwen3:4b",
                model: "qwen3:4b",
                remoteModel: nil,
                remoteHost: nil,
                size: 42,
                digest: "sha256-local",
                details: .init(format: "")
            ),
        ]

        for entry in entries {
            XCTAssertFalse(entry.isProvenLocal, "Expected \(entry) to be rejected")
            XCTAssertNil(entry.localModel)
        }
    }

    func testShowResponseRequiresLocalMetadataAndFormat() throws {
        let local = try decodeShow("""
            {"details":{"format":"gguf"}}
            """)
        let remoteHost = try decodeShow("""
            {"remote_host":"https://ollama.com:443","details":{"format":"gguf"}}
            """)
        let remoteModel = try decodeShow("""
            {"remote_model":"qwen-cloud","details":{"format":"gguf"}}
            """)
        let missingDetails = try decodeShow("{}")
        let missingFormat = try decodeShow("{\"details\":{}}")
        let emptyFormat = try decodeShow("{\"details\":{\"format\":\"\"}}")

        XCTAssertTrue(local.confirmsLocalExecution)
        XCTAssertFalse(remoteHost.confirmsLocalExecution)
        XCTAssertFalse(remoteModel.confirmsLocalExecution)
        XCTAssertFalse(missingDetails.confirmsLocalExecution)
        XCTAssertFalse(missingFormat.confirmsLocalExecution)
        XCTAssertFalse(emptyFormat.confirmsLocalExecution)
    }

    func testDecodesVersionChatResponseAndAPIError() throws {
        let version = try JSONDecoder().decode(
            OllamaVersionResponse.self,
            from: Data("{\"version\":\"0.11.8\"}".utf8)
        )
        let chat = try JSONDecoder().decode(
            OllamaChatResponse.self,
            from: Data(
                "{\"message\":{\"role\":\"assistant\",\"content\":\"Local answer\"}}".utf8
            )
        )
        let apiError = try JSONDecoder().decode(
            OllamaAPIErrorResponse.self,
            from: Data("{\"error\":\"synthetic error\"}".utf8)
        )

        XCTAssertEqual(version.version, "0.11.8")
        XCTAssertEqual(chat.message, .init(role: "assistant", content: "Local answer"))
        XCTAssertEqual(apiError.error, "synthetic error")
    }

    func testChatRequestExcludesToolsAndEncodesDurationKeepAlive() throws {
        let request = OllamaChatRequest(
            model: "qwen3:4b",
            messages: [.init(role: "user", content: "What owns port 3000?")],
            stream: false,
            keepAlive: .duration("2m")
        )

        let object = try encodedJSONObject(request)

        XCTAssertEqual(
            Set(object.keys),
            ["model", "messages", "stream", "keep_alive"]
        )
        XCTAssertNil(object["tools"])
        XCTAssertEqual(object["model"] as? String, "qwen3:4b")
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertEqual(object["keep_alive"] as? String, "2m")
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "What owns port 3000?"]])
    }

    func testChatRequestEncodesIntegerKeepAlive() throws {
        let request = OllamaChatRequest(
            model: "qwen3:4b",
            messages: [],
            stream: false,
            keepAlive: .seconds(0)
        )

        let object = try encodedJSONObject(request)

        XCTAssertEqual(
            Set(object.keys),
            ["model", "messages", "stream", "keep_alive"]
        )
        XCTAssertNil(object["tools"])
        XCTAssertEqual(object["keep_alive"] as? Int, 0)
        XCTAssertEqual(object["messages"] as? [AnyHashable], [])
    }

    private func decodeTags(modelJSON: String) throws -> OllamaTagsResponse {
        try JSONDecoder().decode(
            OllamaTagsResponse.self,
            from: Data("{\"models\":[\(modelJSON)]}".utf8)
        )
    }

    private func decodeShow(_ json: String) throws -> OllamaShowResponse {
        try JSONDecoder().decode(OllamaShowResponse.self, from: Data(json.utf8))
    }

    private func localModelJSON(
        name: String = "qwen3:4b",
        model: String = "qwen3:4b",
        extraFields: String = ""
    ) -> String {
        """
        {
          "name":"\(name)",
          "model":"\(model)",
          \(extraFields)
          "size":42,
          "digest":"sha256-local",
          "details":{"format":"gguf"}
        }
        """
    }

    private func encodedJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

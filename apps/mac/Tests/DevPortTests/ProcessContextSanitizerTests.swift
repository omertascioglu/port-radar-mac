import XCTest
@testable import DevPort

final class ProcessContextSanitizerTests: XCTestCase {
    func testDevServerBuildsRawAndSanitizedProviderNeutralContexts() {
        let processID = Int32(ProcessInfo.processInfo.processIdentifier)
        let listener = ListeningPort(port: 3000, pid: processID)
        let details = ProcessDetails(
            pid: processID,
            parentPID: processID,
            executablePath: "/opt/homebrew/bin/node",
            arguments: [
                "node", "app.js", "--token", "synthetic-process-secret",
                "--host", "localhost", "--port", "3000",
            ],
            workingDirectory: "/tmp/SampleProject",
            startTime: nil
        )
        let project = ProjectInfo(
            name: "SampleProject",
            rootPath: "/tmp/SampleProject",
            framework: .vite
        )
        let server = DevServer(
            listener: listener,
            details: details,
            project: project
        )
        let expectedRaw = """
        port: 3000
        url: http://localhost:3000
        pid: \(processID)
        processName: node
        isSystemProcess: false
        isOrphaned: false
        parentPID: \(processID)
        executablePath: /opt/homebrew/bin/node
        workingDirectory: /tmp/SampleProject
        command: node app.js --token synthetic-process-secret --host localhost --port 3000
        projectName: SampleProject
        projectRoot: /tmp/SampleProject
        framework: Vite
        """

        XCTAssertEqual(server.rawAgentContext, expectedRaw)
        XCTAssertEqual(
            server.sanitizedAgentContext.text,
            expectedRaw.replacingOccurrences(
                of: "--token synthetic-process-secret",
                with: "--token=[REDACTED]"
            )
        )
        XCTAssertFalse(
            server.sanitizedAgentContext.text.contains("synthetic-process-secret")
        )
        XCTAssertTrue(server.sanitizedAgentContext.text.contains("--port 3000"))
        XCTAssertTrue(server.sanitizedAgentContext.text.contains("framework: Vite"))
    }

    func testRedactsHighConfidenceGitHubSlackAndOpenAIPrefixes() {
        let credentials = [
            "ghp_1234567890Synthetic",
            "github_pat_1234567890Synthetic",
            "xoxb-1234567890-Synthetic",
            "xoxp-0987654321-Synthetic",
            "sk-1234567890Synthetic",
        ]
        let raw = """
        command: helper \(credentials.joined(separator: " ")) sk-demo
        executablePath: /usr/local/bin/helper
        framework: Node
        """

        let value = ProcessContextSanitizer.sanitize(raw).text

        for credential in credentials {
            XCTAssertFalse(value.contains(credential), "Leaked synthetic credential")
        }
        XCTAssertEqual(value.components(separatedBy: "[REDACTED]").count - 1, 5)
        XCTAssertTrue(value.contains("sk-demo"))
        XCTAssertTrue(value.contains("executablePath: /usr/local/bin/helper"))
        XCTAssertTrue(value.contains("framework: Node"))
    }

    func testRedactsSensitiveURLQueryParameterValues() {
        let raw = """
        url: https://example.test/search?session_token=query-token-value&page=2&client-secret=query-client-value
        callback: https://localhost/callback?Api_Key=query-api-value&project=SampleProject
        """

        let value = ProcessContextSanitizer.sanitize(raw).text

        XCTAssertFalse(value.contains("query-token-value"))
        XCTAssertFalse(value.contains("query-client-value"))
        XCTAssertFalse(value.contains("query-api-value"))
        XCTAssertTrue(value.contains("?session_token=[REDACTED]"))
        XCTAssertTrue(value.contains("&client-secret=[REDACTED]"))
        XCTAssertTrue(value.contains("?Api_Key=[REDACTED]"))
        XCTAssertTrue(value.contains("page=2"))
        XCTAssertTrue(value.contains("project=SampleProject"))
    }

    func testRedactsHTTPURLUserInfoCredentials() {
        let raw = """
        primary: https://alice:synthetic-password@example.test/db
        secondary: http://bob:synthetic-pass@localhost:8080/path
        projectName: SampleProject
        """

        let value = ProcessContextSanitizer.sanitize(raw).text

        XCTAssertFalse(value.contains("alice:synthetic-password"))
        XCTAssertFalse(value.contains("bob:synthetic-pass"))
        XCTAssertTrue(value.contains("https://[REDACTED]@example.test/db"))
        XCTAssertTrue(value.contains("http://[REDACTED]@localhost:8080/path"))
        XCTAssertTrue(value.contains("projectName: SampleProject"))
    }

    func testRedactsBearerCredentialsCaseInsensitively() {
        let credential = "synthetic.credential_123~+/=-value"
        let raw = """
        pid: 42
        Authorization: bEaReR \(credential)
        framework: Vite
        """

        let value = ProcessContextSanitizer.sanitize(raw).text

        XCTAssertFalse(value.contains(credential))
        XCTAssertTrue(value.contains("bEaReR [REDACTED]"))
        XCTAssertTrue(value.contains("pid: 42"))
        XCTAssertTrue(value.contains("framework: Vite"))
    }

    func testRedactsSensitiveCLIOptionsInEqualsAndSeparatedForms() {
        let secrets = [
            "token-value",
            "secret-value",
            "password-value",
            "passwd-value",
            "api-key-value",
            "access-key-value",
            "private-key-value",
            "client-secret-value",
            "authorization-value",
            "cookie-value",
        ]
        let raw = """
        command: node app.js --token token-value --service-secret=secret-value \
        --DB_PASSWORD password-value --legacy-passwd=passwd-value \
        --Api-Key api-key-value --aws-access_key_id=access-key-value \
        --private-key-path private-key-value --oauth-client-secret=client-secret-value \
        --authorization authorization-value --session-cookie=cookie-value \
        --host localhost --port 3000 --project SampleProject --framework Vite
        """

        let value = ProcessContextSanitizer.sanitize(raw).text

        for secret in secrets {
            XCTAssertFalse(value.contains(secret), "Leaked synthetic secret: \(secret)")
        }
        XCTAssertEqual(value.components(separatedBy: "[REDACTED]").count - 1, 10)
        XCTAssertTrue(value.contains("--token=[REDACTED]"))
        XCTAssertTrue(value.contains("--Api-Key=[REDACTED]"))
        XCTAssertTrue(value.contains("--host localhost"))
        XCTAssertTrue(value.contains("--port 3000"))
        XCTAssertTrue(value.contains("--project SampleProject"))
        XCTAssertTrue(value.contains("--framework Vite"))
    }

    func testRedactsSensitiveEnvironmentAssignmentsCaseInsensitively() {
        let secrets = [
            "token-value",
            "secret-value",
            "password-value",
            "passwd-value",
            "api-key-value",
            "access-key-value",
            "private-key-value",
            "client-secret-value",
            "authorization-value",
            "cookie-value",
        ]
        let raw = """
        command: APP_TOKEN=token-value SERVICE_SECRET=secret-value \
        DATABASE_PASSWORD=password-value LEGACY_PASSWD=passwd-value \
        Api-Key=api-key-value AWS_ACCESS_KEY_ID=access-key-value \
        SIGNING_PRIVATE-KEY=private-key-value OAUTH_CLIENT_SECRET=client-secret-value \
        HTTP_AUTHORIZATION=authorization-value SESSION_COOKIE=cookie-value \
        PORT=3000 HOST=localhost PROJECT_NAME=SampleProject
        """

        let value = ProcessContextSanitizer.sanitize(raw).text

        for secret in secrets {
            XCTAssertFalse(value.contains(secret), "Leaked synthetic secret: \(secret)")
        }
        XCTAssertEqual(value.components(separatedBy: "[REDACTED]").count - 1, 10)
        XCTAssertTrue(value.contains("APP_TOKEN=[REDACTED]"))
        XCTAssertTrue(value.contains("Api-Key=[REDACTED]"))
        XCTAssertTrue(value.contains("PORT=3000"))
        XCTAssertTrue(value.contains("HOST=localhost"))
        XCTAssertTrue(value.contains("PROJECT_NAME=SampleProject"))
    }

    func testSanitizationIsNonthrowingDeterministicAndIdempotent() {
        let syntheticSample = "ghp_" + "1234567890Idempotent"
        let raw = """
        port: 5173
        pid: 42
        processName: node
        executablePath: /opt/homebrew/bin/node
        projectName: SampleProject
        framework: Vite
        command: vite --host localhost --port 3000 \(syntheticSample)
        """

        let first = ProcessContextSanitizer.sanitize(raw)
        let repeated = ProcessContextSanitizer.sanitize(raw)
        let twice = ProcessContextSanitizer.sanitize(first.text)

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first, twice)
        XCTAssertFalse(first.text.contains(syntheticSample))
        XCTAssertTrue(first.text.contains("[REDACTED]"))
        XCTAssertTrue(first.text.contains("port: 5173"))
        XCTAssertTrue(first.text.contains("pid: 42"))
        XCTAssertTrue(first.text.contains("processName: node"))
        XCTAssertTrue(first.text.contains("executablePath: /opt/homebrew/bin/node"))
        XCTAssertTrue(first.text.contains("projectName: SampleProject"))
        XCTAssertTrue(first.text.contains("framework: Vite"))
        XCTAssertTrue(first.text.contains("--host localhost --port 3000"))
    }
}

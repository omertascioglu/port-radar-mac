# Port Radar Offline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Turn the current local-Ollama feature branch into a publicly distributable, tunnel-free `Port Radar Offline` fork whose process and chat data never leaves the Mac and whose Ollama responses stream without the current five-second failure.

**Architecture:** Delete the Cloudflare feature rather than hiding it. Replace the fixed connection to a user-managed Ollama server with a reference-counted actor that launches a dedicated, cloud-disabled Ollama child process on an exact loopback endpoint and hands consumers scoped leases. Make the provider-neutral conversation API stream text, keep all chat state in memory, and close the model and child process as soon as the last Local AI owner releases its lease.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Concurrency actors/tasks/`AsyncThrowingStream`, Foundation `Process` and `URLSession`, XCTest, Swift Package Manager, macOS 14+, conditionally compiled Foundation Models support on macOS 26+, Next.js marketing site, Apache License 2.0.

---

## Working rules

- Work only on `feature/port-radar-offline` in the existing dedicated worktree.
- Read `docs/superpowers/specs/2026-08-24-port-radar-offline-design.md` before starting.
- Use `@superpowers:test-driven-development` for every behavior change: add one focused failing test, observe the intended failure, implement the minimum, and rerun.
- Use `@superpowers:systematic-debugging` for every unexpected failure. Do not guess.
- Preserve all pre-existing user changes and Apache 2.0 modification notices.
- Never launch Ollama, pull a model, open a browser, start a tunnel, or contact a non-loopback endpoint from automated tests.
- Use deterministic fakes for process launch, readiness probes, clocks, sleep, byte streams, and termination.
- Do not print or log prompts, responses, raw process context, environment contents, or server bodies.
- Commit after each task with the exact commit message listed below.

Use this focused macOS test command throughout, replacing `<Filter>`:

```bash
cd apps/mac
CLANG_MODULE_CACHE_PATH=/tmp/port-radar-offline-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/port-radar-offline-swift \
swift test --disable-sandbox \
  --scratch-path /tmp/port-radar-offline-build \
  --filter <Filter>
```

Expected GREEN output for every focused run: the selected tests execute with `0 failures` and the command exits `0`.

### Task 1: Establish the offline product boundary and remove tunnels

**Files:**
- Create: `apps/mac/Tests/DevPortTests/OfflineProductBoundaryTests.swift`
- Modify: `apps/mac/Sources/DevPort/Views/ContentView.swift`
- Modify: `apps/mac/Sources/DevPort/State/AppState.swift`
- Delete: `apps/mac/Sources/DevPort/Actions/CloudflaredBootstrap.swift`
- Delete: `apps/mac/Sources/DevPort/Actions/TunnelManager.swift`
- Delete: `apps/mac/Sources/DevPort/Views/TunnelsView.swift`

**Step 1: Write the failing source-boundary test**

Add a test that resolves `Sources/DevPort` relative to `#filePath`, enumerates only `.swift` source files, and reports every forbidden runtime token with its relative filename. Keep the forbidden spellings assembled from fragments so the test file itself does not trigger its own scan.

```swift
final class OfflineProductBoundaryTests: XCTestCase {
    func testShippingSourcesContainNoTunnelImplementation() throws {
        let sourceRoot = try sourceRootURL()
        let forbidden = [
            ["Cloud", "flared"].joined(),
            ["Tunnel", "Manager"].joined(),
            ["Tunnels", "Modal"].joined(),
            ["trycloud", "flare.com"].joined(),
            ["Share via ", "Cloudflare"].joined(),
        ]

        let violations = try swiftSources(at: sourceRoot).flatMap { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            return forbidden.compactMap { token in
                text.contains(token) ? "\(url.lastPathComponent): \(token)" : nil
            }
        }
        XCTAssertEqual(violations, [])
    }
}
```

Implement `sourceRootURL()` and `swiftSources(at:)` in the test with `FileManager`; fail if the source root cannot be found so a path error cannot produce a false pass.

**Step 2: Run the focused test and observe RED**

Run the shared command with `--filter OfflineProductBoundaryTests`.

Expected: FAIL listing `CloudflaredBootstrap.swift`, `TunnelManager.swift`, `TunnelsView.swift`, and references in `ContentView.swift`/`AppState.swift`.

**Step 3: Remove the feature completely**

- Delete the three tunnel implementation files.
- Remove `showTunnels`, `tunnelsFocusPort`, `TunnelManager.shared`, the tunnel modal, animations, footer entry, share/manage closures, shared badge, public-URL menu items, and Share action from `ContentView.swift`.
- Simplify `ServerRow` to accept only Ask and Stop callbacks.
- Keep local “Open in Browser,” Finder, editor, and Terminal actions; those are explicit local user actions, not data transmission by the app.
- Remove `TunnelManager.shared.prune(...)` from `AppState.apply`.
- Do not leave dead `#if`, hidden controls, or commented-out tunnel code.

**Step 4: Run focused and full tests**

Run the focused test, then:

```bash
cd apps/mac
CLANG_MODULE_CACHE_PATH=/tmp/port-radar-offline-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/port-radar-offline-swift \
swift test --disable-sandbox --scratch-path /tmp/port-radar-offline-build
```

Expected: boundary test and full suite PASS; the executable target compiles without any tunnel type.

**Step 5: Commit**

```bash
git add apps/mac/Sources/DevPort apps/mac/Tests/DevPortTests/OfflineProductBoundaryTests.swift
git commit -m "feat: remove public tunnel sharing"
```

### Task 2: Give the fork a non-conflicting product identity

**Files:**
- Modify: `apps/mac/Tests/DevPortTests/OfflineProductBoundaryTests.swift`
- Modify: `apps/mac/Sources/DevPort/DevPortApp.swift`
- Modify: `apps/mac/Sources/DevPort/Views/ContentView.swift`
- Modify: `apps/mac/Sources/DevPort/AI/LocalAIProvider.swift`
- Modify: `apps/mac/Sources/DevPort/Actions/LaunchAtLogin.swift`
- Modify: `apps/mac/Support/Info.plist`
- Modify: `apps/mac/Support/release-notes.md`
- Modify: `apps/mac/Makefile`

**Step 1: Add failing identity tests**

Extend `OfflineProductBoundaryTests` to load `Support/Info.plist` relative to `#filePath` and assert:

```swift
XCTAssertEqual(plist["CFBundleName"] as? String, "Port Radar Offline")
XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Port Radar Offline")
XCTAssertEqual(
    plist["CFBundleIdentifier"] as? String,
    "com.omertascioglu.PortRadarOffline"
)
```

Also read `Makefile` and assert it contains `PRODUCT_NAME := Port Radar Offline`, `Port-Radar-Offline-$(VERSION).dmg`, and `Port-Radar-Offline.dmg`.

**Step 2: Run RED**

Run with `--filter OfflineProductBoundaryTests`.

Expected: FAIL because the plist and release artifacts still use the upstream identity.

**Step 3: Apply the identity change**

- Change visible menu-bar, title, quit, prompt, release, DMG, and bundle strings to `Port Radar Offline`.
- Set the exact bundle identifier from the test.
- Keep the SwiftPM target and executable named `DevPort`; changing internal module identity adds no user value.
- Change stable release artifact names to `Port-Radar-Offline-<version>.dmg` and `Port-Radar-Offline.dmg`.
- Update modification notices on every changed distributed file.

**Step 4: Verify**

Run `OfflineProductBoundaryTests`, the full Swift suite, and:

```bash
cd apps/mac
make bundle
plutil -p "Port Radar Offline.app/Contents/Info.plist"
```

Expected: tests PASS; bundle exists under the new name; plist prints the exact new display name and bundle identifier.

**Step 5: Commit**

```bash
git add apps/mac
git commit -m "feat: brand the offline fork"
```

### Task 3: Locate Ollama without opening or downloading it

**Files:**
- Create: `apps/mac/Sources/DevPort/AI/OllamaExecutableLocator.swift`
- Create: `apps/mac/Tests/DevPortTests/OllamaExecutableLocatorTests.swift`

**Step 1: Write failing locator tests**

Define tests for these cases:

- an executable returned from the `com.electron.ollama` app bundle is preferred;
- `/opt/homebrew/bin/ollama` and `/usr/local/bin/ollama` are fallback candidates;
- non-executable files and symlinks resolving outside the discovered Ollama app/known CLI locations are rejected;
- no candidate throws `OllamaExecutableLocatorError.notInstalled` without opening an application or URL.

The production API should be:

```swift
protocol OllamaExecutableLocating: Sendable {
    func locate() throws -> URL
}

struct OllamaExecutableLocator: OllamaExecutableLocating, Sendable {
    func locate() throws -> URL
}

enum OllamaExecutableLocatorError: Error, Equatable, Sendable {
    case notInstalled
}
```

Inject bundle lookup, canonical-path resolution, and executable checks in a `#if DEBUG` initializer so tests never inspect or launch the user's installed applications.

**Step 2: Run RED**

Run with `--filter OllamaExecutableLocatorTests`.

Expected: compile failure because the locator does not exist.

**Step 3: Implement the fail-closed locator**

- Resolve the Ollama app with `NSWorkspace` only to locate its bundle; never activate it.
- Canonicalize paths before validating them.
- Accept the app's bundled CLI only when it is inside the canonical Ollama bundle and executable.
- Check the two known CLI paths as fallbacks.
- Do not search arbitrary user-controlled `PATH` entries from the GUI environment.
- Keep the old `OllamaApplication.open` helper temporarily because the existing Settings implementation still references it. Task 10 deletes it in the same commit that removes the Open/Download UI.

**Step 4: Run tests**

Run `OllamaExecutableLocatorTests` and the full Swift suite.

Expected: PASS, with no application launch in tests.

**Step 5: Commit**

```bash
git add apps/mac/Sources/DevPort/AI/OllamaExecutableLocator.swift apps/mac/Tests/DevPortTests/OllamaExecutableLocatorTests.swift
git commit -m "feat: locate installed Ollama safely"
```

### Task 4: Launch a dedicated cloud-disabled Ollama child process

**Files:**
- Create: `apps/mac/Sources/DevPort/AI/OllamaProcess.swift`
- Create: `apps/mac/Tests/DevPortTests/OllamaProcessTests.swift`
- Modify: `apps/mac/Sources/DevPort/AI/LocalAIError.swift`

**Step 1: Write failing launch-contract tests**

Build a recording launcher and assert the exact launch specification:

```swift
XCTAssertEqual(spec.arguments, ["serve"])
XCTAssertEqual(spec.environment["OLLAMA_HOST"], "127.0.0.1:11435")
XCTAssertEqual(spec.environment["OLLAMA_NO_CLOUD"], "1")
XCTAssertNil(spec.environment["OLLAMA_API_KEY"])
XCTAssertFalse(spec.environment.keys.contains("HTTP_PROXY"))
XCTAssertFalse(spec.environment.keys.contains("HTTPS_PROXY"))
XCTAssertFalse(spec.environment.keys.contains("ALL_PROXY"))
```

Also prove stdout/stderr are discarded rather than logged, the executable URL is the locator's canonical URL, terminate is idempotent, and a child that does not exit after the injected grace period receives a force-kill only through the owned process handle.

**Step 2: Run RED**

Run with `--filter OllamaProcessTests`.

Expected: compile failure because process abstractions do not exist.

**Step 3: Implement process ownership**

Create these boundaries:

```swift
struct OllamaLaunchSpec: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let host: String
    let port: Int
}

protocol OllamaOwnedProcess: Sendable {
    var processIdentifier: Int32 { get async }
    var isRunning: Bool { get async }
    func terminate() async
    func waitForExit() async
    func forceKill() async
}

protocol OllamaProcessLaunching: Sendable {
    func launch(_ spec: OllamaLaunchSpec) throws -> any OllamaOwnedProcess
}
```

The live adapter owns Foundation `Process` behind an actor and never exposes the `Process` object across isolation. Build the child environment from a minimal allowlist (`PATH`, `HOME`, `TMPDIR`, locale, model location if present), explicitly remove proxy/auth variables, then set `OLLAMA_HOST` and `OLLAMA_NO_CLOUD`. Do not copy the complete parent environment. Route output to `/dev/null`; do not create readability handlers.

Use fixed dedicated port `11435` for the first implementation. This task maps synchronous process-launch failures to `.ollamaPrivateServiceUnavailable`. Task 5 owns the readiness boundary: it detects an occupied port or a child that exits before readiness, terminates only the owned child, and fails closed without connecting to the occupant.

Map `OllamaExecutableLocatorError.notInstalled` to a new `.ollamaNotInstalled` Local AI error with bounded copy `“Ollama is not installed. Install it separately, then try again.”`. Update every exhaustive LocalAIError switch and its focused expectations in the same TDD cycle so this task leaves the full suite compiling.

**Step 4: Run tests**

Run `OllamaProcessTests` and the full suite.

Expected: PASS; no real process is launched.

**Step 5: Commit**

```bash
git add apps/mac/Sources/DevPort/AI apps/mac/Tests/DevPortTests/OllamaProcessTests.swift
git commit -m "feat: launch private Ollama service"
```

### Task 5: Add reference-counted service leases and readiness

**Files:**
- Create: `apps/mac/Sources/DevPort/AI/OllamaServiceManager.swift`
- Create: `apps/mac/Tests/DevPortTests/OllamaServiceManagerTests.swift`
- Modify: `apps/mac/Sources/DevPort/AI/LocalAIError.swift`

**Step 1: Write deterministic failing lifecycle tests**

Cover:

- first acquire locates and launches once;
- concurrent acquires share the same in-progress launch and exact endpoint;
- readiness succeeds only after the owned child remains running and the injected probe recognizes `/api/version`;
- a pre-occupied port, early child exit, wrong final URL, or failed probe terminates the owned child and returns a bounded error;
- releasing one of two leases keeps the service running;
- releasing the final lease terminates it immediately;
- repeated/concurrent release terminates once;
- acquire racing with final release is serialized without returning a dead service;
- cancellation during startup terminates the unowned child;
- `shutdownAll()` prevents later acquisition and terminates only the manager-owned child;
- no code adopts or kills an unrelated process on `11434` or `11435`.

Use this public shape:

```swift
struct OllamaServiceEndpoint: Equatable, Sendable {
    let baseURL: URL
    let processIdentifier: Int32
}

struct OllamaServiceLease: Sendable {
    let endpoint: OllamaServiceEndpoint
    func release() async
}

actor OllamaServiceManager {
    static let shared = OllamaServiceManager.live()
    func acquire() async throws -> OllamaServiceLease
    func shutdownAll() async
}
```

**Step 2: Run RED**

Run with `--filter OllamaServiceManagerTests`.

Expected: compile failure because the service manager is absent.

**Step 3: Implement the manager**

- Keep owned process state, launch task, lease UUID set, and termination state actor-isolated.
- Use an injected readiness probe and injected sleep/clock; production polls only the exact `http://127.0.0.1:11435/api/version` endpoint for a short bounded startup period.
- Before every successful probe result, confirm the owned process is still running.
- Resume every waiting acquire exactly once.
- `OllamaServiceLease.release()` delegates to one idempotent release registration so copied leases cannot over-release.
- On final release, stop the child; do not retain it for an idle grace period.
- Do not persist PID or service data. After an unclean crash, a later launch fails closed if the dedicated port remains occupied rather than killing an unverifiable process.

**Step 4: Stress and full verification**

Run `OllamaServiceManagerTests`, repeat it 50 times in a shell loop, then run the full suite.

Expected: every run exits `0`; launch and terminate counts remain exactly one in race tests.

**Step 5: Commit**

```bash
git add apps/mac/Sources/DevPort/AI apps/mac/Tests/DevPortTests/OllamaServiceManagerTests.swift
git commit -m "feat: manage local Ollama lifetime"
```

### Task 6: Make the hardened transport lease-bound and dynamic

**Files:**
- Modify: `apps/mac/Sources/DevPort/AI/OllamaTransport.swift`
- Modify: `apps/mac/Sources/DevPort/AI/OllamaClient.swift`
- Modify: `apps/mac/Tests/DevPortTests/OllamaTransportTests.swift`
- Modify: `apps/mac/Tests/DevPortTests/OllamaClientTests.swift`

**Step 1: Write failing endpoint tests**

Replace assertions for static `11434` with a test endpoint created from an owned lease. Add cases for:

- exact `http://127.0.0.1:11435` acceptance;
- rejection of `localhost`, IPv6, user info, query, fragment, encoded paths, alternate/equivalent ports, and every non-loopback host;
- rejection of `/api/pull`, `/api/create`, `/api/delete`, web-search paths, and unknown paths;
- rejection of redirects even when they return to the same origin; the offline client does not need redirects;
- cancellation of all authentication challenges;
- no cookies, cache, credentials, proxy dictionary, or ambient proxy use;
- no release-visible initializer that accepts an arbitrary base URL or `URLSession.shared`.

Expected production construction:

```swift
struct OllamaOriginPolicy: Sendable {
    let endpoint: OllamaServiceEndpoint
    func allows(_ url: URL, path: String) -> Bool
}

struct OllamaTransport: OllamaTransporting, Sendable {
    init(lease: OllamaServiceLease)
}
```

**Step 2: Run RED**

Run `OllamaTransportTests`.

Expected: old static-origin assertions fail and the new initializer is missing.

**Step 3: Implement the lease-bound boundary**

- Remove `OllamaOriginPolicy.baseURL` and port `11434` from production code.
- Construct requests only by appending an allowlisted path to the lease endpoint.
- Always reject redirects by returning `nil` from the redirect delegate.
- Verify the final response URL against the exact lease endpoint before exposing data.
- Keep loader injection `private` plus `#if DEBUG` test factories.
- Separate short control-request configuration from the streaming configuration introduced in Task 7; do not reintroduce a five-second total chat deadline.
- Make `OllamaClient` require a lease-backed transport. There must be no default client that silently contacts a globally running Ollama server.

**Step 4: Verify**

Run `OllamaTransportTests`, `OllamaClientTests`, and the full suite.

Expected: PASS; this source scan returns no production `11434` reference:

```bash
rg -n '11434|localhost:11434' apps/mac/Sources/DevPort
```

**Step 5: Commit**

```bash
git add apps/mac/Sources/DevPort/AI/OllamaTransport.swift apps/mac/Sources/DevPort/AI/OllamaClient.swift apps/mac/Tests/DevPortTests/OllamaTransportTests.swift apps/mac/Tests/DevPortTests/OllamaClientTests.swift
git commit -m "fix: bind Ollama transport to private service"
```

### Task 7: Parse and expose Ollama's streaming response

**Files:**
- Modify: `apps/mac/Sources/DevPort/AI/OllamaModels.swift`
- Modify: `apps/mac/Sources/DevPort/AI/OllamaTransport.swift`
- Modify: `apps/mac/Sources/DevPort/AI/OllamaClient.swift`
- Modify: `apps/mac/Tests/DevPortTests/OllamaModelValidationTests.swift`
- Modify: `apps/mac/Tests/DevPortTests/OllamaTransportTests.swift`
- Modify: `apps/mac/Tests/DevPortTests/OllamaClientTests.swift`

**Step 1: Write RED tests for NDJSON streaming**

Add a transport seam that returns a controlled `AsyncThrowingStream<Data, Error>`. Tests must prove:

- request body contains `"stream": true`;
- `keep_alive` does not unload before chat closes;
- chunks `Hel`, `lo`, `!` are emitted in order before the final marker;
- blank lines are ignored;
- an API `{ "error": ... }` chunk becomes bounded `.malformedResponse` without exposing its body;
- invalid JSON, oversized line, oversized cumulative response, missing final marker, and a wrong final URL fail closed;
- parent cancellation stops the producer task and yields `CancellationError`;
- a slow but active stream does not fail at five seconds;
- `/api/version`, `/api/tags`, `/api/show`, and unload remain bounded control requests.

Use these contracts:

```swift
typealias LocalAITextStream = AsyncThrowingStream<String, any Error>

protocol OllamaTransporting: Sendable {
    func request(path: String, method: String, body: Data?) async throws -> Data
    func stream(path: String, method: String, body: Data?) async throws
        -> AsyncThrowingStream<Data, any Error>
}

protocol OllamaClientProtocol: Sendable {
    func chatStream(
        model: String,
        messages: [OllamaChatMessage]
    ) async throws -> LocalAITextStream
}
```

Add a decoding type with optional content, `done`, and `error` fields. Never surface the raw error string.

**Step 2: Run RED**

Run `OllamaModelValidationTests`, `OllamaTransportTests`, and `OllamaClientTests` separately.

Expected: compile failures for the streaming APIs followed by focused assertion failures as each layer is introduced.

**Step 3: Implement the minimal stream pipeline**

- Use `URLSession.bytes(for:)` in the live loader and bridge newline-delimited records into a cancellation-aware `AsyncThrowingStream<Data, Error>`.
- Validate HTTP status and final URL before returning the stream.
- Enforce per-line and cumulative byte limits before decoding.
- Decode one JSON object per line and yield only non-empty assistant content.
- Require the final `done: true` record.
- Map `URLError.cancelled` to `CancellationError`; keep other mappings bounded.
- Remove the old non-streaming `chat(...) -> String` production path.

**Step 4: Verify**

Run the three focused suites, then the full suite.

Expected: PASS; a controlled test receives the first text chunk while the producer remains suspended before completion.

**Step 5: Commit**

```bash
git add apps/mac/Sources/DevPort/AI/OllamaModels.swift apps/mac/Sources/DevPort/AI/OllamaTransport.swift apps/mac/Sources/DevPort/AI/OllamaClient.swift apps/mac/Tests/DevPortTests/OllamaModelValidationTests.swift apps/mac/Tests/DevPortTests/OllamaTransportTests.swift apps/mac/Tests/DevPortTests/OllamaClientTests.swift
git commit -m "feat: stream local Ollama responses"
```

### Task 8: Make Ollama conversations own and release the service lease

**Files:**
- Modify: `apps/mac/Sources/DevPort/AI/LocalAIProvider.swift`
- Modify: `apps/mac/Sources/DevPort/AI/AIProviderResolver.swift`
- Modify: `apps/mac/Sources/DevPort/AI/OllamaProvider.swift`
- Modify: `apps/mac/Sources/DevPort/AI/AppleFoundationModelProvider.swift`
- Modify: `apps/mac/Sources/DevPort/AI/LocalAIConversationRegistry.swift`
- Modify: `apps/mac/Tests/DevPortTests/AIProviderResolverTests.swift`
- Modify: `apps/mac/Tests/DevPortTests/OllamaConversationTests.swift`
- Modify: `apps/mac/Tests/DevPortTests/AppleProviderFallbackTests.swift`
- Modify: `apps/mac/Tests/DevPortTests/LocalAIConversationRegistryTests.swift`

**Step 1: Write failing conversation/lifecycle tests**

Change the provider-neutral contract to:

```swift
protocol LocalAIConversation: Sendable {
    var providerID: LocalAIProviderID { get }
    func streamResponse(to prompt: String) async throws -> LocalAITextStream
    func close() async
}
```

Add tests proving:

- Ollama provider acquires its own service lease only after a non-empty local model is selected;
- model validation happens against the lease-bound client before conversation creation and before every generation;
- automatic resolver checks Apple availability, then creates Ollama directly without an availability/start/stop/start cycle;
- stream chunks pass through immediately and the complete assistant reply is appended to history only after `done`;
- a failed partial response is not committed to future conversation history;
- close cancels validation/stream, waits for unwind, unloads exactly once, then releases the lease exactly once;
- close before first chat skips unload but still releases the lease;
- queued responses remain serialized and independently cancelable;
- Apple implementation emits one stream chunk when native streaming is unavailable;
- managed registry wrappers preserve streaming and close-once behavior.

**Step 2: Run RED**

Run the four focused suites named above.

Expected: compile failures for `streamResponse` and service ownership.

**Step 3: Implement provider-neutral streaming**

- Replace `respond(to:)` with `streamResponse(to:)` throughout the protocol and wrappers.
- Have `OllamaProvider.makeConversation` acquire a lease from `OllamaServiceManager`, create a lease-bound client, validate the selected model, and release on every failure path.
- Specialize `AIProviderResolver` so Ollama creation does not perform a separate availability probe that would churn the private service.
- Have `OllamaConversation` aggregate emitted chunks for history while forwarding them live.
- Preserve existing serialization, queued cancellation, close races, and late-result authorization.
- Keep Apple lifecycle serialization intact; initially wrap its existing complete reply as a one-chunk stream instead of adding unverified macOS 26 API surface.
- On Ollama close, cancel and await active work, unload, then release the service lease.

**Step 4: Stress and verify**

Run focused suites, repeat `OllamaConversationTests` and `LocalAIConversationRegistryTests` 50 times, then run the full suite.

Expected: all runs PASS; unload precedes final lease release in controlled event logs.

**Step 5: Commit**

```bash
git add apps/mac/Sources/DevPort/AI apps/mac/Tests/DevPortTests
git commit -m "feat: stream provider conversations"
```

### Task 9: Render partial responses and add Stop

**Files:**
- Modify: `apps/mac/Sources/DevPort/AI/AgentChatModel.swift`
- Modify: `apps/mac/Sources/DevPort/Views/AgentChatView.swift`
- Modify: `apps/mac/Tests/DevPortTests/AgentChatModelTests.swift`

**Step 1: Write failing UI-model tests**

Use a controlled conversation stream and prove:

- sending inserts one user message and one empty assistant message;
- each chunk updates the same assistant message before stream completion;
- `isSending` remains true while the stream is open;
- `stopGeneration()` cancels the active request, preserves received partial text, and restores sendability;
- Stop with no active request is harmless;
- mid-stream failure preserves partial text and appends one bounded system error;
- cancellation does not append an error;
- closing prevents late chunks from changing cleared state;
- a second send cannot overlap the first;
- stream changes increment an observable scroll revision.

Production API additions:

```swift
private(set) var streamRevision = 0

func stopGeneration() {
    generationTask?.cancel()
}
```

Give `AgentMessage` an initializer that accepts a stable ID so chunks mutate one message rather than appending a bubble per token.

**Step 2: Run RED**

Run `AgentChatModelTests`.

Expected: compile failure for streaming and Stop APIs.

**Step 3: Implement incremental UI state**

- Append the assistant placeholder before consuming the stream.
- Mutate it only when attempt ID, message ID, and open state all match.
- Retain partial text on Stop or transport failure.
- Change the thinking row to a Stop button with a progress indicator and accessibility label `Stop response`.
- Disable send during generation and keep Close behavior idempotent.
- Auto-scroll on `streamRevision`, not only message count.
- Show the exact privacy line `Offline — data never leaves this Mac.` in the chat.

**Step 4: Verify**

Run `AgentChatModelTests`, repeat its cancellation tests 50 times, then run the full suite and a debug build.

Expected: PASS; no race leaves `isSending` true after Stop.

**Step 5: Commit**

```bash
git add apps/mac/Sources/DevPort/AI/AgentChatModel.swift apps/mac/Sources/DevPort/Views/AgentChatView.swift apps/mac/Tests/DevPortTests/AgentChatModelTests.swift
git commit -m "feat: show streaming local AI responses"
```

### Task 10: Use temporary private-service leases in Settings

**Files:**
- Modify: `apps/mac/Sources/DevPort/AI/OllamaSettingsModel.swift`
- Modify: `apps/mac/Sources/DevPort/Views/SettingsView.swift`
- Modify: `apps/mac/Tests/DevPortTests/OllamaSettingsModelTests.swift`
- Modify: `apps/mac/Tests/DevPortTests/LocalAIStatusTextTests.swift`
- Delete: `apps/mac/Sources/DevPort/Actions/OllamaApplication.swift`

**Step 1: Write failing settings tests**

Replace Open-Ollama tests with service-manager tests proving:

- refresh acquires a private-service lease, lists validated local models, and releases immediately afterward;
- every success, failure, cancellation, stale generation, and view disappearance releases exactly once;
- concurrent refresh cancels the old operation, prevents stale publication, and guarantees every acquired lease is released exactly once;
- missing executable shows `Ollama is not installed.` with no download-link state;
- no local models shows non-clickable instructions to install a model outside Port Radar Offline;
- cloud/ambiguous models never reach the picker;
- selected model is cleared only when the current persisted selection still matches the refresh snapshot;
- privacy copy is exactly `Offline — data never leaves this Mac.`.

Use injected acquisition:

```swift
typealias AcquireService = @Sendable () async throws -> OllamaServiceLease

init(
    acquireService: @escaping AcquireService = {
        try await OllamaServiceManager.shared.acquire()
    },
    preferences: Preferences = .shared
)
```

**Step 2: Run RED**

Run `OllamaSettingsModelTests` and `LocalAIStatusTextTests`.

Expected: old Open/Download expectations fail.

**Step 3: Implement temporary discovery**

- Remove `openApplication`, retry delays, `openOllamaAndRetry`, and `showsDownloadLink`.
- Delete the now-unreferenced `OllamaApplication.open` helper.
- Acquire a service lease inside refresh, construct a lease-bound client, fetch local models, and release in a structured cleanup path.
- Settings offers only `Check local models`/`Refresh`, provider picker, local model picker, readiness text, and non-clickable installation guidance.
- Remove `Link("Download Ollama", ...)` and all external URL constants.
- Cancel and release when Ollama controls disappear or Settings closes.

**Step 4: Verify**

Run both focused suites and the full suite.

Expected: PASS; source scan finds no `ollama.com/download`, `openOllama`, or `showsDownloadLink` in the macOS shipping source.

**Step 5: Commit**

```bash
git add apps/mac/Sources/DevPort/AI/OllamaSettingsModel.swift apps/mac/Sources/DevPort/Actions/OllamaApplication.swift apps/mac/Sources/DevPort/Views/SettingsView.swift apps/mac/Tests/DevPortTests/OllamaSettingsModelTests.swift apps/mac/Tests/DevPortTests/LocalAIStatusTextTests.swift
git commit -m "feat: discover models with private Ollama"
```

### Task 11: Close conversations and the private service on application exit

**Files:**
- Modify: `apps/mac/Sources/DevPort/DevPortApp.swift`
- Modify: `apps/mac/Sources/DevPort/AI/LocalAIConversationRegistry.swift`
- Modify: `apps/mac/Tests/DevPortTests/LocalAIConversationRegistryTests.swift`
- Modify: `apps/mac/Tests/DevPortTests/OllamaServiceManagerTests.swift`

**Step 1: Write failing ordered-cleanup tests**

Inject two cleanup actions into `AppDelegate` and record events. Assert:

```swift
XCTAssertEqual(events, ["conversations-closed", "service-stopped"])
```

Also test concurrent chat close plus app termination, termination during service startup, and repeated termination. Each must close/unload/release/terminate at most once and reject late registration or acquisition.

**Step 2: Run RED**

Run `LocalAIConversationRegistryTests` and `OllamaServiceManagerTests`.

Expected: AppDelegate lacks service cleanup and event ordering assertion fails.

**Step 3: Implement ordered shutdown**

- Replace fire-and-forget `applicationWillTerminate` cleanup with `applicationShouldTerminate(_:)`: return `.terminateLater`, run the ordered asynchronous cleanup once, and call `reply(toApplicationShouldTerminate: true)` on the main actor only after cleanup settles. Repeated termination requests share the same task.
- App termination first calls `LocalAIConversationRegistry.shared.closeActive()` so conversations unload their models and release leases.
- It then calls `OllamaServiceManager.shared.shutdownAll()` as a final barrier.
- Preserve the registry's termination barrier and close-once behavior.
- Do not block the main thread with `waitUntilExit`; all waits remain asynchronous and bounded inside owned-process abstractions.

**Step 4: Stress and verify**

Run both focused suites 50 times, then the full suite and release build.

Expected: every run PASS; recorded order is stable.

**Step 5: Commit**

```bash
git add apps/mac/Sources/DevPort/DevPortApp.swift apps/mac/Sources/DevPort/AI/LocalAIConversationRegistry.swift apps/mac/Tests/DevPortTests/LocalAIConversationRegistryTests.swift apps/mac/Tests/DevPortTests/OllamaServiceManagerTests.swift
git commit -m "fix: stop private AI service on exit"
```

### Task 12: Rewrite public documentation, marketing UI, and notices

**Files:**
- Modify: `README.md`
- Modify: `NOTICE`
- Modify: `apps/mac/README.md`
- Modify: `apps/mac/Support/release-notes.md`
- Modify: `apps/web/README.md`
- Modify: `apps/web/src/lib/site.ts`
- Modify: `apps/web/src/app/layout.tsx`
- Modify: `apps/web/src/app/page.tsx`
- Modify: `apps/web/src/components/AppDemo.tsx`
- Modify: `apps/web/src/components/PressPanel.tsx`
- Modify: `apps/web/src/app/press/gallery/[slide]/page.tsx`
- Modify: `apps/web/src/app/globals.css`
- Create: `docs/testing/port-radar-offline-manual-matrix.md`
- Delete: `docs/testing/local-ai-manual-matrix.md`

**Step 1: Add a failing repository copy audit**

Extend `OfflineProductBoundaryTests` to scan public first-party text/source files while excluding `.git`, `.build`, `node_modules`, package lockfiles, the historical design/plan files, `LICENSE`, and required upstream attribution inside `NOTICE`. Assemble forbidden tunnel spellings from fragments. Assert no shipping or marketing copy advertises Share, Cloudflare, tunnels, the upstream download URL, upstream Product Hunt page, or the old app name as the current product.

Also assert:

- README contains `Port Radar Offline` and `A tunnel-free, offline-focused fork of Port Radar`;
- README links to `https://github.com/juansebsol/port-radar-mac` as upstream;
- NOTICE retains Juan Sebastian Solano's complete existing notice and adds `Port Radar Offline modifications` plus the fork maintainer attribution;
- LICENSE is byte-for-byte unchanged from `origin/main` (perform this part with the shell check in Step 4, not from a networked test).

**Step 2: Run RED**

Run `OfflineProductBoundaryTests`.

Expected: FAIL on README, macOS docs, web copy/demo, press slides, release notes, and manual matrix.

**Step 3: Rewrite without expanding product scope**

- Describe Scan, Ask, and Stop only.
- Explain Apple On-Device, managed `OLLAMA_NO_CLOUD=1` service, local model requirement, in-memory chat, secret sanitization, immediate unload, and no automatic download.
- Remove the website's tunnel animation/stills and replace that space with an offline streaming Ask state; do not redesign unrelated layout.
- Set the repository URL to `https://github.com/omertascioglu/port-radar-mac` and the download URL to `https://github.com/omertascioglu/port-radar-mac/releases/latest/download/Port-Radar-Offline.dmg`; do not publish or deploy.
- Remove links to the upstream Product Hunt listing. Product Hunt launch work remains a later, separate publication task.
- Add modification notices to changed distributed source files.
- Add an honest manual matrix with every real-app/network-capture item initially marked `NOT RUN`.
- Keep `LICENSE` unchanged. Append fork attribution to `NOTICE`; do not replace upstream attribution.
- Follow `apps/web/AGENTS.md`; before modifying Next.js files, read the relevant installed Next.js guides under `apps/web/node_modules/next/dist/docs/`.

**Step 4: Verify docs and web**

Run:

```bash
cd apps/mac
CLANG_MODULE_CACHE_PATH=/tmp/port-radar-offline-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/port-radar-offline-swift \
swift test --disable-sandbox --scratch-path /tmp/port-radar-offline-build \
  --filter OfflineProductBoundaryTests

cd ../../apps/web
npm run lint
npm run build

cd ../..
git diff --exit-code origin/main -- LICENSE
```

Expected: Swift audit PASS, web lint/build exit `0`, and LICENSE diff exits `0`.

**Step 5: Commit**

```bash
git add README.md NOTICE apps/mac/README.md apps/mac/Support/release-notes.md apps/web docs/testing apps/mac/Tests/DevPortTests/OfflineProductBoundaryTests.swift
git commit -m "docs: present the offline fork"
```

### Task 13: Final automated verification and user-operated local trial

**Files:**
- Modify after manual run: `docs/testing/port-radar-offline-manual-matrix.md`
- Create locally, do not commit: `outputs/Port-Radar-Offline-Test.zip`
- Create locally, do not commit: `outputs/PORT-RADAR-OFFLINE-TESTING.md`

**Step 1: Run the complete automated gate**

From the repo root, run fresh commands with clean temporary caches:

```bash
git diff --check origin/main...HEAD

cd apps/mac
CLANG_MODULE_CACHE_PATH=/tmp/port-radar-offline-final-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/port-radar-offline-final-swift \
swift test --disable-sandbox \
  --scratch-path /tmp/port-radar-offline-final-debug

CLANG_MODULE_CACHE_PATH=/tmp/port-radar-offline-final-clang-release \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/port-radar-offline-final-swift-release \
swift build -c release --disable-sandbox \
  --scratch-path /tmp/port-radar-offline-final-release

cd ../web
npm run lint
npm run build
```

Expected: every command exits `0`; record exact test count and build results.

**Step 2: Run privacy/security audits**

From the repo root:

```bash
rg -n 'cloudflared|trycloudflare|TunnelManager|TunnelsModal|Share via Cloudflare' \
  apps/mac/Sources apps/mac/Support apps/web/src README.md apps/mac/README.md

rg -n 'https?://' apps/mac/Sources/DevPort

rg -n 'print\(|debugPrint\(|NSLog|os_log|Logger\(' apps/mac/Sources/DevPort/AI

rg -n '11434|ollama\.com|/api/(pull|create|delete)|web_search|web_fetch' \
  apps/mac/Sources/DevPort

gitleaks dir .
```

Expected: the forbidden runtime scans return no matches; any remaining `http://127.0.0.1` is constructed only from the owned service endpoint; logging scan contains no prompt/response path; gitleaks reports no leaks. Review every `https://` match manually—runtime app source must contain no external network action or in-app link.

**Step 3: Build the user test package without launching it**

```bash
cd apps/mac
make bundle
cd ../..
mkdir -p outputs
ditto -c -k --sequesterRsrc --keepParent \
  "apps/mac/Port Radar Offline.app" \
  "outputs/Port-Radar-Offline-Test.zip"
```

Create `outputs/PORT-RADAR-OFFLINE-TESTING.md` from the manual matrix with short, non-technical steps. Do not launch or control the app; the user explicitly operates it.

**Step 4: User performs the real local trial**

The user verifies:

1. Port Radar Offline and upstream Port Radar can coexist.
2. No Share or Tunnels control exists.
3. Settings finds an already installed local Ollama model without opening the Ollama desktop app or downloading anything.
4. A cold first answer may be slow but does not fail after five seconds.
5. Text appears incrementally.
6. Stop preserves partial text and permits a new question.
7. Closing chat unloads the model and terminates the private child service.
8. Reopening chat starts a fresh private service.
9. Network observation shows no non-loopback connection from Port Radar Offline or its managed Ollama child while process context and prompts are used.

Keep all unperformed checks marked `NOT RUN`. If any check fails, return to `@superpowers:systematic-debugging`, reproduce with a failing automated test where possible, fix, and repeat the full gate.

**Step 5: Record evidence and commit only the matrix**

After the user reports results, update environment, Ollama/model versions, and PASS/FAIL/NOT RUN values without inventing evidence.

```bash
git add docs/testing/port-radar-offline-manual-matrix.md
git commit -m "test: record offline privacy verification"
```

Do not add `outputs/`, push a branch, create a GitHub fork, open a PR, publish a release, deploy the website, or post to Product Hunt until the user separately authorizes that external action.

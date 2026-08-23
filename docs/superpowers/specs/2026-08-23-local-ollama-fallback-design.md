# Local Ollama Fallback Design

Date: 2026-08-23
Status: Proposed
Target: Port Radar for macOS
Upstream baseline: 0f4019de0fe64957411a155b81019ff20d0cbab9

## Summary

Port Radar's “Ask about process” feature currently depends on Apple's on-device
Foundation Models framework and therefore becomes unavailable when the operating
system, hardware, or Apple Intelligence settings do not support that model.

This change adds Ollama as an optional, local-only fallback. The default
Automatic mode continues to prefer Apple's on-device SystemLanguageModel. If
that model is unavailable, Port Radar may use an explicitly selected, locally
stored Ollama model. Users may also force either provider in Settings.

The privacy rule is strict: Port Radar does not send process context, prompts, or
responses to an internet service. A failure never triggers a cloud fallback.

## Goals

- Preserve the existing Apple Intelligence experience on supported Macs.
- Add useful process chat on Macs where Apple's model is unavailable.
- Let users choose Automatic, Apple Intelligence, or Ollama.
- Connect only to Ollama's loopback API at http://127.0.0.1:11434.
- Permit only Ollama models whose API metadata identifies them as locally
  stored, never remote or cloud-backed models.
- Load an Ollama model only when chat needs it and request immediate unloading
  when the chat closes.
- Keep prompts and responses in memory only.
- Redact likely secrets from process metadata before either provider sees it.
- Make the app compile with SDKs that do not include FoundationModels.
- Add automated coverage for provider selection, privacy boundaries, transport,
  model lifecycle, errors, and sanitization.

## Non-goals

- Downloading, installing, launching, stopping, or updating Ollama silently.
- Pulling or recommending a model automatically.
- Supporting a user-defined Ollama host, LAN host, container hostname, or remote
  endpoint in the first version.
- Supporting Ollama cloud models, web search, tools, or remote inference.
- Rebranding Port Radar in the upstream contribution.
- Changing Cloudflare tunnel behavior in the same pull request.
- Persisting chat history.
- Marketing or launching the upstream contribution as a separate Product Hunt
  product.

## Product and contribution scope

The work will live on a feature branch in a public fork and be proposed to the
original Port Radar repository as a focused pull request. The pull request keeps
the Port Radar product name, visual identity, existing Apache 2.0 license, and
attribution.

The existing LICENSE and NOTICE remain intact. New code is contributed under
the repository's Apache 2.0 terms. If the upstream project requires prominent
modification notices in changed source files, those notices are added without
replacing the original copyright or attribution.

A later personal fork may be named “Ömer Localhostlar” and may be launched as a
separate product only after it has substantial differentiation. That rebrand,
its Product Hunt materials, and any additional product features are outside this
change.

The earlier security review found separate concerns in the Cloudflare tunnel
feature: downloading a moving latest cloudflared binary without integrity
verification, removing quarantine, and not guaranteeing tunnel termination on
application exit. Those should be reported or fixed in a separate issue or pull
request so this contribution remains reviewable.

## Current state

- apps/mac/Package.swift declares macOS 14 as the deployment target.
- AgentChatView.swift and Actions/ProcessAgent.swift import FoundationModels
  unconditionally, so an SDK without that framework cannot compile the target.
- ProcessAgent uses SystemLanguageModel.default and LanguageModelSession for the
  existing Apple path.
- The process prompt currently includes port, PID, process name, command,
  executable path, working directory, project root, framework, and timing data.
- Settings has one Ask toggle but no provider or model selection.
- The Swift package currently has no test target.

## User experience

### Settings

The existing “Ask about process” toggle remains the top-level switch. When it is
on, Settings adds:

1. A provider picker:
   - Automatic (default)
   - Apple Intelligence
   - Ollama
2. An Ollama model picker populated only from models already available in the
   local Ollama service and verified as non-remote.
3. A compact status line such as:
   - Apple Intelligence is available
   - Ollama is running · 3 local models
   - Ollama is not running
   - No local Ollama models found
4. An “Open Ollama” action when the application is installed but its service is
   unavailable. If Ollama is not installed, the interface gives setup guidance
   and an explicit link; Port Radar does not download it.

No model is selected automatically. The user chooses from installed local
models. A previously saved selection is retained only while the same model still
passes local-model validation.

### Provider selection

Automatic resolves in this order:

1. Apple's on-device SystemLanguageModel when available.
2. The selected and validated local Ollama model when Apple is unavailable.
3. An unavailable state with actionable setup guidance.

Choosing Apple Intelligence disables fallback. If Apple's on-device model is
unavailable, the chat explains why and makes no Ollama request.

Choosing Ollama uses the selected local Ollama model even when Apple's model is
available. This supports users who do not want Apple Intelligence involved.

### Chat

The current modal remains visually familiar but becomes provider-neutral.
Its header displays a trust badge:

- Apple · On-device
- Ollama · Local

Opening the modal resolves and validates a provider. Ollama model weights are
not loaded merely by listing models. They are loaded by Ollama on the first chat
request. Closing the modal cancels any active generation and asks Ollama to
unload the model used by this chat.

The initial system message accurately names the active provider and says that
sanitized process context is available to it. It must not imply Apple
Intelligence when Ollama is active.

## Architecture

### Provider-neutral domain layer

Introduce a small abstraction that keeps SwiftUI and provider-specific SDK types
separate:

- LocalAIProvider describes identity, availability, and conversation creation.
- LocalAIConversation owns in-memory messages, responds asynchronously, cancels
  work, and closes provider resources.
- LocalAIProviderID identifies apple or ollama for UI and telemetry-free status
  display.
- LocalAIProviderPreference represents automatic, apple, or ollama.
- LocalAIProviderResolver applies the deterministic selection matrix.
- LocalAIError maps provider failures into actionable, provider-neutral UI
  messages.

The chat view depends on one conversation interface. It does not import
FoundationModels and does not construct URL requests.

Suggested source layout:

- Sources/DevPort/AI/LocalAIProvider.swift
- Sources/DevPort/AI/AIProviderResolver.swift
- Sources/DevPort/AI/AppleFoundationModelProvider.swift
- Sources/DevPort/AI/OllamaProvider.swift
- Sources/DevPort/AI/OllamaClient.swift
- Sources/DevPort/AI/ProcessContextSanitizer.swift
- Sources/DevPort/AI/LocalAIError.swift

Existing ProcessAgent responsibilities move into this directory. AgentChatView,
Preferences, SettingsView, ContentView, Package.swift, and README are updated to
use the new layer.

### Apple provider

AppleFoundationModelProvider explicitly uses SystemLanguageModel.default, which
Apple documents as the on-device Apple Foundation Model. It does not instantiate
PrivateCloudComputeLanguageModel or a custom remote LanguageModel.

All Apple-specific declarations and imports are guarded by:

    #if canImport(FoundationModels)

Runtime availability checks remain in addition to compile-time guards. On an SDK
without FoundationModels, the Apple provider compiles as unavailable while the
Ollama provider and the rest of the application remain functional.

The provider receives the same sanitized process context as Ollama. Its
LanguageModelSession remains in memory for the life of the chat and is discarded
when the modal closes.

### Ollama provider

OllamaProvider uses an injected OllamaClient so behavior can be tested without a
running service. The production client uses Foundation URLSession directly; no
third-party dependency is required.

The only allowed origin is:

    http://127.0.0.1:11434

The client supports only:

- GET /api/version for service detection and diagnostics.
- GET /api/tags to list already available models.
- POST /api/show to validate the selected model immediately before chat.
- POST /api/chat with stream false for conversation responses.
- POST /api/chat with an empty message list and keep_alive 0 to request unload.

The first contribution uses non-streaming responses to keep the scope small and
error handling deterministic. Streaming can be added later without changing the
provider boundary.

The client never calls /api/pull, /api/create, /api/delete, /api/push, web
search, web fetch, or any endpoint on ollama.com.

### Local-model validation

Loopback transport alone is not sufficient for a local-only claim. Current
Ollama versions can accept a request on localhost and forward it to Ollama Cloud
when a remote model is selected.

For every list refresh and again immediately before conversation creation, the
client validates model metadata:

- Reject when remote_host is present and non-empty.
- Reject when remote_model is present and non-empty.
- Reject explicit cloud identifiers, including a :cloud tag or -cloud suffix,
  as defense in depth for older Ollama versions.
- Require positive on-disk size, a non-empty digest, and non-empty model-format
  metadata; reject an entry if any of that local evidence is absent.
- Recheck the selected model through /api/show and apply the same remote-field
  rejection before the first prompt is sent.

Only models that pass all checks appear in the picker. If the API response does
not provide enough evidence to establish that a model is local, the model is
excluded rather than guessed safe. The UI can explain that a newer Ollama
version may be required.

No tools are supplied to /api/chat, so a local model cannot ask Port Radar to
perform web search or network actions.

This rule protects the data path controlled by Port Radar. A compromised or
privately modified Ollama daemon is outside the application's trust boundary and
cannot be made trustworthy by a client-side check.

## Data flow and privacy

### Prompt construction

ProcessContextSanitizer produces one immutable snapshot before provider
resolution. Both Apple and Ollama receive that same sanitized snapshot.

The sanitizer preserves useful structure while replacing likely secrets with
[REDACTED]. It covers at minimum:

- Environment-style assignments whose names contain token, secret, password,
  passwd, api key, access key, private key, client secret, authorization, or
  cookie.
- Command options in --key=value and --key value forms for the same names.
- Authorization bearer values.
- Credentials embedded in URL user-info.
- Common high-confidence token prefixes such as GitHub, Slack, and OpenAI-style
  tokens.
- Sensitive query parameters in URLs.

The sanitizer operates before string interpolation into provider instructions.
Tests use synthetic secrets only.

### Persistence

The app persists only:

- Ask enabled or disabled.
- Provider preference.
- Selected Ollama model identifier.

Process context, user prompts, assistant responses, sanitization input, and
provider errors containing response bodies are not written to UserDefaults,
files, analytics, crash breadcrumbs, or application logs. Chat messages exist
only in view/conversation memory and are released when the modal closes.

The Ollama client uses an ephemeral URLSession configuration with caches,
cookies, and credential storage disabled. Port Radar adds no request or response
body logging.

### Network boundary

Every production Ollama request is built by one transport object; callers cannot
provide an arbitrary URL.

Before dispatch, the transport requires:

- Scheme exactly http.
- Host exactly 127.0.0.1.
- Port exactly 11434.
- A known API path from the allowlist above.

The URLSession redirect delegate rejects any redirect that changes scheme, host,
port, or allowed path. It also rejects authentication challenges that would
cause credential lookup. A redirect failure is shown as a local-security error;
it never retries elsewhere.

Automatic mode does not contact Ollama when the Apple provider is available.
Provider discovery is lazy and occurs only when Settings needs Ollama status or
when chat resolution reaches the Ollama fallback.

### Privacy statement

The README and interface may state:

“Process context and chat stay on this Mac. Port Radar uses Apple's on-device
SystemLanguageModel or a verified locally stored Ollama model. It never falls
back to a cloud model.”

The text must not make a broader claim about unrelated features such as a
user-initiated Cloudflare public tunnel. The trust badge is therefore scoped to
the chat provider.

## Resource lifecycle

Port Radar does not keep Ollama or a model running in the background by itself.

- If Ollama is stopped, the app shows guidance and may explicitly open the
  installed Ollama application after a user click.
- If the user already runs Ollama, Port Radar uses that service and never
  terminates it.
- The first chat request lets Ollama load the selected model.
- Chat requests set a bounded keep_alive suitable for the open chat.
- Closing chat cancels the active URLSession task and sends an empty /api/chat
  request for the same model with keep_alive 0.
- App termination performs the same best-effort model-unload request for a model
  loaded by Port Radar.
- Port Radar tracks only the model used by its own conversation. It does not
  unload other models and does not stop the Ollama service.

Immediate unloading is best-effort because the app or daemon may terminate
before the request completes. The UI and README should describe this honestly.
Ollama's documented default also unloads inactive models after its configured
keep-alive period.

## State and concurrency

- Resolver and provider creation run off the main actor.
- Observable UI state changes occur on the main actor.
- One Task represents the active generation.
- Sending is disabled while a generation is active, matching current behavior.
- Closing chat cancels the Task before resource cleanup.
- Late responses are ignored after conversation closure.
- Model refreshes are cancellable and cannot overwrite a newer refresh result.
- A short service-detection timeout and a longer generation timeout are separate.
- Provider preference changes apply to the next chat, not midway through an
  active conversation.

## Error handling

Errors are mapped to concise user actions:

- Apple model unavailable: show Apple's availability reason.
- Ollama connection refused: show “Ollama is not running” and Open Ollama.
- No validated local models: ask the user to install a local model in Ollama.
- Selected model removed or changed to remote: clear the selection and require a
  new local model.
- Remote/cloud model detected: refuse it and explain the local-only rule.
- Unsupported or ambiguous Ollama metadata: require an Ollama update.
- Timeout: retain the conversation and allow retry.
- Cancellation: do not append an error bubble.
- Invalid redirect or origin: refuse the request and show a security error.
- Malformed response or non-success status: show a bounded generic error without
  logging the prompt or full response body.

No error path switches to a cloud provider.

## Preferences migration

Existing users keep their Ask enabled state. New keys default to:

- Provider preference: Automatic.
- Ollama model: empty.

An empty model means “selection required,” not “choose the first model.”
Unknown provider values fall back to Automatic. A saved model is treated as an
identifier only and must pass fresh validation before use.

## Testing strategy

Add a DevPortTests test target in apps/mac/Package.swift. Production code uses
dependency injection for Apple availability and Ollama transport so tests do not
require Apple Intelligence, Ollama, internet access, or a downloaded model.

### Resolver tests

- Automatic chooses Apple when Apple is available.
- Automatic does not call Ollama discovery when Apple is available.
- Automatic chooses Ollama when Apple is unavailable and a selected local model
  validates.
- Automatic becomes unavailable when neither provider can run.
- Forced Apple never calls Ollama.
- Forced Ollama uses Ollama even when Apple is available.
- Forced Ollama without a selected local model is unavailable.
- No failure path returns a cloud provider.

### Ollama client tests

- Service detection and version decoding.
- Local model listing through /api/tags.
- Remote models with remote_host or remote_model are filtered.
- Explicit :cloud and -cloud identifiers are filtered.
- Ambiguous entries without local evidence are filtered.
- /api/show revalidation rejects a model that changed after listing.
- Request encoding for /api/chat uses the selected model, sanitized context,
  in-memory history, stream false, and no tools.
- Successful response decoding.
- Structured API error decoding without exposing request content.
- Timeout and cancellation behavior.
- Empty unload request includes keep_alive 0.
- Only the exact loopback origin and allowlisted paths are accepted.
- Same-origin allowed redirects and every non-exact redirect are rejected.
- URLSession persistence features are disabled.

### Sanitizer tests

- Redacts environment assignments, split and joined CLI options, bearer values,
  URL credentials, secret query parameters, and known token prefixes.
- Preserves safe flags, port, PID, executable name, project name, framework, and
  non-secret arguments.
- Is deterministic and idempotent.
- Never places the original secret in an error description.

### UI and preference tests

Where practical with the existing Swift package structure:

- Defaults and migration for provider and model preferences.
- Provider badge labels.
- Setup states for stopped Ollama, no models, remote-only models, and invalid
  saved selection.

### Manual matrix

- Apple Silicon, macOS 26 or later, Apple Intelligence available.
- Apple provider unavailable, Ollama running with a validated local model.
- Forced Ollama on an Apple-capable Mac.
- Ollama stopped.
- Ollama installed but not running.
- No models installed.
- Only cloud/remote Ollama models present.
- Selected model removed between Settings and chat.
- Older SDK that lacks FoundationModels.
- Chat closed during generation.
- App quit during an Ollama chat.
- Network inspection confirms chat traffic is limited to 127.0.0.1:11434.
- Synthetic secret-bearing command arguments are redacted for both providers.

## Documentation

README additions cover:

- Automatic provider order.
- Apple provider's on-device SystemLanguageModel requirement.
- Installing and opening Ollama without automatic downloads.
- Installing and selecting a local model.
- The exclusion of cloud/remote Ollama models.
- Why localhost alone is not proof of local inference.
- Ollama's optional disable_ollama_cloud setting as additional defense in depth.
- In-memory chat history and process-context sanitization.
- Model loading and best-effort unloading.
- Troubleshooting service, model, timeout, and version errors.

The pull request description includes the architecture, privacy boundaries,
screenshots of Settings and both provider badges, automated-test output, and the
manual verification matrix.

## Implementation sequence

1. Add the test target and provider-domain types.
2. Add sanitizer tests and implementation.
3. Add resolver tests and implementation.
4. Isolate the Apple provider behind compile-time and runtime availability.
5. Add Ollama transport tests, strict origin policy, response models, and local
   model validation.
6. Add Ollama conversation behavior and lifecycle cleanup.
7. Refactor the chat modal to the provider-neutral conversation.
8. Add preferences, Settings controls, status states, and provider badges.
9. Update README and pull request documentation.
10. Run automated and manual verification before requesting upstream review.

Each behavior change is implemented test-first.

## Acceptance criteria

- The project compiles with and without an SDK that provides FoundationModels.
- Existing Apple chat remains functional and explicitly uses the on-device
  SystemLanguageModel.
- Automatic, forced Apple, and forced Ollama modes follow the documented matrix.
- Port Radar creates no Ollama request when Automatic selects Apple.
- Ollama requests can target only http://127.0.0.1:11434 and exact allowed API
  paths.
- Remote/cloud/ambiguous Ollama models cannot be selected or prompted.
- No endpoint can download a model or invoke an Ollama web tool.
- Process context is sanitized before both providers receive it.
- Prompts and responses are not persisted or logged by Port Radar.
- Closing chat cancels generation and requests keep_alive 0 for the model used by
  the conversation.
- The Ollama service itself is never terminated by Port Radar.
- Automated tests cover provider resolution, transport restrictions, remote
  model rejection, request lifecycle, and sanitization.
- The upstream pull request contains only the Ollama fallback and supporting
  refactor, tests, settings, and documentation.

## References

- Apple Foundation Models overview:
  https://developer.apple.com/documentation/foundationmodels/
- Apple WWDC25 introduction to the on-device Foundation Models framework:
  https://developer.apple.com/videos/play/wwdc2025/286/
- Ollama local API introduction:
  https://docs.ollama.com/api/introduction
- Ollama model listing:
  https://docs.ollama.com/api/tags
- Ollama chat and keep_alive:
  https://docs.ollama.com/api/chat
- Ollama cloud model behavior and local-only mode:
  https://docs.ollama.com/cloud
- Ollama local privacy and OLLAMA_NO_CLOUD:
  https://docs.ollama.com/faq
- Ollama OpenAPI model metadata:
  https://github.com/ollama/ollama/blob/main/docs/openapi.yaml

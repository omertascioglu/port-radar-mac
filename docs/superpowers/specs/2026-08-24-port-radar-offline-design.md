# Port Radar Offline Design

## Summary

Port Radar Offline is a public, privacy-focused fork of Port Radar. It keeps local port and process inspection, process controls, and on-device process explanations while removing every tunnel and public-sharing capability. The macOS application must not send port metadata, process context, prompts, or model responses outside the Mac.

The GitHub repository remains `port-radar-mac` under the fork owner's account. The distributed application is named **Port Radar Offline** and uses a distinct bundle identifier so it can coexist with the upstream application. Public documentation must describe it as a tunnel-free, offline-focused fork of Port Radar and retain all Apache 2.0 attribution requirements.

## Goals

- Remove Cloudflare, `cloudflared`, tunnel management, public URLs, and sharing UI completely.
- Keep all port, process, prompt, and response data on the Mac.
- Support Apple's on-device Foundation Models provider where available.
- Provide an isolated, local-only Ollama fallback that the application starts and stops itself.
- Stream Ollama responses into the chat UI as they are generated.
- Release model memory and stop the application-managed Ollama service when local-AI UI no longer needs it.
- Make privacy boundaries testable and visible to the user.
- Preserve upstream authorship and Apache 2.0 license and notice obligations.

## Non-goals

- Exposing localhost services to the internet or local network.
- Adding LAN exposure analysis or warnings.
- Downloading Ollama, models, updates, or any other executable or content.
- Supporting remote Ollama hosts, custom endpoints, cloud models, web search, proxies, or redirects.
- Persisting conversations, prompts, responses, or process context.
- Reworking unrelated port scanning and process-control behavior.

## Product and Distribution Identity

- Repository: the GitHub fork may remain `omertascioglu/port-radar-mac`.
- Product name: `Port Radar Offline` in the menu bar, windows, bundle metadata, and release artifacts.
- Bundle identity: a new identifier owned by the fork maintainer; it must not replace the upstream app.
- Attribution: retain `LICENSE`, retain applicable upstream `NOTICE` content, add the fork maintainer's attribution without removing upstream attribution, and add prominent modification notices to changed distributed files as required by Apache 2.0.
- Documentation: link to the upstream repository and use the description “A tunnel-free, offline-focused fork of Port Radar.”

## Architecture

### Local Port and Process Inspection

Existing macOS-local inspection remains the source of listening-port and process information. The application does not connect to monitored ports. Raw process information remains in memory for the UI and is sanitized before entering any model prompt.

### Provider Resolution

The user can choose:

- **Automatic:** use Apple On-Device when available, otherwise Ollama Local.
- **Apple On-Device:** use only Apple's on-device Foundation Models provider and report unavailability without falling through to a cloud service.
- **Ollama Local:** use only the application-managed, cloud-disabled Ollama service.

Provider badges must say `Apple · On-Device` or `Ollama · Local`. The settings and chat UI must also show “Offline — data never leaves this Mac.” No provider may silently fall back to a remote service.

### Application-managed Ollama Service

The application must not send prompts to a pre-existing server on port `11434`. Instead, it locates an already installed Ollama executable and launches a dedicated child service with these boundaries:

- bind only to an explicit `127.0.0.1` address on a dedicated local port;
- set `OLLAMA_NO_CLOUD=1` for the child process;
- reuse the user's existing local model storage without pulling or copying models;
- make all application requests through the hardened loopback transport to the exact endpoint assigned to the child process;
- reject remote hosts, proxy routing, redirects, cookies, authentication challenges, and non-allowlisted API paths;
- reject cloud-designated model names such as `:cloud` as a second line of defense;
- never attach prompts to, or trust, an unknown pre-existing local Ollama service. If the assigned endpoint is already occupied or the spawned process cannot be identified as the ready service, startup fails closed.

The privacy guarantee assumes the installed Ollama executable is authentic and honors its documented local-only mode. The application itself never makes a non-loopback model request.

The child service may run temporarily while the Local AI settings screen discovers models or while a chat is open. It must not be retained as an idle optimization. Closing the last owning screen cancels active generation, asks Ollama to unload the model, waits for cleanup within a bounded shutdown period, and terminates the child service. Concurrent opens and closes use reference-counted ownership so one screen cannot stop a service still used by another.

Normal termination must perform the same cleanup. If the app exits unexpectedly, a cloud-disabled orphan cannot send prompt data to Ollama Cloud; on the next launch, the app may clean up only a process it can identify as its own. It must never terminate or connect to an unrelated local service.

### Streaming Conversation

The provider-neutral conversation interface delivers incremental text updates plus a final completion or bounded error. Ollama uses its newline-delimited streaming chat response, and the chat UI renders chunks as they arrive.

There is no five-second generation deadline. Connection establishment and malformed or stalled transport conditions remain bounded, but a healthy model may continue generating without a fixed total response deadline. The user always has a visible **Stop** action.

When stopped or closed:

1. mark the conversation closed so late chunks cannot mutate UI state;
2. cancel the active request;
3. ask the provider to close and unload immediately;
4. wait for in-flight work to unwind;
5. release conversation memory and service ownership.

If streaming fails after text has arrived, retain the partial response and show a local, bounded error. Apple responses use native incremental delivery when the available framework API supports it; otherwise the shared streaming interface emits one final chunk.

## Data Handling and Network Boundary

- Raw port and process data is kept in memory and is never persisted.
- The existing fail-closed sanitizer removes credentials from model context before either provider receives it.
- Prompts, responses, and chat history remain in memory only and are discarded on close.
- User preferences may persist only provider choice and selected local model identifier; they must not contain process or chat data.
- Ollama communication is restricted to the exact application-owned loopback origin and an explicit API-path allowlist.
- There are no tunnel endpoints, analytics, telemetry, update checks, web search, automatic downloads, or in-app external links.
- The source repository and README may contain normal attribution and documentation links; this does not change the runtime network boundary of the macOS app.

## User Interface

Remove all Share actions, tunnel lists, tunnel status, public URL presentation, and Cloudflare setup or error states. The remaining product focuses on Scan, Ask, and Stop.

Local AI settings provide:

- Automatic, Apple On-Device, and Ollama Local provider choices;
- locally discovered model selection;
- service/model readiness status;
- clear offline privacy copy;
- non-clickable guidance when Ollama or a local model is missing.

The application does not download Ollama or open a download page. Chat shows incremental assistant text, a Stop action while generating, provider identity, and concise recovery guidance for local failures.

## Error Handling

User-facing errors distinguish:

- Ollama is not installed;
- no compatible local model is available;
- the private Ollama service could not start;
- the local service could not be reached;
- the model or stream returned malformed data;
- generation failed after a partial response;
- the user canceled generation.

Slow generation is not itself an error. Error text must be bounded, must not include raw server bodies or process context, and must not be logged with prompts or responses.

## Removal Scope

Delete Cloudflare bootstrap/download code, tunnel process management, tunnel models and state, tunnel and Share views, public URL flows, related tests, documentation, assets, and permissions. Remove dead state and navigation left behind by those deletions. Do not leave disabled or hidden tunnel code in the shipping target.

## Verification

Automated verification must include:

- complete unit and integration test suites;
- debug and release builds;
- streaming parsing, partial delivery, cancellation, malformed chunks, and mid-stream failures;
- no five-second generation timeout regression;
- child-service launch environment, ownership, reference counting, unload, termination, and late-result races;
- refusal of `:cloud` models and unknown or pre-existing Ollama services;
- exact loopback origin and API allowlist enforcement;
- redirect, proxy, cookie, authentication, cache, and non-loopback rejection;
- sanitizer coverage and proof that process/chat data is not persisted or logged;
- static scans proving Cloudflare, `cloudflared`, tunnel, public URL, and forbidden endpoint code is absent from the shipping application;
- license, notice, modification notice, bundle identity, and product-name checks.

Before publishing, perform a user-operated manual run with an installed local model covering cold start, long first response, visible streaming, Stop, chat close, model unload, and relaunch. Observe network traffic during the run and verify that Port Radar Offline and its managed Ollama process create no non-loopback connection. Record the environment and results honestly; do not mark unperformed checks as passing.

## Publication Sequence

1. Build and test locally without launching external services automatically during automated checks.
2. Give the fork owner a local `.app` package and manual privacy test checklist.
3. Fix any failures and repeat automated and manual verification.
4. Create the public GitHub fork under `omertascioglu` and push the reviewed branch only after the user approves.
5. Publish release notes that separate upstream capabilities from the fork's tunnel removal, isolated Ollama service, streaming chat, lifecycle cleanup, and privacy hardening.

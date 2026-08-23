# Local AI Manual Test Matrix

This matrix records manual checks only. Automated unit and build evidence belongs in the
verification report. `PASS` and `FAIL` are used only for scenarios that were actually run;
unavailable environments and unperformed UI or network checks remain `NOT RUN`.

## Run metadata

| Field | Recorded value |
| --- | --- |
| Date | 2026-08-23 |
| Machine | Apple Silicon (`arm64`), sandboxed development environment |
| macOS | 15.5 (24F74) |
| Xcode | 16.4 (16F6) |
| Ollama version | NOT RUN — not queried |
| Selected local model | NOT RUN — no model queried or selected |

The macOS 26 SDK and Apple Intelligence hardware/runtime path are unavailable in this
environment. Ollama was not contacted, opened, installed, started, stopped, or given a model.
No app UI, proxy capture, public tunnel, or model request was run from the sandbox.

## Checklist

- [ ] **NOT RUN** — Apple available on macOS 26 or later. The current SDK is macOS 15.5 and
  cannot exercise the Foundation Models branch.
- [ ] **NOT RUN** — Apple unavailable plus a validated local Ollama model. Ollama was not
  contacted and no model was selected.
- [ ] **NOT RUN** — Forced Ollama on an Apple-capable Mac. The required Apple runtime and
  Ollama model were unavailable.
- [ ] **NOT RUN** — Ollama service stopped. The service state was not queried or changed.
- [ ] **NOT RUN** — Ollama application not installed. Installed applications were not inspected
  and no application was opened.
- [ ] **NOT RUN** — Ollama running with no local models. Model inventory was not queried.
- [ ] **NOT RUN** — Ollama with remote-only models. Model inventory was not queried.
- [ ] **NOT RUN** — Selected model removed between Settings and chat. No UI or model inventory
  was used.
- [ ] **NOT RUN** — Chat closed during generation. No live model generation was started.
- [ ] **NOT RUN** — App quit during generation. No app UI or live generation was started.
- [ ] **NOT RUN** — Synthetic command secrets absent from provider requests. This remains a
  manual request-inspection check; automated sanitizer and request-capture tests are separate.
- [ ] **NOT RUN** — Proxy or network inspection shows chat requests only to
  `127.0.0.1:11434`. No network capture or Ollama request was performed.
- [ ] **NOT RUN** — Cloudflare sharing still functions. No public tunnel was created.
- [ ] **NOT RUN** — Cloudflare Share remains visibly separate from Ask privacy messaging. The
  app UI was not launched for visual inspection.

Do not record real prompts, usernames, filesystem locations, project names, commands, tokens,
or screenshots in future runs. Use synthetic fixtures and inspect every screenshot for private
data before attaching it to a review.

## Apache 2.0 section 4(b) modification-notice audit

Comparison against `origin/main` identified these pre-existing, still-distributed files as
modified by the contribution. Each carries the same top-of-file modification notice:

- `README.md`
- `apps/mac/README.md`
- `apps/mac/Package.swift`
- `apps/mac/Sources/DevPort/DevPortApp.swift`
- `apps/mac/Sources/DevPort/Models/DevServer.swift`
- `apps/mac/Sources/DevPort/State/Preferences.swift`
- `apps/mac/Sources/DevPort/Views/AgentChatView.swift`
- `apps/mac/Sources/DevPort/Views/ContentView.swift`
- `apps/mac/Sources/DevPort/Views/SettingsView.swift`

`apps/mac/Sources/DevPort/Actions/ProcessAgent.swift` was removed and is not part of the
distributed result, so it cannot carry a notice. Files created entirely by this contribution
are not described as modified upstream originals. `LICENSE` and `NOTICE` remain unchanged.

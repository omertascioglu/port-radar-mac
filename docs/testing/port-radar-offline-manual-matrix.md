# Port Radar Offline Manual Test Matrix

This matrix records manual checks only. Automated unit and build evidence belongs in the
verification report. `PASS` and `FAIL` are used only for scenarios that were actually run;
unavailable environments and unperformed UI or network checks remain `NOT RUN`.

## Run metadata

| Field | Recorded value |
| --- | --- |
| Date | 2026-08-26 |
| Machine | Apple Silicon (`arm64`), sandboxed development environment |
| macOS | 15.5 (24F74) |
| Xcode | 16.4 (16F6) |
| Ollama version | NOT RUN — not queried |
| Selected local model | NOT RUN — no model queried or selected |

The macOS 26 SDK and the Apple Intelligence hardware/runtime path are unavailable in this
environment. Ollama was not contacted, installed, started, stopped, or given a model, and the
app's private local service was never launched. No app UI, network capture, or model request was
run from the sandbox, so every item below is `NOT RUN`.

## Product surface

- [ ] **NOT RUN** — The menu bar panel offers Scan, Ask, and Stop only, with no sharing entry
  point anywhere in the row menu, footer, or Settings. The app UI was not launched.
- [ ] **NOT RUN** — The app identifies itself as Port Radar Offline in the menu bar title, the
  quit item, and the quit confirmation. The app UI was not launched.

## Providers

- [ ] **NOT RUN** — Apple on-device model available on macOS 26 or later. The current SDK is
  macOS 15.5 and cannot exercise the Foundation Models branch.
- [ ] **NOT RUN** — Apple unavailable plus a validated local Ollama model under **Automatic**.
  Ollama was not contacted and no model was selected.
- [ ] **NOT RUN** — Forced **Ollama** on an Apple-capable Mac. The required Apple runtime and a
  local model were unavailable.
- [ ] **NOT RUN** — Forced **Apple Intelligence** reports the platform reason instead of falling
  back. The Apple runtime was unavailable.

## Private local Ollama service

- [ ] **NOT RUN** — The service the app starts listens on `127.0.0.1:11435`, runs with
  `OLLAMA_NO_CLOUD=1`, and is a child of the app. No process was launched or inspected.
- [ ] **NOT RUN** — A separately running Ollama app on the default port is left untouched. No
  service state was queried or changed.
- [ ] **NOT RUN** — The service stops when the last lease is released, and does not linger after
  chat closes. No lease was acquired.
- [ ] **NOT RUN** — Proxy or network inspection shows requests only to `127.0.0.1:11435` and
  only to `/api/version`, `/api/tags`, `/api/show`, and `/api/chat`. No network capture was
  performed.
- [ ] **NOT RUN** — A redirect off the private endpoint is refused with the local-only boundary
  error. No live redirect was produced.

## Settings

- [ ] **NOT RUN** — Nothing checks Ollama until **Check local models** is pressed. The app UI
  was not launched.
- [ ] **NOT RUN** — With Ollama absent, Settings shows
  `Ollama is not installed. Install it separately, then try again.` and offers no clickable
  install or download affordance. Installed applications were not inspected.
- [ ] **NOT RUN** — With Ollama present and no local models, Settings shows non-clickable
  guidance to install a model outside Port Radar Offline. Model inventory was not queried.
- [ ] **NOT RUN** — Before any check, the model row reports the persisted model Ask would use.
  The app UI was not launched.
- [ ] **NOT RUN** — Remote-only, cloud, and metadata-ambiguous models never appear in the
  picker. Model inventory was not queried.
- [ ] **NOT RUN** — Closing Settings or hiding the Ollama controls cancels an in-flight check and
  releases its lease. No check was started.

## Chat

- [ ] **NOT RUN** — The reply streams in token by token and the Stop control ends it while
  keeping the partial text. No live generation was started.
- [ ] **NOT RUN** — The chat footer reads `Offline — data never leaves this Mac.` The app UI was
  not launched.
- [ ] **NOT RUN** — Synthetic command secrets are absent from provider requests. This remains a
  manual request-inspection check; automated sanitizer and request-capture tests are separate.
- [ ] **NOT RUN** — Selected model removed between Settings and chat is reported, not guessed.
  No UI or model inventory was used.
- [ ] **NOT RUN** — Closing chat during generation cancels it, unloads the model with
  `keep_alive: 0`, and releases the lease. No live generation was started.

## Exit

- [ ] **NOT RUN** — Quitting during generation closes the conversation first, then stops the
  private service, then exits. No app UI or live generation was started.
- [ ] **NOT RUN** — No `ollama serve` child process survives app exit. No process was launched
  or inspected.

## Website and documentation

- [ ] **NOT RUN** — The landing page renders the offline streaming Ask state and no sharing
  copy in a real browser. Only `npm run lint` and `npm run build` were run; no page was opened.
- [ ] **NOT RUN** — The press gallery routes render at 1270×760 for screenshots. No route was
  opened or captured.
- [ ] **NOT RUN** — The download button resolves to a published
  `Port-Radar-Offline.dmg`. No release exists yet and no network request was made.

Do not record real prompts, usernames, filesystem locations, project names, commands, tokens,
or screenshots in future runs. Use synthetic fixtures and inspect every screenshot for private
data before attaching it to a review.

## Apache 2.0 section 4(b) modification-notice audit

`git diff --name-only --diff-filter=M origin/main` identifies these pre-existing,
still-distributed files as modified. Each carries a modification notice as its first line,
except `apps/mac/Package.swift` and `apps/mac/Support/Info.plist`, where the notice sits
immediately after the line the file format requires first (`swift-tools-version` and the XML
declaration):

- `README.md`
- `apps/mac/Makefile`
- `apps/mac/Package.swift`
- `apps/mac/README.md`
- `apps/mac/Sources/DevPort/Actions/LaunchAtLogin.swift`
- `apps/mac/Sources/DevPort/DevPortApp.swift`
- `apps/mac/Sources/DevPort/Models/DevServer.swift`
- `apps/mac/Sources/DevPort/Scanner/PortScanner.swift`
- `apps/mac/Sources/DevPort/State/AppState.swift`
- `apps/mac/Sources/DevPort/State/Preferences.swift`
- `apps/mac/Sources/DevPort/Views/AgentChatView.swift`
- `apps/mac/Sources/DevPort/Views/ContentView.swift`
- `apps/mac/Sources/DevPort/Views/SettingsView.swift`
- `apps/mac/Support/Info.plist`
- `apps/mac/Support/release-notes.md`
- `apps/web/README.md`
- `apps/web/src/app/globals.css`
- `apps/web/src/app/layout.tsx`
- `apps/web/src/app/page.tsx`
- `apps/web/src/app/press/gallery/[slide]/page.tsx`
- `apps/web/src/components/AppDemo.tsx`
- `apps/web/src/components/PressPanel.tsx`
- `apps/web/src/components/Reveal.tsx`
- `apps/web/src/lib/site.ts`

`NOTICE` is also modified: the upstream attribution is retained verbatim and the fork's
attribution is appended below it, which is the notice itself rather than a file comment.

Files removed by this fork are not part of the distributed result, so they cannot carry a
notice. Files created entirely by this fork are not described as modified upstream originals.
`LICENSE` is unchanged, verified with `git diff --exit-code origin/main -- LICENSE`.

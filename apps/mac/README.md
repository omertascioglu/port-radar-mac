<!-- Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork. -->

<p align="center">
  <img src="Support/AppIcon.png" alt="Port Radar Offline" width="128" height="128">
</p>

# Port Radar Offline (macOS)

A native macOS menu-bar app that detects dev servers listening on localhost — Vite, Next.js, Python, Docker, and anything else bound to a TCP port — and lets you inspect and stop them without hunting through terminals.

Swift + SwiftUI (`MenuBarExtra`), macOS 14+. No Xcode project: built with Swift Package Manager and edited in any editor. Xcode is required only for its toolchain.

The app has three actions: **Scan**, **Ask**, and **Stop**. It has no sharing feature and opens no public address.

## Ask: Apple on-device model or a local Ollama model

Ask is provider-neutral and never leaves the Mac. In **Automatic** mode the app uses Apple's
on-device `SystemLanguageModel` when it is available. That path requires macOS 26 or later,
supported Apple hardware, and Apple Intelligence to be enabled and ready. If Apple is
unavailable, Automatic falls back to the already-selected, validated local Ollama model.
Selecting **Apple Intelligence** or **Ollama** in Settings forces that provider instead. Apple
documents the on-device framework in its
[Foundation Models overview](https://developer.apple.com/documentation/foundationmodels/).

Answers stream in token by token. **Stop** ends the response immediately and keeps whatever text
already arrived.

### The private local Ollama service

Ollama work runs against a service the app owns, not the Ollama menu-bar app:

- The app launches `ollama serve` as its own child process with `OLLAMA_HOST=127.0.0.1:11435`
  and `OLLAMA_NO_CLOUD=1`, inheriting only `PATH`, `HOME`, `TMPDIR`, the locale variables, and
  `OLLAMA_MODELS`.
- Requests go only to `http://127.0.0.1:11435` and only to `/api/version`, `/api/tags`,
  `/api/show`, and `/api/chat`. No tools are supplied. A redirect off that host, port, or path
  set fails the request with `Ollama redirected outside Port Radar Offline's local-only boundary.`
- Every consumer holds a lease on the service. The service starts on the first lease and stops
  when the last one is released, so it is not left running in the background.
- Ollama documents its [local API](https://docs.ollama.com/api/introduction),
  [model metadata](https://docs.ollama.com/api/tags), and
  [cloud behavior](https://docs.ollama.com/cloud); `OLLAMA_NO_CLOUD` is described in the
  [Ollama FAQ](https://docs.ollama.com/faq).

### What the app never does

It never installs, updates, downloads, launches, or pulls anything, and it never opens the
Ollama app or a download page. Settings has one Ollama control — **Check local models** — and
it only runs when pressed. If Ollama is not installed you get
`Ollama is not installed. Install it separately, then try again.` If it is installed but has no
local models, Settings shows non-clickable guidance: install a local model with Ollama outside
Port Radar Offline, then check again.

### Local-model validation

Settings lists only models that the private service reports as installed and for which the
metadata provides positive local-storage evidence. Cloud, remote, and ambiguous models are
rejected even though the API is reached at `127.0.0.1`, because a local address alone does not
prove where inference runs. The selected model is validated again immediately before chat, and a
saved selection is cleared when it no longer validates.

### Privacy and lifecycle

The process snapshot is sanitized before either provider receives it: likely tokens, passwords,
authorization values, URL credentials, and similar secrets are replaced with `[REDACTED]`.
Process context, prompts, and answers stay in memory; the app persists only the Ask toggle, the
provider preference, and the selected model identifier. Ollama loads the selected model on the
first prompt. Closing chat cancels generation, asks Ollama to unload the model with
`keep_alive: 0`, and releases the lease. On quit the app closes the active conversation — so it
unloads and releases first — and then shuts the private service down before exiting.

### Set up the optional Ollama path

1. Install Ollama yourself from the official Ollama macOS download page. Port Radar Offline
   never installs or updates it.
2. In Ollama, explicitly install or pull a model that runs locally. Port Radar Offline never
   chooses or pulls a model for you.
3. In Settings, enable Ask, choose **Automatic** or **Ollama**, press **Check local models**,
   then pick a model that passes validation.

Nothing else is required: the app starts its own service when Ask needs one, so the Ollama
menu-bar app does not have to be running.

### Ollama troubleshooting

- **`Ollama is not installed. Install it separately, then try again.`** Install Ollama from its
  official macOS download page, then press **Check local models** again.
- **`Unable to start the private local Ollama service.`** The child process could not launch or
  become ready. Confirm the `ollama` executable is intact, free local resources, and retry.
- **No local models appear:** install or pull a local model explicitly in Ollama, then check
  again. Remote-only, cloud, and metadata-ambiguous models are intentionally excluded; do not
  bypass the local-model validation.
- **The selected model was removed or is unavailable:** restore that model locally or choose
  another installed model that passes validation.
- **A request times out:** confirm the machine is not saturated and retry. You may choose
  another already-installed validated local model; the app never switches models or providers
  silently.
- **Version or metadata compatibility error:** update Ollama through its official macOS release
  and check again. Responses that do not provide enough evidence of local storage are rejected
  instead of guessed safe.

## Build & run

From this directory (`apps/mac`):

```bash
make run      # build, assemble Port Radar Offline.app, launch
make build    # compile only (swift build -c release)
make bundle   # build + assemble Port Radar Offline.app without launching
make dmg      # package a drag-to-Applications installer into dist/
make clean    # remove .build/, the app bundle, dist/
```

Or from the repo root: `make run` (delegates here).

The Makefile wraps the compiled binary into a proper `.app` bundle because two things require one: user notifications (need a bundle identifier) and `LSUIElement` (menu-bar only, no Dock icon). The SPM executable stays `DevPort`; the bundle is `Port Radar Offline` with the bundle identifier `com.omertascioglu.PortRadarOffline`, so it can coexist with the upstream app.

## Quick test

With the app running, start a throwaway listener in another terminal:

```bash
python3 -m http.server 8128
```

It should appear in the menu bar within a few seconds as a Python row on `localhost:8128`. Use Stop there to exercise kill, or `Ctrl+C` in the terminal. The app itself does not listen on a port, so it will not show up in its own list. The private Ollama service listens on `127.0.0.1:11435` only while Ask holds a lease.

## How it works

- **Scan** — polls `lsof -iTCP -sTCP:LISTEN -P -n` every ~2.5 s and diffs snapshots of `(port, pid)`.
- **Resolve** — enriches each PID via native APIs: `proc_pidpath` (executable), `KERN_PROCARGS2` (full argv), `kinfo_proc` (parent PID, start time), `PROC_PIDVNODEPATHINFO` (working directory).
- **Stop** — SIGTERM with automatic escalation to SIGKILL after 4 s, or immediate SIGKILL. Confirmation required.

No root, ever. Without elevated privileges the app only sees and signals processes owned by the current user — which is exactly where dev servers live.

## Source layout

```
Sources/DevPort/
  Scanner/          lsof polling loop, snapshot diffing
  ProcessResolver/  PID → executable, argv, cwd, parent
  Models/           DevServer value types
  State/            @Observable app store
  Views/            MenuBarExtra window UI
  Actions/          terminate / force-kill / open helpers
  AI/               providers, private Ollama service, sanitizer
Support/Info.plist  bundle config (LSUIElement, bundle id)
```

## Distribution

`make dmg` produces `dist/Port-Radar-Offline-<version>.dmg` plus a stable
`dist/Port-Radar-Offline.dmg` for the site's download button. `make publish` uploads that asset
to this fork's [Releases](https://github.com/omertascioglu/port-radar-mac/releases/latest).

Not on the Mac App Store: the mandatory App Sandbox forbids inspecting or signaling other
processes, which is this app's core function.

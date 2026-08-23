<!-- Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution. -->

<p align="center">
  <img src="Support/AppIcon.png" alt="Port Radar" width="128" height="128">
</p>

# Port Radar (macOS)

A native macOS menu-bar app that detects dev servers listening on localhost — Vite, Next.js, Python, Docker, and anything else bound to a TCP port — and lets you inspect and kill them without hunting through terminals.

Swift + SwiftUI (`MenuBarExtra`), macOS 14+. No Xcode project: built with Swift Package Manager and edited in any editor. Xcode is required only for its toolchain.

## Ask: Apple on-device model with local Ollama fallback

Ask is provider-neutral and stays local. In **Automatic** mode, Port Radar uses Apple's
on-device `SystemLanguageModel` when it is available. That path requires macOS 26 or later,
supported Apple hardware, and Apple Intelligence to be enabled and ready. If Apple is
unavailable, Automatic can fall back to the already-selected, validated local Ollama model.
Selecting Apple Intelligence or Ollama in Settings forces that provider instead. Apple documents
the on-device framework in its [Foundation Models overview](https://developer.apple.com/documentation/foundationmodels/).

Ollama is optional. Port Radar never installs it, starts it without the user pressing **Open
Ollama**, or pulls a model. Settings lists only models that Ollama reports as already installed
and for which the model metadata provides positive local-storage evidence. The selected model is
checked again immediately before chat. Remote, cloud, and ambiguous models are rejected even if
the Ollama API is reached at localhost, because localhost alone does not prove where inference
runs. Ollama documents its [local API](https://docs.ollama.com/api/introduction),
[model metadata](https://docs.ollama.com/api/tags), and [cloud behavior](https://docs.ollama.com/cloud).

Port Radar sends Ollama requests only to `http://127.0.0.1:11434` and only to the version, tags,
show, and chat API paths. It supplies no tools. As additional defense in depth, enable Ollama's
`disable_ollama_cloud` / `OLLAMA_NO_CLOUD` local-only setting described in the
[Ollama FAQ](https://docs.ollama.com/faq).

The process snapshot is sanitized before either provider receives it: likely tokens, passwords,
authorization values, URL credentials, and similar secrets are replaced with `[REDACTED]`.
Port Radar keeps process context, prompts, and answers in memory only; it persists only the Ask
toggle, provider preference, and selected model identifier. Ollama loads the selected model on
the first prompt. Closing chat cancels active generation and asks Ollama to unload that model
with `keep_alive: 0`; app-quit cleanup makes the same best-effort request, but immediate unload
cannot be guaranteed if the app or Ollama exits first. Port Radar never stops the Ollama service.

This privacy boundary applies to **Ask**. The separate, user-triggered **Share** action deliberately
creates a public Cloudflare tunnel for the selected localhost port.

### Set up the optional Ollama fallback

1. Install Ollama yourself from the
   [official macOS download](https://ollama.com/download/mac). Port Radar never installs or
   updates Ollama.
2. In Ollama, explicitly install or pull a model that runs locally. Port Radar never chooses or
   pulls a model for you.
3. Start Ollama yourself, or press **Open Ollama** in Port Radar Settings. That button is an
   explicit user action; Port Radar does not start Ollama silently.
4. In Port Radar Settings, enable Ask, choose **Automatic** or **Ollama**, then choose an installed
   model that passes Port Radar's local-metadata checks. Automatic uses it only when Apple's
   on-device model is unavailable; Ollama forces the selected local model.

### Ollama troubleshooting

- **Ollama is not running:** Start the installed Ollama app, or press **Open Ollama**, then try
  Settings again. If Port Radar reports that the app was not found, install it from Ollama's
  [official macOS download](https://ollama.com/download/mac).
- **No local models appear:** Install or pull a local model explicitly in Ollama, then reopen
  Settings. Remote-only, cloud, and metadata-ambiguous models are intentionally excluded; do not
  bypass Port Radar's local-model validation.
- **The selected model was removed or is unavailable:** Restore that model locally or choose
  another installed model that passes validation. Port Radar clears a saved selection when the
  model no longer validates.
- **A request times out:** Confirm the local Ollama service is responsive, reduce competing local
  load, and retry. You may choose another already-installed validated local model; Port Radar
  never switches models or providers silently.
- **Version or metadata compatibility error:** Update Ollama through its official macOS release
  and refresh Settings. Older responses that do not provide enough evidence of local storage are
  rejected instead of guessed safe. As defense in depth, keep Ollama's `disable_ollama_cloud` /
  `OLLAMA_NO_CLOUD` local-only setting enabled as described in the
  [Ollama FAQ](https://docs.ollama.com/faq); this supplements rather than replaces Port Radar's
  validation.

## Build & run

From this directory (`apps/mac`):

```bash
make run      # build, assemble Port Radar.app, launch
make build    # compile only (swift build -c release)
make bundle   # build + assemble Port Radar.app without launching
make dmg      # package a drag-to-Applications installer into dist/
make clean    # remove .build/, Port Radar.app, dist/
```

Or from the repo root: `make run` (delegates here).

The Makefile wraps the compiled binary into a proper `.app` bundle because two things require one: user notifications (need a bundle identifier) and `LSUIElement` (menu-bar only, no Dock icon).

## Quick test

With Port Radar running, start a throwaway listener in another terminal:

```bash
python3 -m http.server 8128
```

It should appear in the menu bar within a few seconds as a Python row on `localhost:8128`. Use Stop there to exercise kill, or `Ctrl+C` in the terminal. Port Radar itself does not listen on a port, so it will not show up in its own list.

## How it works

- **Scan** — polls `lsof -iTCP -sTCP:LISTEN -P -n` every ~2.5 s and diffs snapshots of `(port, pid)`.
- **Resolve** — enriches each PID via native APIs: `proc_pidpath` (executable), `KERN_PROCARGS2` (full argv), `kinfo_proc` (parent PID, start time), `PROC_PIDVNODEPATHINFO` (working directory).
- **Kill** — SIGTERM with automatic escalation to SIGKILL after 4 s, or immediate SIGKILL. Confirmation required.

No root, ever. Without elevated privileges the app only sees and signals processes owned by the current user — which is exactly where dev servers live.

## Source layout

```
Sources/DevPort/
  Scanner/          lsof polling loop, snapshot diffing
  ProcessResolver/  PID → executable, argv, cwd, parent
  Models/           DevServer value types
  State/            @Observable app store
  Views/            MenuBarExtra window UI
  Actions/          terminate / force-kill / tunnels / agent
Support/Info.plist  bundle config (LSUIElement, bundle id)
```

## Distribution

Shipped as a DMG on [Releases](https://github.com/juansebsol/port-radar-mac/releases/latest).
`make dmg` produces the same installer locally.

Not on the Mac App Store: the mandatory App Sandbox forbids inspecting or signaling other
processes, which is this app's core function.

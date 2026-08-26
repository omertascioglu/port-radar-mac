<!-- Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution, and for the Port Radar Offline fork. -->

<p align="center">
  <img src="apps/mac/Support/AppIcon.png" alt="Port Radar Offline" width="128" height="128">
</p>

<h1 align="center">Port Radar Offline</h1>

<p align="center">
  A tunnel-free, offline-focused fork of Port Radar. Every port your Mac is running — named,
  explained, stopped. Nothing leaves the machine.
</p>

---

Port Radar Offline is a native macOS menu-bar app that lists every process listening on
localhost, grouped by project. Ask an on-device Apple model or a local Ollama model what a
process is and whether it's safe to stop, then stop it. There is no sharing feature: the app
publishes nothing and exposes no local port to the internet.

- **Scan** — every listening TCP port, refreshed continuously, grouped by project
- **Ask** — Apple's on-device model when available, or a local Ollama model you already
  installed; answers stream in and can be stopped mid-response
- **Stop** — graceful SIGTERM with escalation to SIGKILL, or force quit, always confirmed

macOS 14+. Apple's model requires macOS 26+, supported hardware, and Apple Intelligence.
Ollama is optional and must be installed by you.

## Offline by design

The chat footer says exactly what the app does: `Offline — data never leaves this Mac.`

**Apple on-device.** With **Automatic**, Ask tries Apple's on-device `SystemLanguageModel`
first. Choosing **Apple Intelligence** or **Ollama** in Settings forces that provider. See
Apple's [Foundation Models documentation](https://developer.apple.com/documentation/foundationmodels/)
for the platform requirements.

**A private local Ollama service.** When Ask needs Ollama, Port Radar Offline starts its own
`ollama serve` child process bound to `127.0.0.1:11435` with `OLLAMA_NO_CLOUD=1` and a
scrubbed environment, and talks to it over a lease-bound transport that permits only
`/api/version`, `/api/tags`, `/api/show`, and `/api/chat` on that address. It supplies no
tools. Any redirect outside that boundary fails the request. The service is a child of the
app, not the Ollama menu-bar app, so it is not shared with anything else on the Mac.

**You install Ollama and its models.** The app never installs, updates, downloads, opens, or
pulls anything. Settings only checks for local models when you press the button, and when it
finds none it prints guidance instead of a link: install a model with Ollama outside Port
Radar Offline, then check again. If Ollama is missing you get
`Ollama is not installed. Install it separately, then try again.` — nothing is fetched for you.

**Only local models.** The picker lists only models whose metadata proves local storage. Cloud,
remote, and metadata-ambiguous models are rejected, and the selected model is validated again
immediately before a chat starts.

**Secrets are removed before the model sees anything.** The process snapshot is sanitized —
likely tokens, passwords, authorization values, and URL credentials become `[REDACTED]` —
before either provider receives it.

**Nothing is written down.** Prompts, answers, and process context live in memory only. The app
persists just the Ask toggle, the provider preference, and the selected model identifier.

**Cleanup is ordered.** Closing chat cancels generation, asks Ollama to unload the model with
`keep_alive: 0`, and releases the service lease; the private service stops when the last lease
goes away. On quit the app closes the active conversation first, then shuts the private service
down, then exits.

## Download

Releases live at
[Releases](https://github.com/omertascioglu/port-radar-mac/releases/latest); the published
asset is
[`Port-Radar-Offline.dmg`](https://github.com/omertascioglu/port-radar-mac/releases/latest/download/Port-Radar-Offline.dmg).
Until this fork publishes one, build the disk image yourself with `make dmg`. Builds are not
notarized yet, so first launch needs **System Settings → Privacy & Security → Open Anyway**.

## Build from source

No third-party dependencies; you need the Swift toolchain that ships with Xcode.

```bash
make run      # build, assemble Port Radar Offline.app, launch
make build    # compile only
make bundle   # build + assemble without launching
make dmg      # package a drag-to-Applications installer
make clean
```

## How it works

- Polls `lsof -iTCP -sTCP:LISTEN -P -n` and diffs snapshots of `(port, pid)`
- Enriches each PID via native APIs: `proc_pidpath`, `KERN_PROCARGS2`, `kinfo_proc`,
  `PROC_PIDVNODEPATHINFO`
- Never runs as root — it only sees and signals processes owned by the current user, which is
  exactly where dev servers live

Not on the Mac App Store: the mandatory App Sandbox forbids inspecting or signaling other
processes, which is the entire point of the app.

## Repo layout

```
apps/mac/     Native SwiftUI menu-bar app
apps/web/     Next.js landing page
```

More detail in [`apps/mac/README.md`](apps/mac/README.md) and
[`apps/web/README.md`](apps/web/README.md).

## Upstream

Port Radar Offline is a fork of [Port Radar](https://github.com/juansebsol/port-radar-mac) by
Juan Sebastian Solano. The fork removes the upstream sharing feature, adds the private local
Ollama service, and ships under its own name and bundle identifier so both apps can coexist.
Upstream releases, listings, and support channels are not this fork's.

## License

[Apache License 2.0](LICENSE) — free to use, modify, and distribute, including commercially.
If you redistribute this app or build on it, keep the copyright notices, ship a copy of
[`NOTICE`](NOTICE) with it, and mark any files you changed.

Copyright 2026 Juan Sebastian Solano. Port Radar Offline modifications copyright 2026
Ömer Taşçıoğlu.

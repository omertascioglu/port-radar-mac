<!-- Modification notice: Changed in 2026 for the local AI and optional Ollama fallback contribution. -->

<p align="center">
  <img src="apps/mac/Support/AppIcon.png" alt="Port Radar" width="128" height="128">
</p>

<h1 align="center">Port Radar</h1>

<p align="center">
  The AI port manager for Mac. Every port your Mac is running — named, explained, stopped in one click.
</p>

---

Port Radar is a native macOS menu-bar app that lists every process listening on localhost,
grouped by project. Ask an on-device Apple model or an optional verified local Ollama model
what a process is and whether it's safe to stop. Share any local app as a live public URL with
a one-click Cloudflare tunnel.

- **Scan** — every listening TCP port, refreshed continuously, grouped by project
- **Ask** — uses Apple's on-device model when available, with an optional local Ollama fallback
  for unsupported or user-selected configurations
- **Stop** — graceful SIGTERM with escalation, or force quit, always confirmed
- **Share** — one-click Cloudflare quick tunnel, no account or CLI setup

macOS 14+. Apple's model requires macOS 26+, supported hardware, and Apple Intelligence;
Ollama is an optional local fallback on supported Port Radar systems.

## Local AI and privacy

**Automatic** tries Apple's on-device `SystemLanguageModel` first. If it is unavailable, Port
Radar can use the local Ollama model you selected; choosing Apple or Ollama in Settings forces
that provider. See Apple's [Foundation Models documentation](https://developer.apple.com/documentation/foundationmodels/)
for the Apple model's platform requirements.

Ollama support is opt-in. Port Radar never installs Ollama, opens it without an explicit user
action, or pulls a model. The picker shows only models already installed and supported by
metadata that proves local storage. Remote, cloud, and ambiguous models are excluded—even when
an Ollama service exposes them through localhost. For defense in depth, enable Ollama's
`disable_ollama_cloud` / `OLLAMA_NO_CLOUD` local-only setting; see Ollama's
[cloud](https://docs.ollama.com/cloud) and [privacy FAQ](https://docs.ollama.com/faq).

Before either provider sees process context, Port Radar replaces likely secrets with
`[REDACTED]`. Port Radar keeps prompts and answers only in memory. An Ollama model loads on the
first prompt; closing chat asks Ollama to unload that model immediately, on a best-effort basis.
The local-only promise applies to **Ask**. **Share** is a separate, explicit action that publishes
the selected localhost port through Cloudflare.

## Download

Grab the latest DMG from [Releases](https://github.com/juansebsol/port-radar-mac/releases/latest),
open it, and drag Port Radar to Applications. First-launch instructions are on the release page.

## Build from source

No third-party dependencies; you need the Swift toolchain that ships with Xcode.

```bash
make run      # build, assemble Port Radar.app, launch
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

## License

[Apache License 2.0](LICENSE) — free to use, modify, and distribute, including commercially.
If you redistribute Port Radar or build on it, keep the copyright notice and ship a copy of
[`NOTICE`](NOTICE) with it, and mark any files you changed.

Copyright 2026 Juan Sebastian Solano.

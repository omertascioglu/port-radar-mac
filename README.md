<p align="center">
  <img src="apps/mac/Support/AppIcon.png" alt="Port Radar" width="128" height="128">
</p>

<h1 align="center">Port Radar</h1>

<p align="center">
  The AI port manager for Mac. Every port your Mac is running — named, explained, stopped in one click.
</p>

---

Port Radar is a native macOS menu-bar app that lists every process listening on localhost,
grouped by project. Ask Apple Intelligence what any of them is and whether it's safe to stop —
on-device, so nothing leaves your Mac. Share any local app as a live public URL with a
one-click Cloudflare tunnel.

- **Scan** — every listening TCP port, refreshed continuously, grouped by project
- **Ask** — on-device Apple Intelligence explains a process from its command, path, and uptime
- **Stop** — graceful SIGTERM with escalation, or force quit, always confirmed
- **Share** — one-click Cloudflare quick tunnel, no account or CLI setup

macOS 14+. Ask requires Apple Intelligence (macOS 26+ on a supported Mac).

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

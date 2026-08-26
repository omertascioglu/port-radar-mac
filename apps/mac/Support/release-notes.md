<!-- Modification notice: Changed in 2026 for the Port Radar Offline fork product identity and tunnel-free feature set. -->
Port Radar Offline is a native macOS menu-bar app that shows every port your Mac is running — and explains what's behind each one. Nothing it does leaves the machine.

- **Scan** — see every localhost listener, grouped by project
- **Ask** — Apple's on-device model, or a local Ollama model you installed yourself; answers stream in and **Stop** ends one mid-response
- **Stop** — stop or force quit anything, with confirmation

Requires macOS 14 or later. Apple's on-device model needs macOS 26 or later with Apple
Intelligence; otherwise pick an installed local Ollama model in Settings.

Ask keeps prompts, answers, and process context in memory only, replaces likely secrets with
`[REDACTED]` before a model sees them, and talks to Ollama through a private service the app
starts on `127.0.0.1:11435` with cloud access disabled. Closing chat unloads the model and
stops that service. The app never installs, downloads, opens, or pulls anything — install
Ollama and its models yourself.

## Install

Download `Port-Radar-Offline.dmg`, open it, then drag Port Radar Offline to Applications.

**First launch:** macOS will block it because this build isn't notarized yet. Go to
**System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway**.
You only need to do this once.

Prefer the terminal?

```bash
xattr -cr "/Applications/Port Radar Offline.app"
```

Or build from source — no dependencies beyond the Swift toolchain:

```bash
git clone https://github.com/omertascioglu/port-radar-mac
cd port-radar-mac && make run
```

<!-- Modification notice: Changed in 2026 for the Port Radar Offline fork product identity and tunnel-free feature set. -->
Port Radar Offline is a native macOS menu-bar app that shows every port your Mac is running — and explains what's behind each one.

- See every localhost listener, grouped by project
- Ask Apple Intelligence or a local Ollama model what a process is and whether it's safe to stop
- Stop or force quit anything, with confirmation

Requires macOS 14 or later. Ask uses Apple Intelligence when available or a local Ollama model.

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

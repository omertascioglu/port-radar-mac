A native macOS menu-bar app that shows every port your Mac is running — and explains what's behind each one.

- See every localhost listener, grouped by project
- Ask Apple Intelligence what a process is and whether it's safe to stop (on-device, nothing leaves your Mac)
- Stop or force quit anything, with confirmation
- Share any local app as a live public URL via one-click Cloudflare tunnel

Requires macOS 14 or later. Ask requires Apple Intelligence (macOS 26+ on a supported Mac).

## Install

Download `Port-Radar.dmg`, open it, drag Port Radar to Applications.

**First launch:** macOS will block it because this build isn't notarized yet. Go to
**System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway**.
You only need to do this once.

Prefer the terminal?

```bash
xattr -cr "/Applications/Port Radar.app"
```

Or build from source — no dependencies beyond the Swift toolchain:

```bash
git clone https://github.com/juansebsol/port-radar-mac
cd port-radar-mac && make run
```

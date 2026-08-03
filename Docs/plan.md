# DevPort — Plan

A native macOS menu-bar app that continuously detects developer servers running on localhost and lets you inspect, open, and safely stop them.

---

## 1. What we're building

Developers constantly leave dev servers running — Vite on 5173, Next.js on 3000, a forgotten Docker container, a Supabase stack. DevPort sits in the menu bar and shows every listening dev port on the machine, grouped by project, with one-click controls to open the URL, jump to the project, or kill the process.

**Target tools to detect:** Node, npm, npx, pnpm, yarn, Bun, Python, Ruby, Go, Docker, Supabase, Vite, Next.js, and similar dev processes listening on localhost TCP ports.

---

## 2. Tech stack

- **Language/UI** — Swift + SwiftUI, `MenuBarExtra`; deployment target macOS 14+ (the `@Observable` state macro requires it)
- **Project format** — Swift Package Manager (`Package.swift`); no `.xcodeproj`, no Xcode UI
- **Build/run** — `swift build` + a `Makefile` bundle script that assembles and ad-hoc signs `DevPort.app`
- **Dependencies** — Apple frameworks only (AppKit, SwiftUI, UserNotifications); zero third-party packages unless clearly needed
- **Icons** — SF Symbols
- **Storage** — `UserDefaults` for preferences
- **Privileges** — never requires root; only sees/controls the user's own processes, which is exactly the set dev servers live in

---

## 3. How we build & run (no Xcode UI)

Xcode is installed only for its toolchain (Swift compiler, macOS SDK, `codesign`). All editing happens in Cursor; all building happens in the terminal.

- `swift build` — compile
- `make bundle` — arrange the binary into `DevPort.app` (`Contents/MacOS/DevPort` + `Info.plist`), ad-hoc codesign
- `make run` — bundle + launch

The `.app` bundle (not a bare binary) is required for two features: user notifications (`UNUserNotificationCenter` needs a bundle identifier) and `LSUIElement` (hides the Dock icon so the app is menu-bar only).

---

## 4. Detection approach

Poll on an async timer (~2–3 s), diff against the previous snapshot:

1. **Find listeners** — `lsof -iTCP -sTCP:LISTEN -P -n` → port + PID for every listening TCP socket owned by the user.
2. **Resolve process** — from each PID: executable path (`proc_pidpath`), full launch command and parent PID (`ps` / `sysctl`), working directory (`proc_pidinfo` vnode info).
3. **Detect project** — walk up from the working directory to a `.git` root; read `package.json` / `pyproject.toml` / `go.mod` etc. for project name and framework guess (Vite, Next.js, …).
4. **Filter noise** — ignore system daemons (root-owned, known macOS ports), respect the configured port range and process allowlist.
5. **Diff & notify** — new port ⇒ optional notification; disappeared port ⇒ remove from UI; long-running server with no recent parent shell ⇒ flag as possibly orphaned.

---

## 5. Architecture

Source folders live in the repo root (per rules.md project layout):

| Module | Responsibility |
|--------|----------------|
| `Scanner` | Async polling loop around `lsof`, snapshot diffing |
| `ProcessResolver` | PID → executable, command, cwd, parent chain |
| `ProjectDetector` | cwd → git root, project name, framework identification |
| `Models` | `DevServer`, `Project`, `Framework` value types |
| `State` | `@Observable` app store; new/gone events, notification dispatch |
| `Views` | `MenuBarExtra` window, project groups, server rows, preferences |
| `Actions` | Open URL, reveal in Finder, open in Cursor/Terminal, terminate (SIGTERM), force kill (SIGKILL) |

Concurrency via async/await. Defensive error handling around every external call (`lsof` output parsing, dead PIDs mid-scan) — a failed scan must never crash the app, just skip the tick.

---

## 6. UI

`MenuBarExtra` window, grouped by project:

- **Per project** — name, framework icon, path
- **Per server** — status dot, localhost URL, port, PID, command (truncated, copyable), uptime
- **Controls** — open URL in browser, reveal in Finder, open in preferred editor, open in Terminal, stop (graceful, falls back to force kill), force kill
- **Preferences** — polling interval, port ranges, process allowlist, notifications on/off

Clean, native look; SF Symbols throughout; no emoji as icons.

---

## 7. Distribution

- **Now** — local only: `make run`, or keep `DevPort.app` in `/Applications`. Ad-hoc signed, no Apple account needed.
- **Later (optional)** — Developer ID + notarization to share outside the App Store (extra signing flags in the bundle script; requires paid Apple Developer account).
- **App Store — not possible for this app.** The App Store mandates App Sandbox, which forbids inspecting or signaling other processes — DevPort's core function. This is a platform rule, not a tooling choice.

---

## 8. Future improvements (out of MVP scope)

- Orphaned-server detection heuristics beyond the basics
- Restart with original command/cwd
- Notifications for new dev ports
- Preferences UI (port ranges, allowlist, polling interval)
- Docker/Supabase container-aware labels
- Launch at login
- Developer ID signing + notarization

---

## MVP definition

**Detect active localhost dev servers and safely stop them.** Concretely: the menu-bar app lists listening dev ports with port, PID, command, and project name, and can gracefully terminate (then force kill) a selected process. Everything in §8 waits until that loop works.

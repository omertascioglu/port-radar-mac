# DevPort — Tasks

Ordered checklist. Work top to bottom, one task at a time; finish **Done when** before moving on. Cross out completed tasks with strikethrough and update **Current focus**.

**Current focus:** Task 7

---

## Phase 1 — Skeleton

~~**1. SPM package + menu-bar shell**
Create `Package.swift` (executable target, macOS 13+), a minimal `@main` SwiftUI app with an empty `MenuBarExtra`, and the `Makefile` that builds, assembles `DevPort.app` (`Info.plist` with bundle id + `LSUIElement`), ad-hoc signs, and launches.
*Done when:* `make run` puts a DevPort icon in the menu bar with a placeholder window, and no Dock icon appears.~~

---

## Phase 2 — Detect & list (MVP part 1)

~~**2. Scanner**
Async polling loop (~2–3 s) around `lsof -iTCP -sTCP:LISTEN -P -n`; parse into `(port, pid)` snapshots and diff against the previous tick. Failed scans skip the tick, never crash.
*Done when:* starting/stopping `python3 -m http.server 8123` adds/removes an entry in logs within a few seconds.~~

~~**3. Process resolver**
PID → executable path, full launch command, parent PID, working directory. Handle PIDs that die mid-scan.
*Done when:* a detected Vite server shows its real command line and project cwd in logs.~~

~~**4. Raw list UI**
`Models` + `@Observable` state store; `MenuBarExtra` window listing detected servers: port, PID, command, localhost URL.
*Done when:* running dev servers appear in the menu-bar window and disappear when stopped.~~

---

## Phase 3 — Kill controls (MVP part 2)

~~**5. Stop / force kill**
Per-row stop button: SIGTERM, then SIGKILL after a timeout if still alive; separate force-kill option; confirmation before killing.
*Done when:* a dev server started in a terminal can be stopped from the menu bar and the row disappears. **This completes the MVP.**~~

---

## Phase 4 — Project grouping

~~**6. Project detector**
Walk up from cwd to `.git` root; read `package.json` / `pyproject.toml` / `go.mod` for project name and framework. System processes stay visible but labeled with the System badge (user decision — no hiding).
*Done when:* servers are labeled with the correct project name and framework.~~

**7. Grouped UI + open actions**
Group rows by project with framework SF Symbols; add open URL, reveal in Finder, open in Cursor, open in Terminal.
*Done when:* each action works from a server row.

---

## Phase 5 — Polish

**8. Uptime + restart**
Show process uptime; restart action (kill, relaunch with original command + cwd).
*Done when:* restarting a Vite server brings it back on the same port.

**9. Notifications + orphan flag**
Notification when a new dev port appears; flag servers whose parent shell is gone as possibly orphaned.
*Done when:* starting a new dev server triggers a notification; an orphaned server is visually marked.

**10. Preferences**
Preferences window: polling interval, port ranges, process allowlist, notifications toggle; persist in `UserDefaults`.
*Done when:* settings survive an app restart and visibly change behavior.

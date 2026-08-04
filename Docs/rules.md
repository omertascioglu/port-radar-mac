# Development Rules

Ground rules for building this project — for you and for AI assistance. These come from decisions already made in this repo and requests you've stated in chat. **Do not invent extra rules beyond what's here, [plan.md](./plan.md), and [tasks.md](./tasks.md).**

---

## Source of truth

| Doc | Role |
|-----|------|
| [plan.md](./plan.md) | What we're building, architecture, Square flow, MVP scope |
| [tasks.md](./tasks.md) | Ordered checklist — what to build next and when a slice is done |
| **rules.md** (this file) | How we work while building |

If something conflicts, **plan.md** defines product/tech intent; **tasks.md** defines current execution order; **rules.md** defines process.

---

## Project layout

- **Monorepo** — `apps/mac/` is the native Port Radar menu-bar app; `apps/web/` is the Next.js landing. Keep those stacks separate (no shared build that forces Node onto Swift or vice versa).
- **`Docs/`** holds planning and process docs only (`plan.md`, `tasks.md`, `rules.md`), at the repo root.
- Root `Makefile` may delegate to `apps/mac` for convenience (`make run`).

---

## How we build (workflow)

1. **MVP first** — Ship the smallest working loop described in plan.md before future improvements (plan §8 stays out of scope until MVP is done).
2. **One task at a time** — Work top to bottom in [tasks.md](./tasks.md). Finish the current task's **Done when** criteria before moving on.
3. **Cross out completed work** — In `tasks.md`, mark finished tasks with strikethrough (`~~like this~~`) and update **Current focus** to the next task.
4. **Vertical slices** — Each task should be testable on its own (e.g. menu before payments), matching plan.md Phase structure.
5. **Don't go overboard** — No extra features, abstractions, or files beyond what the current task needs. When asked for commands only, provide commands — don't run or scaffold unless asked.

---

## Code & change discipline

- **Minimize scope** — Smallest correct diff. Don't touch unrelated code.
- **Match existing patterns** — Same naming, structure, and style as surrounding code.
- **No over-engineering** — No premature abstractions, helpers, or error handling for unlikely edge cases.
- **Comments** — Only for non-obvious business or technical detail; code should mostly speak for itself.
- **Tests** — Add only when requested or when they cover real behavior worth guarding.

---

## Tech stack

Defaults for new projects unless `plan.md` overrides.

- **Frameworks** — Next.js (web), Expo + Expo Go (mobile)
- **Tooling** — npm
- **Infrastructure** — PM2 + Caddy (Node processes, HTTPS, routing)
- **Icons** — Lucide (`lucide-react` on web, `lucide-react-native` on mobile). Use Lucide for all UI icons; do not use emoji as interface icons.

### Stack rules

- **Expo / React Native** — Install packages with `npx expo install <package>`, not `npm install`. Expo picks versions matched to the installed SDK. To realign deps: `npx expo install --fix`. Never use `--legacy-peer-deps`.
- **npm** — Use for Next.js projects and JS-only dependencies. Do not use plain `npm install` for Expo or native modules.

### Native macOS apps

- **Language/UI** — Swift + SwiftUI. Menu-bar apps use `MenuBarExtra` (macOS 13+).
- **No Xcode UI** — All development happens in the editor/IDE of choice, never in Xcode. Xcode is installed only for its toolchain (Swift compiler, macOS SDK, `codesign`). Never create or open an `.xcodeproj`.
- **Project format** — Swift Package Manager (`Package.swift` in `apps/mac`). Build with `swift build`; run via the bundle script.
- **App bundle** — A `Makefile` assembles the `.app` bundle (`Info.plist`, ad-hoc codesign). Required for notifications and hiding the Dock icon (`LSUIElement`).
- **Dependencies** — Apple frameworks first (AppKit, SwiftUI, UserNotifications). Add SPM dependencies only when clearly needed.
- **Icons** — SF Symbols for all UI icons (native equivalent of the Lucide rule); no emoji as interface icons.
- **No root** — The app must never require sudo or elevated privileges.

---

## Git & pull requests

- **Assistant: never stage, commit, push, or open PRs** — No `git add`, `git commit`, `git push`, or `gh pr create`. Git is managed by the human in the loop.

---

## AI assistance expectations

When working in this repo, the assistant should:

1. Read **plan.md** and **tasks.md** before starting new work.
2. Implement only what the **current task** requires.
3. Update **tasks.md** when a task is actually complete (strikethrough + move **Current focus**).
4. Not add new markdown docs unless you ask (plan, tasks, and rules are the doc set for now).
5. Never update **rules.md** unless explicitly asked to add something to the rules.

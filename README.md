<p align="center">
  <img src="apps/mac/Support/AppIcon.png" alt="Port Radar" width="128" height="128">
</p>

# Port Radar

Native macOS menu-bar app that finds localhost listeners — plus a marketing site in the same repo.

## Repo layout

```
apps/mac/     Native SwiftUI menu-bar app (Port Radar)
apps/web/     Next.js landing
Docs/         Product plan, tasks, rules
```

## Mac app

```bash
cd apps/mac
make run      # build, assemble Port Radar.app, launch
make build    # compile only
make bundle   # build + assemble without launching
make clean
```

From the repo root you can also run:

```bash
make run
```

Details: [`apps/mac/README.md`](apps/mac/README.md)

## Web landing

```bash
cd apps/web
npm run dev
```

Details: [`apps/web/README.md`](apps/web/README.md)

## Docs

[`Docs/plan.md`](Docs/plan.md) · [`Docs/tasks.md`](Docs/tasks.md) · [`Docs/rules.md`](Docs/rules.md)

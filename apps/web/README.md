<!-- Modification notice: Changed in 2026 for the Port Radar Offline fork. -->

# Port Radar Offline — Web

Landing page for the macOS download. Lives in `apps/web`.

## Dev

```bash
cd apps/web
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Download link

Edit `src/lib/site.ts`, or set the env var:

```bash
NEXT_PUBLIC_DOWNLOAD_URL=https://github.com/omertascioglu/port-radar-mac/releases/latest/download/Port-Radar-Offline.dmg
```

The default already points at the latest release asset, so it keeps working across releases as
long as the DMG is named `Port-Radar-Offline.dmg` (see `make publish`).

## Press routes

`/press/gallery/01` … `/press/gallery/06` render 1270×760 stills of the app panel for
screenshots. They reuse the live demo's components so the stills cannot drift from the product,
and they are excluded from search indexing.

## Scripts

```bash
npm run dev
npm run build
npm run start
npm run lint
```

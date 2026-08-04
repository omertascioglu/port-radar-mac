# Port Radar — Web

Premium marketing site for Product Hunt + macOS downloads. Lives in `apps/web`.

## Dev

```bash
cd apps/web
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Download / Product Hunt links

Edit `src/lib/site.ts`, or set env vars:

```bash
NEXT_PUBLIC_DOWNLOAD_URL=https://github.com/YOU/REPO/releases/latest/download/Port-Radar.dmg
NEXT_PUBLIC_PRODUCT_HUNT_URL=https://www.producthunt.com/posts/port-radar
```

## Scripts

```bash
npm run dev
npm run build
npm run start
npm run lint
```

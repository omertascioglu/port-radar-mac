# Launch content kit

Ready-to-paste posts and media for Port Radar.

```
content/
├── README.md                 ← you are here
├── capture-gallery.sh        ← re-shoot gallery stills from the real UI
├── reddit/
│   ├── POST.md               ← r/vibecoding title + body
│   ├── share-image.png       ← attach this
│   └── logo.png
└── product-hunt/
    ├── LAUNCH.md             ← tagline, description, tags, first comment
    └── media/
        ├── thumbnail-240.png
        ├── logo.png
        ├── logo-512.png
        ├── 01-hero.png
        ├── 02-ask-ai.png
        ├── 03-tunnels.png
        ├── 04-stop.png
        ├── 05-menu.png
        └── 06-free.png
```

1. Reddit → open `reddit/POST.md`, attach `share-image.png`
2. Product Hunt → open `product-hunt/LAUNCH.md`, upload gallery in numbered order

## Gallery images

The gallery stills are screenshots of the actual product UI, not mockups. Slides render
at `/press/gallery/01` … `/06` in `apps/web` and reuse the same components as the live
site demo, so they can't drift from the app.

```bash
cd apps/web && npm run dev
content/capture-gallery.sh 3000   # pass the port Next actually picked
```

Output is 2540×1520 — 2× Product Hunt's recommended 1270×760, same 1.67:1 ratio.

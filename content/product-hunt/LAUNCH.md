# Product Hunt — launch copy & assets

## Product name
Port Radar

---

## Tagline (≤60 chars)

**Use this:**

```
The AI port manager for Mac. No Terminal required.
```

*(50 chars)*

Why it works: the first half is the searchable category (**AI port manager**, **Mac**) so the launch indexes for what people type. The second half is the promise anyone understands — you don't need to be a command-line person to use this. No insider jargon, so it travels past the hardcore dev crowd.

### Alternates (all ≤60)

| Tagline | Chars | Angle |
| --- | --- | --- |
| `The AI port manager for Mac. Never open Terminal again.` | 55 | Punchiest, most quotable |
| `The AI port manager for Mac. One click, no Terminal.` | 52 | Emphasizes speed |
| `Port 3000 already in use? Fix it from your menu bar` | 51 | Highest-volume search phrase |
| `See what's running on your Mac — and stop it with AI` | 52 | Zero jargon at all |
| `Free AI port manager for Mac. No Terminal required.` | 51 | Leads with free |

**Keyword cluster to keep alive across tagline, description, and comment:** AI port manager, Mac, macOS menu bar, localhost, port 3000, running processes, Apple Intelligence, Cloudflare tunnel, free.

**Words to avoid** (jargon that shrinks the audience): `lsof`, `EADDRINUSE`, `kill -9`, `xargs`, PID.

---

## Description (≤500 chars)

```
"Port 3000 is already in use." If you've seen that, this is for you.

Port Radar is a native macOS menu bar app that shows every port your Mac is running, in plain language — Vite, Next.js, Docker, a forgotten app eating your battery — and stops any of them in one click.

What's different: Apple Intelligence answers "what is this, is it safe to stop?" right on your device, so nothing leaves your Mac. Plus one-click Cloudflare tunnels to share a local site as a live link.

Free.
```

*(482 / 500 chars)*

---

## Launch tags (pick 3)

1. **Developer Tools** — primary, where your buyers browse
2. **Mac** — platform search traffic
3. **Artificial Intelligence** — biggest discovery surface right now

*(Swap AI → Menu Bar Apps only if you'd rather own a small niche than compete in a big one.)*

---

## Shoutouts

Each one posts as a founder review on that product's page, so write it like a real review:
name the alternative you didn't pick and why. Add these three first.

### 1. Cloudflare

Port Radar's one-click share is built on Cloudflare quick tunnels. I picked it over ngrok
because there's no account, no auth token, and no session limits — the app just downloads
cloudflared on first use and you get a public HTTPS URL for localhost in seconds. Free,
instant, no signup wall.

### 2. Apple Intelligence

The Ask feature runs on Apple's on-device foundation model instead of a cloud API. Better
than wiring up OpenAI or Claude for this job: no API key, no per-call cost, no network round
trip, and your running processes never leave your Mac — which matters a lot when the question
is "is this safe to stop?"

### 3. SwiftUI

Port Radar is a MenuBarExtra app with zero third-party dependencies — the list, the popover,
the modals, the animations are all SwiftUI. The usual alternative for a menu bar utility is
Electron, which means shipping a whole browser and hundreds of megs of RAM to display a list of
ports. This one opens instantly and idles at nothing.

*(If SwiftUI has no product page that day, use **Swift** or **Xcode** with the same angle.)*

### Extras (add if you want more than three)

**GitHub** — Releases and distribution. Beats rolling my own update server: the app pulls the
Cloudflare helper straight from GitHub releases, and the download link is just a repo.

**Next.js / Tailwind CSS** — Only the marketing site and the launch gallery, not the app. Lower
priority, but honest: the gallery images render from the same components as the site demo, so
the screenshots are real UI instead of mockups.

Search Product Hunt for each by name and pick the official product page. Keep shoutouts to
things the app genuinely runs on — these publish publicly as reviews with your name on them,
so everything should be verifiable from the repo.

---

## First comment (auto-posts at launch)

Hey Product Hunt 👋

You start a project. Something's already using port 3000. You have no idea what, or whether it's safe to shut down.

That was my entire week, every week. So I built Port Radar.

It sits in your Mac menu bar and:

• Shows every port your Mac is currently running  
• Names what's behind it in plain language — Vite, Next.js, Docker, Postgres, or "a background app you opened three days ago"  
• Answers "what is this, and is it safe to stop?" using Apple Intelligence, **on your device** — nothing gets uploaded anywhere  
• Stops anything in one click  
• Turns a local site into a live shareable link with a one click Cloudflare tunnel  

No Terminal. No commands to memorize. No cloud.

The AI part is the piece I'm proudest of, instead of a list of numbers, you get an actual answer, and it never leaves your machine.



---

## Media checklist

| Asset | File | Spec |
| --- | --- | --- |
| Thumbnail | `media/thumbnail-240.png` | 240×240 |
| Logo (hi-res) | `media/logo.png` | 1254×1254 |
| Logo mid | `media/logo-512.png` | 512×512 |
| Gallery 1 — hero (upload first) | `media/01-hero.png` | 2540×1520 |
| Gallery 2 — Ask AI | `media/02-ask-ai.png` | 2540×1520 |
| Gallery 3 — Tunnels | `media/03-tunnels.png` | 2540×1520 |
| Gallery 4 — Stop | `media/04-stop.png` | 2540×1520 |
| Gallery 5 — Actions menu | `media/05-menu.png` | 2540×1520 |
| Gallery 6 — Free | `media/06-free.png` | 2540×1520 |

**Gallery order:** 01 → 06. The first image becomes the social/newsletter preview.

Gallery stills are 2× Product Hunt's recommended 1270×760 (same 1.67:1 ratio, sharper on
retina, all well under the 3MB limit). They're real screenshots of the product UI — rendered
from the same components as the site demo, not mockups. To re-shoot after a UI change:

```bash
cd apps/web && npm run dev
content/capture-gallery.sh 3000   # use the port Next actually picked
```

Slides live at `/press/gallery/01` … `/06`.

Optional: a short YouTube demo (menu bar → ask AI → tunnel). PH only accepts public YouTube URLs.

---

## Launch notes

- Weekday, 12:01am PT posting window gets a full day on the leaderboard
- Reply to every comment in the first 2–3 hours — engagement drives ranking more than raw votes
- Ask for feedback, never upvotes
- Reuse the tagline verbatim in your Reddit title, X post, and GitHub repo description so the keyword cluster reinforces itself

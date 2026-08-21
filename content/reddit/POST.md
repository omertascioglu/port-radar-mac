# r/vibecoding — Reddit post

## Title (copy this)

I built a menu bar app that tells you what the hell is running on localhost (and if it's safe to kill)

## Alternate titles

1. Stop guessing which forgotten Vite server is eating your Mac
2. Mystery ports? Ask AI what's listening — on-device, menu bar
3. Built Port Radar so I stop `lsof -i` every time Cursor spins up another server

## Image to attach

`share-image.png` (primary)  
`logo.png` (backup / icon only)

---

## Body (copy this)

You know that feeling when you've got 6 terminals open, Cursor has been vibing for 3 hours, and suddenly something is on `:3000` / `:5173` / `:8080` and you have no idea what owns it?

I got tired of:

- `lsof -i :3000`
- Activity Monitor archaeology
- killing the wrong `node` process
- forgetting a server is still running overnight

So I built **Port Radar** — a native macOS menu bar app that:

1. **Lists every localhost process** listening right now  
2. Lets you **ask Apple Intelligence** what it is, why it's there, and if it's safe to stop  
3. Can **share any local app** with a one-click Cloudflare tunnel (public URL, no deploy)

The AI bit runs **on-device** via Apple Intelligence — nothing leaves your Mac. Felt important if you're asking "is this safe to kill?" about random processes.

Built it for myself while shipping side projects. If you're in the same "I spun up 4 stacks and lost track" club, this might save you a few rage sessions.

**Free · Mac · menu bar**  
GitHub: https://github.com/juansebsol/port-radar-mac

Happy to take feature requests / roast the UX. What's your current "mystery port" workflow?

---

## Posting tips

- Flair: **Show** / **Showcase** / whatever vibecoding uses for self-built tools
- Attach `share-image.png` first; keep the post personal (built for myself), not "launch announcement"
- Reply fast to comments — Reddit hates drive-by shills
- Don't lead with Product Hunt; if someone asks for download, drop the GitHub link

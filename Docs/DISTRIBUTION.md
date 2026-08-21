# Shipping Port Radar to other people's Macs

## What you already have

`make dmg` (from repo root or `apps/mac`) produces a real Mac installer:

```bash
make dmg
# → apps/mac/dist/Port-Radar-0.1.0.dmg  (~1.1 MB)
```

It's the standard drag-to-Applications disk image: the user opens it, drags the app
across, done. The version number comes from `CFBundleShortVersionString` in
`Support/Info.plist`, so bump that before each release.

## The problem: that DMG is not ready for strangers

The app is currently **ad-hoc signed** (`codesign --sign -`), which is fine on your own
machine and rejected everywhere else:

```bash
make verify
# Signature=adhoc
# Port Radar.app: rejected     ← Gatekeeper
```

What someone who downloads it actually experiences on macOS 15 Sequoia or newer:

1. Double-click → *"Port Radar Not Opened. Apple could not verify it is free of malware."*
2. There is **no** Control-click → Open bypass anymore. Apple removed it in Sequoia.
3. They must open System Settings → Privacy & Security, scroll to the bottom, find
   "Port Radar was blocked", click **Open Anyway**, then authenticate as admin.

That's a real conversion killer on a Product Hunt launch day — most visitors will assume
the app is broken or sketchy and leave. Developers will push through it; nobody else will.

## The fix: Developer ID + notarization

Requires the **Apple Developer Program — $99/year**. Notarization and Developer ID
certificates are not available on a free Apple account. There is no way around this for
distribution outside the App Store, and the App Store itself is not an option here (its
mandatory sandbox forbids inspecting and signaling other processes, which is the app).

Once enrolled:

1. **Create the certificate** — Xcode → Settings → Accounts → Manage Certificates → +
   → *Developer ID Application*. Confirm it landed:

   ```bash
   make identities
   # 1) ABC123... "Developer ID Application: Your Name (TEAM12345)"
   ```

2. **Store notary credentials once** — use an app-specific password from
   appleid.apple.com, not your Apple ID password:

   ```bash
   xcrun notarytool store-credentials port-radar \
     --apple-id you@example.com \
     --team-id TEAM12345 \
     --password xxxx-xxxx-xxxx-xxxx
   ```

3. **Build a signed, notarized, stapled DMG**:

   ```bash
   make notarize \
     DEVELOPER_ID="Developer ID Application: Your Name (TEAM12345)" \
     NOTARY_PROFILE=port-radar
   ```

   This signs the app with the hardened runtime and a secure timestamp, builds the DMG,
   uploads it to Apple, waits for the verdict, then staples the ticket so the app
   validates even offline.

4. **Confirm it will open cleanly**:

   ```bash
   make verify DEVELOPER_ID="Developer ID Application: Your Name (TEAM12345)"
   # Authority=Developer ID Application: ...
   # Port Radar.app: accepted
   ```

`accepted` is the goal. That's a download that just opens.

Keep these out of your shell history and CI logs — pass them per-command as above, or put
them in a local untracked file you source.

## Publishing the download

One command, once the repo is public:

```bash
make publish
```

That builds the DMG and creates a GitHub release tagged from `CFBundleShortVersionString`,
attaching `dist/Port-Radar.dmg` with the notes in `apps/mac/Support/release-notes.md`.

The site already points at `releases/latest/download/Port-Radar.dmg`, so the download button
keeps working for every future release **as long as the asset stays named `Port-Radar.dmg`**.
`make dmg` writes both a versioned file (for your records) and that stable-named copy.

Release assets on a **private** repo require authentication and will 401 for visitors — the
repo must be public for this to work.

## If you launch before paying the $99

It works, but say so on the download page and in the Product Hunt comments, or your first
wave of feedback will be "it says it's malware." Minimum viable honesty:

> macOS will block the first launch because the app isn't notarized yet (I'm a solo dev and
> haven't bought the $99 certificate). Open System Settings → Privacy & Security → click
> "Open Anyway". Source is on GitHub if you'd rather build it yourself.

The Terminal alternative, for the developer crowd:

```bash
xattr -cr "/Applications/Port Radar.app"
```

## Later: automatic updates

Nothing is wired up for updates — users would have to re-download. When it matters, the
standard answer for non-App-Store Mac apps is [Sparkle](https://sparkle-project.org), which
needs a signed appcast feed hosted next to the DMG. Notarization is a prerequisite, so do
that first.

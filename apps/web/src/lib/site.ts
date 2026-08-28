// Modification notice: Changed in 2026 for the Port Radar Offline fork.
/** Site config — update the download URL when a release DMG ships. */
export const site = {
  name: "Port Radar Offline",
  tagline: "Ask a local model what’s running on your Mac.",
  description:
    "Port Radar Offline finds every localhost process in your menu bar — then an on-device Apple model or a local Ollama model explains what it is. No sharing, no accounts, no network calls. Free and open source.",
  // Resolves to the newest release's DMG — the asset name must stay stable.
  downloadUrl:
    process.env.NEXT_PUBLIC_DOWNLOAD_URL ??
    "https://github.com/omertascioglu/port-radar-mac/releases/latest/download/Port-Radar-Offline.dmg",
  githubUrl: "https://github.com/omertascioglu/port-radar-mac",
} as const;

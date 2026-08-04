/** Site config — update download URL when you ship a release DMG/zip. */
export const site = {
  name: "Port Radar",
  tagline: "Ask AI what’s running on your Mac.",
  description:
    "Port Radar finds every localhost process in your menu bar — then Apple Intelligence explains what it is. One-click Cloudflare tunnels give you a live public URL for any local app. On-device. Private.",
  downloadUrl:
    process.env.NEXT_PUBLIC_DOWNLOAD_URL ??
    "https://github.com/sebsol/port-radar-mac/releases/latest",
  githubUrl: "https://github.com/sebsol/port-radar-mac",
  productHuntUrl: process.env.NEXT_PUBLIC_PRODUCT_HUNT_URL ?? "#product-hunt",
  email: "hello@portradar.app",
} as const;

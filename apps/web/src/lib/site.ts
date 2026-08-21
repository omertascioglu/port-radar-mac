/** Site config — update download URL when you ship a release DMG/zip. */
export const site = {
  name: "Port Radar",
  tagline: "Ask AI what’s running on your Mac.",
  description:
    "Port Radar finds every localhost process in your menu bar — then Apple Intelligence explains what it is. One-click Cloudflare tunnels give you a live public URL for any local app. On-device. Private. Free and open source.",
  // Resolves to the newest release's DMG — the asset name must stay stable.
  downloadUrl:
    process.env.NEXT_PUBLIC_DOWNLOAD_URL ??
    "https://github.com/juansebsol/port-radar-mac/releases/latest/download/Port-Radar.dmg",
  githubUrl: "https://github.com/juansebsol/port-radar-mac",
  productHuntUrl:
    process.env.NEXT_PUBLIC_PRODUCT_HUNT_URL ??
    "https://www.producthunt.com/products/port-radar-for-macos",
  // Official featured badge — post_id is fixed for the launch.
  productHuntBadge:
    "https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1228833&theme=neutral",
  email: "hello@portradar.app",
} as const;

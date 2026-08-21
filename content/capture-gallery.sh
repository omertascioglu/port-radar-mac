#!/usr/bin/env bash
# Re-shoot the launch gallery from the real UI components.
#
#   cd apps/web && npm run dev        # note the port it picks
#   content/capture-gallery.sh 3000
#
# Slides live at /press/gallery/01..06 and render the same components as the
# product demo, so the stills can't drift from the app.
set -euo pipefail

PORT="${1:-3000}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
MEDIA="$(cd "$(dirname "$0")" && pwd)/product-hunt/media"
REDDIT="$(cd "$(dirname "$0")" && pwd)/reddit"

shoot() { # slide, filename
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=2 --virtual-time-budget=4000 \
    --window-size=1270,760 --screenshot="$MEDIA/$2" \
    "http://localhost:$PORT/press/gallery/$1" 2>/dev/null
  echo "  $2"
}

echo "Capturing gallery from localhost:$PORT"
shoot 01 01-hero.png
shoot 02 02-ask-ai.png
shoot 03 03-tunnels.png
shoot 04 04-stop.png
shoot 05 05-menu.png
shoot 06 06-free.png

cp "$MEDIA/01-hero.png" "$REDDIT/share-image.png"
echo "Done — 2540x1520 (2x of Product Hunt's 1270x760)."

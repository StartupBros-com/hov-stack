#!/usr/bin/env bash
# render_designs.sh - regenerate seed/acme-console/design/*.png from designs/*.html.
# Headless Chrome at device scale 2, with its own profile and XDG dirs under a scratch root so it
# never touches the operator's browser profile. The PNGs are cropped to the page background.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="${SCRATCH:-/tmp/bdvet-render}"
CHROME="${CHROME:-google-chrome}"
mkdir -p "$SCRATCH/profile" "$SCRATCH/xdg-config" "$SCRATCH/xdg-cache" "$HERE/seed/acme-console/design"
for name in team-members danger-zone billing; do
  XDG_CONFIG_HOME="$SCRATCH/xdg-config" XDG_CACHE_HOME="$SCRATCH/xdg-cache" \
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --user-data-dir="$SCRATCH/profile" --force-device-scale-factor=2 --window-size=784,1000 \
    --screenshot="$SCRATCH/$name.png" "file://$HERE/designs/$name.html" 2> "$SCRATCH/$name.chrome.err"
  python3 -I - "$SCRATCH/$name.png" "$HERE/seed/acme-console/design/$name.png" <<'PY'
import sys
from PIL import Image, ImageChops
src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGB")
bg = Image.new("RGB", im.size, im.getpixel((2, 2)))
box = ImageChops.difference(im, bg).getbbox()
pad = 64  # 32 CSS px at scale 2
left, top, right, bottom = box
im.crop((max(0, left - pad), max(0, top - pad), min(im.width, right + pad), min(im.height, bottom + pad))).save(dst, optimize=True)
print("%s %dx%d" % (dst.rsplit("/", 1)[-1], *Image.open(dst).size))
PY
done

#!/usr/bin/env bash
# Fetch the Kuro type stack (Fraunces, Space Grotesk, Space Mono) as self-hosted
# woff2 files, offline-safe (no runtime dependency on Google Fonts / CDNs).
#
# The Google Fonts CSS2 API serves different font formats depending on the
# User-Agent string; a modern Chrome UA is required to get woff2 (older/absent
# UAs get ttf or eot). The response contains one @font-face block per
# unicode-range subset (cyrillic, greek, vietnamese, latin-ext, latin, ...);
# we only want the "latin" subset (broadest coverage for this project's UI).
#
# Re-run this script any time to re-fetch (e.g. if Google rotates font URLs).
set -euo pipefail

cd "$(dirname "$0")/../frontend/public/fonts"

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
CSS_URL="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,300..600&family=Space+Grotesk:wght@300..700&family=Space+Mono:ital,wght@0,400;0,700;1,400&display=swap"

echo "Fetching Google Fonts CSS2 manifest..."
curl -s -A "$UA" "$CSS_URL" -o /tmp/haro-kuro-fonts.css

# Extract the "latin" subset src URL for each family/weight/style combination
# and download straight into public/fonts with clear file names.
python3 - <<'PYEOF'
import re

css = open("/tmp/haro-kuro-fonts.css").read()
blocks = re.findall(r'/\*\s*(\S+)\s*\*/\s*@font-face\s*\{([^}]+)\}', css)

# (family, weight, style) -> output filename
NAMES = {
    ("Fraunces", "300 600", "normal"): "Fraunces-Variable.woff2",
    ("Space Grotesk", "300 700", "normal"): "SpaceGrotesk-Variable.woff2",
    ("Space Mono", "400", "normal"): "SpaceMono-Regular.woff2",
    ("Space Mono", "700", "normal"): "SpaceMono-Bold.woff2",
    ("Space Mono", "400", "italic"): "SpaceMono-Italic.woff2",
}

import subprocess
for subset, body in blocks:
    if subset != "latin":
        continue
    fam = re.search(r"font-family:\s*'([^']+)'", body).group(1)
    weight = re.search(r"font-weight:\s*([^;]+);", body).group(1).strip()
    style = re.search(r"font-style:\s*([^;]+);", body).group(1).strip()
    url = re.search(r"url\(([^)]+)\)", body).group(1)
    key = (fam, weight, style)
    out = NAMES.get(key)
    if not out:
        print(f"skip unrecognized face: {key}")
        continue
    print(f"downloading {fam} {weight} {style} -> {out}")
    subprocess.run(["curl", "-sL", "-o", out, url], check=True)
PYEOF

echo "Fetching OFL licenses..."
curl -sL -o OFL-Fraunces.txt "https://raw.githubusercontent.com/google/fonts/main/ofl/fraunces/OFL.txt"
curl -sL -o OFL-SpaceGrotesk.txt "https://raw.githubusercontent.com/google/fonts/main/ofl/spacegrotesk/OFL.txt"
curl -sL -o OFL-SpaceMono.txt "https://raw.githubusercontent.com/google/fonts/main/ofl/spacemono/OFL.txt"

echo "Done. Files written to frontend/public/fonts/:"
ls -la Fraunces-Variable.woff2 SpaceGrotesk-Variable.woff2 SpaceMono-Regular.woff2 SpaceMono-Bold.woff2 SpaceMono-Italic.woff2 \
  OFL-Fraunces.txt OFL-SpaceGrotesk.txt OFL-SpaceMono.txt

echo
echo "Kanji watermark subset (門黒集) is a separate, optional step - see"
echo "notes/kuro-theme-plan.md for the Noto Serif CJK JP subsetting command."

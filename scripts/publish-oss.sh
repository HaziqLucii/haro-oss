#!/usr/bin/env bash
# Publish a squashed public snapshot of this repo to the public HaziqLucii/haro-oss
# mirror. This repo (HaziqLucii/haro) is the private upstream; haro-oss is the
# public downstream, decided 2026-09-22 (no history rewrite on this repo — the
# mirror just gets one fresh commit per publish, force-pushed).
#
# Excludes notes/, backlog/ and app/notes/ (internal planning/strategy docs) —
# everything else committed at HEAD goes across as-is. Exports from HEAD (not the
# working tree) so uncommitted edits never leak. Run manually whenever you want to
# push an update; each run replaces the mirror's entire history with one new commit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_REPO="HaziqLucii/haro-oss"

echo "▸ verifying active gh account is HaziqLucii"
active_login="$(gh api user --jq .login 2>/dev/null || true)"
if [ "$active_login" != "HaziqLucii" ]; then
  echo "✗ active gh account is '$active_login', not HaziqLucii." >&2
  echo "  run: gh auth switch --hostname github.com --user HaziqLucii" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "main" ]; then
  echo "✗ on branch '$branch'; publish from main." >&2
  exit 1
fi
if ! git diff --quiet HEAD -- . ':!notes' ':!backlog' ':!app/notes'; then
  echo "▸ note: uncommitted changes exist; they are NOT published (exporting HEAD)"
fi

echo "▸ exporting HEAD (excluding notes/, backlog/, app/notes/, the landing drafts)"
git archive --format=tar HEAD | tar -x -C "$WORK"
rm -rf "$WORK/notes" "$WORK/backlog" "$WORK/app/notes" "$WORK/app/design/landing"
# No Dependabot on the mirror: every PR it opens pins that snapshot on GitHub for good, and a
# force-pushed mirror can never merge them anyway. Dependency updates happen in the private repo.
rm -f "$WORK/.github/dependabot.yml"

echo "▸ adding MIT LICENSE"
YEAR="$(date +%Y)"
cat > "$WORK/LICENSE" << EOF
MIT License

Copyright (c) $YEAR Haziq

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

echo "▸ dropping the notes/product-spec.md reference from README (excluded from this mirror)"
python3 - "$WORK/README.md" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = (
    "[`CHANGELOG.md`](./CHANGELOG.md) (the live record of what's shipped) and\n"
    "[`notes/product-spec.md`](./notes/product-spec.md)."
)
new = "[`CHANGELOG.md`](./CHANGELOG.md) (the live record of what's shipped)."
if old in text:
    text = text.replace(old, new)
    with open(path, "w") as f:
        f.write(text)
    print("  patched")
else:
    print("  pattern not found — README wording changed, left as-is (check manually)")
PYEOF

echo "▸ committing squashed snapshot"
cd "$WORK"
git init -q -b main
git add -A
git -c user.name="Haziq" -c user.email="haziqdluffy@gmail.com" \
    commit -q -m "public snapshot $(date -u +%Y-%m-%d)"

echo "▸ pushing to $PUBLIC_REPO (force)"
git remote add origin "https://github.com/$PUBLIC_REPO.git"
git push -f origin main

echo "▸ starting ci on the mirror (a history-less push can't trigger it by paths; public repos run free)"
for wf in ci.yml app-ci.yml; do
  gh workflow run "$wf" -R "$PUBLIC_REPO" --ref main || echo "  could not start $wf; run it from the Actions tab"
done

echo "✓ published to https://github.com/$PUBLIC_REPO"

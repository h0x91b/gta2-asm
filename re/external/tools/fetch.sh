#!/usr/bin/env bash
# Clones the external reference repos at the pinned commits into .external/ (git-ignored).
# Read-only reference: nothing from these clones is committed except extracted facts.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
EXT="${EXT:-$REPO/.external}"
mkdir -p "$EXT"
while read -r name url sha; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ ! -d "$EXT/$name/.git" ]]; then git clone -q "$url" "$EXT/$name"; fi
  git -C "$EXT/$name" fetch -q origin "$sha" 2>/dev/null || true
  git -C "$EXT/$name" -c advice.detachedHead=false checkout -q "$sha"
  echo "$name $(git -C "$EXT/$name" rev-parse HEAD)"
done <<'PINS'
# name                url                                              commit
gta2-seuko-mod   https://github.com/izawartka/gta2-seuko-mod.git   25b198591f840b909dc5e3a38be880840d94c17d
gta2-resurection https://github.com/h0x91b/gta2-resurection.git   87e1d98f14a7a861d6e3518eb2b4885788592a8e
gta2-mouse       https://github.com/h0x91b/gta2-mouse.git         6c5351b67da14f1c08db2e9146b59afdfe583743
PINS

#!/usr/bin/env bash
# Full regeneration of re/external/: fetch pinned repos, export the .gzf, harvest + diff.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
"$D/fetch.sh"
[[ "${SKIP_GZF:-}" == 1 ]] || "$D/export_gzf.sh"
python3 -I "$D/harvest.py" "$@"

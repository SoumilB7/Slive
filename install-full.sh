#!/bin/bash
# Install or update Slive with its Python server — Ask, local models,
# correct-answer labeling and training (~1.2 GB more than install.sh):
#   curl -fsSL https://raw.githubusercontent.com/SoumilB7/Slive/main/install-full.sh | bash
# A version: … | bash -s -- 0.2.3     Re-run to update.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "$here" && -f "$here/install.sh" ]]; then
    SLIVE_EDITION=full exec bash "$here/install.sh" "$@"
fi
curl -fsSL https://raw.githubusercontent.com/SoumilB7/Slive/main/install.sh | SLIVE_EDITION=full bash -s -- "$@"

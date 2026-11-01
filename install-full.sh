#!/bin/bash
# Install or update Slive with its Python server — Ask, local models,
# correct-answer labeling and training (~1.2 GB more than install.sh):
#   curl -fsSL https://raw.githubusercontent.com/SoumilB7/Slive/main/install-full.sh | bash
# Always the latest version. Re-run to update.
set -euo pipefail
# Run from a checkout: use its install.sh. Piped from curl there's no script
# path (and the current directory could hold anyone's install.sh), so fetch it.
src="${BASH_SOURCE[0]:-}"
if [[ -n "$src" && -f "$(dirname "$src")/install.sh" ]]; then
    SLIVE_EDITION=full exec bash "$(dirname "$src")/install.sh"
fi
curl -fsSL https://raw.githubusercontent.com/SoumilB7/Slive/main/install.sh | SLIVE_EDITION=full bash

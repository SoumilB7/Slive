#!/bin/zsh
# Install the WhisperKit converter Slive's training pipeline uses to turn a
# fine-tuned checkpoint into Core ML models — no Xcode required.
#
# - whisperkittools (argmaxinc) goes in its OWN Python 3.11 venv: it pins
#   torch 2.5 / transformers 4.53, which clash with the Slive Server venv.
# - argmaxtools compiles .mlpackage → .mlmodelc with
#   `xcrun coremlcompiler compile <pkg> <dir>`, and coremlcompiler ships only
#   with Xcode. shim/xcrun answers exactly that call with Core ML's runtime
#   compiler (coremltools.utils.compile_model); every other xcrun call passes
#   through to the real one. The pipeline puts shim/ first on the converter's
#   PATH (flowy/training/pipeline.py: converter_env).
#
# Usage: Backend/scripts/install-whisperkit-tools.sh   (~3 GB, one time)
set -euo pipefail

ROOT="${SLIVE_WHISPERKIT_TOOLS:-$HOME/Library/Application Support/Slive/tools/whisperkittools}"
COMMIT=84f77a83c8f530022ae55fbb1a64b3351ef63c7a   # whisperkittools main, Oct 2026

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required (https://docs.astral.sh/uv/) — e.g. brew install uv" >&2
  exit 1
fi

mkdir -p "$ROOT/shim"
uv venv --allow-existing --python 3.11 "$ROOT/venv"
VIRTUAL_ENV="$ROOT/venv" uv pip install \
  "git+https://github.com/argmaxinc/whisperkittools@$COMMIT"

cat > "$ROOT/shim/xcrun" <<SHIM
#!/bin/sh
# Slive: compile Core ML packages without Xcode (see install-whisperkit-tools.sh).
if [ "\$1" = "coremlcompiler" ] && [ "\$2" = "compile" ]; then
  exec "$ROOT/venv/bin/python" -c '
import os, sys
import coremltools as ct
package, out_dir = sys.argv[1], sys.argv[2]
name = os.path.splitext(os.path.basename(package.rstrip("/")))[0]
ct.utils.compile_model(package, destination_path=os.path.join(out_dir, name + ".mlmodelc"))
' "\$3" "\$4"
fi
exec /usr/bin/xcrun "\$@"
SHIM
chmod +x "$ROOT/shim/xcrun"

"$ROOT/venv/bin/whisperkit-generate-model" --help >/dev/null
echo "WhisperKit converter ready: $ROOT/venv/bin/whisperkit-generate-model"
echo "Compile shim:               $ROOT/shim/xcrun"

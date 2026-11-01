#!/bin/sh
# Fails if a settings view hand-rolls a colour, radius or font instead of
# using SliveTheme. Theme/ is the allow-list (it is not scanned).
cd "$(dirname "$0")/../Sources/Slive" || exit 2
FILES="Settings/*.swift Settings/*/*.swift Hotkey/HotkeyRecorderView.swift"
PATTERN='\.white\.opacity\(|Color\.orange|cornerRadius: [0-9]|\.font\(\.system\('
# shellcheck disable=SC2086
if grep -nE "$PATTERN" $FILES; then
    echo "check-tokens: hand-rolled style found; add a SliveTheme token." >&2
    exit 1
fi
echo "check-tokens: ok"

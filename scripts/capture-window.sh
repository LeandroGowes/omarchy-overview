#!/bin/bash
set -euo pipefail

GEOMETRY="${1:-}"
TITLE="${2:-Janela}"

if [[ -z "$GEOMETRY" ]]; then
  echo "Usage: $0 '<x,y widthxheight>' [title]" >&2
  exit 1
fi

# Allow overview layer surface to dismiss and window to focus
sleep 0.20

[[ -f ~/.config/user-dirs.dirs ]] && source ~/.config/user-dirs.dirs
DIR="${OMARCHY_SCREENSHOT_DIR:-${XDG_PICTURES_DIR:-$HOME/Pictures}}/Screenshots"
mkdir -p "$DIR"

FILE="$DIR/screenshot-$(date +'%Y-%m-%d_%H-%M-%S').png"

if ! grim -g "$GEOMETRY" "$FILE"; then
  echo "grim failed to capture geometry $GEOMETRY" >&2
  exit 1
fi

wl-copy --type image/png < "$FILE" 2>/dev/null || true

omarchy-notification-send --image "$FILE" "Captura de Janela" "${TITLE} salva e copiada!" --exec xdg-open "$FILE" || true

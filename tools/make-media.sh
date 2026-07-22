#!/usr/bin/env bash
# Package booth/ for copy to CompactFlash / USB / disk image.
#
# Host machine prepares everything; target is real MS-DOS x86 hardware.
#
# Usage:
#   tools/make-media.sh                  # → ./media/booth
#   tools/make-media.sh /mnt/cf          # copy straight to mounted volume
#   tools/make-media.sh --zip            # also write media/dos-game-browser.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST=""
DO_ZIP=0

for arg in "$@"; do
  case "$arg" in
    --zip) DO_ZIP=1 ;;
    -h|--help)
      sed -n '1,20p' "$0"
      exit 0
      ;;
    *) DEST="$arg" ;;
  esac
done

# Ensure binaries exist
if [[ ! -s "$ROOT/booth/BROWSER.COM" ]]; then
  echo "Building binaries..."
  "$ROOT/tools/build.sh"
fi

# Ensure index if games present
if [[ -d "$ROOT/booth/GAMES" ]] && compgen -G "$ROOT/booth/GAMES/*/GAME.TXT" >/dev/null 2>&1; then
  echo "Refreshing GAMES.LST..."
  python3 "$ROOT/tools/scan-games.py"
elif [[ ! -f "$ROOT/booth/GAMES.LST" ]]; then
  echo "WARNING: no games indexed. Run: python3 tools/fetch-samples.py && python3 tools/scan-games.py" >&2
  # Minimal empty-safe list so browser can at least start and show error? Prefer a stub.
  printf '# GAMES.LST - no games yet\r\n' > "$ROOT/booth/GAMES.LST"
fi

STAGING="$ROOT/media/booth"
rm -rf "$STAGING"
mkdir -p "$STAGING"

# Copy deployable tree only (not sources)
cp -a "$ROOT/booth/." "$STAGING/"

# Drop host-only docs inside GAMES if present
rm -f "$STAGING/GAMES/README.md" 2>/dev/null || true

# Normalize text files to CRLF for DOS
STAGING="$STAGING" python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ["STAGING"])
for p in root.rglob("*"):
    if not p.is_file():
        continue
    if p.suffix.lower() in {".txt", ".lst", ".bat", ".cfg", ".ini", ".md"} or p.name.upper() in {
        "GAME.TXT",
        "GAMES.LST",
        "START.BAT",
    }:
        try:
            data = p.read_bytes()
        except OSError:
            continue
        if b"\0" in data:
            continue
        try:
            text = data.decode("ascii")
        except UnicodeDecodeError:
            try:
                text = data.decode("cp437", errors="replace")
                text = text.encode("ascii", errors="replace").decode("ascii")
            except Exception:
                continue
        text = text.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\r\n")
        p.write_bytes(text.encode("ascii", errors="replace"))
PY

echo "Staged: $STAGING"
find "$STAGING" -maxdepth 2 -type f | head -40
du -sh "$STAGING"

if [[ -n "$DEST" ]]; then
  echo "Copying → $DEST"
  mkdir -p "$DEST"
  cp -a "$STAGING"/. "$DEST"/
  echo "Media copy complete."
fi

if [[ "$DO_ZIP" -eq 1 ]]; then
  ZIP="$ROOT/media/dos-game-browser-booth.zip"
  rm -f "$ZIP"
  (cd "$ROOT/media" && zip -r -q "$(basename "$ZIP")" booth)
  ls -la "$ZIP"
fi

cat <<EOF

Next steps (real hardware):
  1. Format CF/HDD with FAT16 (or FAT12 for floppies); install MS-DOS 5/6 if needed.
  2. Copy contents of media/booth\\ to C:\\ (or a folder on C:).
  3. Optional auto-start: add C:\\START.BAT to AUTOEXEC.BAT
  4. Boot the machine; Ctrl+Alt+Backspace force-exits a hung game.

DOSBox (host test):  tools/run.sh
EOF

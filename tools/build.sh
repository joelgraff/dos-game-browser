#!/usr/bin/env bash
# Assemble BROWSER.COM, ABORT.COM, VDETECT.COM with NASM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

find_nasm() {
  local c
  for c in \
    "$(command -v nasm 2>/dev/null || true)" \
    "$ROOT/../dos-launcher-dev/tools/nasm-root/usr/bin/nasm" \
    "$HOME/Documents/dos-launcher-dev/tools/nasm-root/usr/bin/nasm"
  do
    if [[ -n "$c" && -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

NASM="$(find_nasm)" || {
  echo "nasm not found. Install: sudo apt install nasm   (or equivalent)" >&2
  exit 1
}

echo "NASM=$NASM"
mkdir -p "$ROOT/booth/UTILS"

"$NASM" -f bin -o "$ROOT/booth/UTILS/ABORT.COM" "$ROOT/src/abort.asm"
"$NASM" -f bin -o "$ROOT/booth/UTILS/VDETECT.COM" "$ROOT/src/vdetect.asm"
"$NASM" -f bin -I "$ROOT/src/" -o "$ROOT/booth/BROWSER.COM" "$ROOT/src/browser.asm"

# DOS expects CRLF in batch files
if [[ -f "$ROOT/booth/START.BAT" ]]; then
  python3 - <<PY
from pathlib import Path
p = Path("$ROOT/booth/START.BAT")
t = p.read_text(encoding="ascii", errors="replace").replace("\r\n", "\n").replace("\n", "\r\n")
p.write_bytes(t.encode("ascii"))
PY
fi

ls -la "$ROOT/booth/BROWSER.COM" "$ROOT/booth/UTILS/ABORT.COM" "$ROOT/booth/UTILS/VDETECT.COM"
echo "Build OK"

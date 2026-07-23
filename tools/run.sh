#!/usr/bin/env bash
# Launch DOS Game Browser under DOSBox or DOSBox Staging (host testing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

find_python() {
  local c
  for c in \
    "$(command -v python3 2>/dev/null || true)" \
    "$(command -v python 2>/dev/null || true)"
  do
    if [[ -n "$c" && -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done

  if command -v py >/dev/null 2>&1; then
    echo "py -3"
    return 0
  fi

  return 1
}

find_dosbox() {
  local c
  for c in \
    "$(command -v dosbox-staging 2>/dev/null || true)" \
    "$(command -v dosbox 2>/dev/null || true)" \
    "$ROOT/../dos-launcher-dev/tools/dosbox-staging/dosbox" \
    "$HOME/Documents/dos-launcher-dev/tools/dosbox-staging/dosbox" \
    "$HOME/dos-launcher-dev/tools/dosbox-staging/dosbox"
  do
    if [[ -n "$c" && -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

DB="$(find_dosbox)" || {
  echo "DOSBox not found. Install DOSBox Staging or classic DOSBox, e.g.:" >&2
  echo "  sudo apt install dosbox" >&2
  echo "  # or https://dosbox-staging.github.io/" >&2
  exit 1
}

PYTHON_CMD="$(find_python)" || {
  echo "Python 3 not found. Install Python and ensure python3/python/py is available." >&2
  exit 1
}

if [[ ! -s "$ROOT/booth/BROWSER.COM" ]]; then
  echo "Building browser..."
  "$ROOT/tools/build.sh"
fi

if [[ ! -f "$ROOT/booth/GAMES.LST" ]]; then
  if find "$ROOT/booth/GAMES" -type f \( \
      -iname 'GAME.TXT' -o -iname '*.exe' -o -iname '*.com' -o -iname '*.bat' \
    \) -print -quit | grep -q .; then
    echo "Scanning games..."
    $PYTHON_CMD "$ROOT/tools/scan-games.py"
  else
    echo "No games in booth/GAMES yet."
    echo "  python tools/fetch-samples.py   # or: py -3 tools/fetch-samples.py"
    echo "  python tools/scan-games.py      # or: py -3 tools/scan-games.py"
    # Allow UI to load with empty index message
    printf '# GAMES.LST - empty\r\n' > "$ROOT/booth/GAMES.LST"
  fi
fi

# Generate conf with absolute mount path for this machine
CONF="$ROOT/config/dosbox.local.conf"
cat > "$CONF" << EOF
[sdl]
fullscreen = false

[dosbox]
memsize = 16
machine = svga_s3

[cpu]
core = auto
cputype = auto
cpu_cycles = max
cpu_cycles_protected = max
cpu_throttle = false

[dos]
xms = true
ems = true
umb = true
ver = 6.22

[autoexec]
@echo off
mount C $ROOT/booth
C:
cls
echo DOS Game Browser
if exist UTILS\\ABORT.COM goto have_abort
echo WARNING: UTILS\\ABORT.COM missing - force-exit hotkey unavailable
goto after_abort
:have_abort
UTILS\\ABORT.COM
:after_abort
echo.
echo Ctrl+Alt+Backspace force-exits a running game
echo.
:loop
C:
CD \\
BROWSER.COM
goto loop
EOF

echo "Using DOSBox: $DB"
# Staging uses --noprimaryconf; classic dosbox ignores unknown flags sometimes
if "$DB" --help 2>&1 | grep -q noprimaryconf; then
  exec "$DB" --noprimaryconf --conf "$CONF" "$@"
else
  exec "$DB" -conf "$CONF" -noconsole "$@"
fi

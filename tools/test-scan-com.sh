#!/usr/bin/env bash
# Differential test: SCAN.COM (running under DOSBox) against dgb.py scan.
#
# Two implementations of the same rules will drift. Every case here builds one
# fixture, scans it both ways, and requires the G| lines to match byte for byte.
# That is the whole point of the file: it is the only thing keeping the DOS-side
# scanner honest as the Python one changes.
#
# Requires: nasm, dosbox.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export SDL_VIDEODRIVER=dummy
export SDL_AUDIODRIVER=dummy

find_dosbox() {
  local c
  for c in dosbox-staging dosbox dosbox-x; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  for c in /usr/bin/dosbox /usr/local/bin/dosbox; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

DOSBOX="$(find_dosbox)" || { echo "dosbox not found" >&2; exit 1; }
PY="$(command -v python3 || command -v python)"

if [[ ! -f "$ROOT/bin/SCAN.COM" ]]; then
  echo "bin/SCAN.COM missing; run: python dgb.py build" >&2
  exit 1
fi

PASS=0
FAIL=0
STEP=0

# compare <name> <fixture-root>
# Scans <fixture-root>/GAMES with both scanners and diffs the G| lines.
compare() {
  local name="$1" d="$2"
  STEP=$((STEP + 1))
  echo "[$STEP] $name"

  mkdir -p "$d/DGB"
  cp "$ROOT/bin/SCAN.COM" "$d/DGB/"
  cat > "$d/T.CONF" <<EOF
[sdl]
autolock=false
[autoexec]
mount c $d
c:
cd \\DGB
SCAN.COM C:\\GAMES > OUT.TXT
exit
EOF
  ( cd "$d" && timeout 60 "$DOSBOX" -conf "$d/T.CONF" -noconsole >/dev/null 2>&1 ) || true

  "$PY" "$ROOT/dgb.py" scan --games-root "$d/GAMES" --launcher-dir "$d/PY" \
    --games-root-dos '\GAMES' --sort title --no-headers >/dev/null 2>&1 || true

  grep '^G|' "$d/DGB/GAMES.LST" 2>/dev/null | tr -d '\r' > "$d/dos.txt" || true
  grep '^G|' "$d/PY/GAMES.LST"  2>/dev/null | tr -d '\r' > "$d/py.txt"  || true

  if [[ ! -s "$d/dos.txt" ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: SCAN.COM produced no entries"
    [[ -f "$d/DGB/OUT.TXT" ]] && sed 's/^/    | /' "$d/DGB/OUT.TXT" | tr -d '\r'
    return
  fi

  if diff -q "$d/dos.txt" "$d/py.txt" >/dev/null; then
    PASS=$((PASS + 1))
    echo "  ok ($(wc -l < "$d/dos.txt") entries, identical)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: scanners disagree"
    echo "    --- SCAN.COM            +++ dgb.py scan"
    diff "$d/dos.txt" "$d/py.txt" | sed 's/^/    /'
  fi
}

mkgame() { mkdir -p "$1"; printf 'MZ' > "$1/$2"; }

# ---------------------------------------------------------------------------
d="$WORK/depth"
mkgame "$d/GAMES/JILL" JILL.EXE
mkgame "$d/GAMES/APOGEE/KEEN" KEEN1.EXE
mkgame "$d/GAMES/EPIC/JAZZ/JJ1" JAZZ.EXE
compare "game directories at depths 1, 2 and 3" "$d"

# ---------------------------------------------------------------------------
d="$WORK/nodescend"
mkgame "$d/GAMES/DOOM" DOOM.EXE
mkgame "$d/GAMES/DOOM/UTILS" EDITOR.EXE
mkgame "$d/GAMES/DOOM/DATA" VIEWER.EXE
compare "a game's own subdirectories are not entries" "$d"

# ---------------------------------------------------------------------------
d="$WORK/skip"
mkgame "$d/GAMES/ALPHA" ALPHA.EXE
printf 'MZ' > "$d/GAMES/ALPHA/SETUP.EXE"
printf 'MZ' > "$d/GAMES/ALPHA/INSTALL.EXE"
compare "installers are skipped" "$d"

# ---------------------------------------------------------------------------
d="$WORK/extpref"
mkgame "$d/GAMES/BETA" BETA.COM
printf 'MZ' > "$d/GAMES/BETA/BETA.EXE"
printf 'x'  > "$d/GAMES/BETA/START.BAT"
compare ".BAT beats .EXE beats .COM" "$d"

# ---------------------------------------------------------------------------
d="$WORK/meta"
mkgame "$d/GAMES/KEEN" KEEN1.EXE
printf 'title=Commander Keen\r\nyear=1990\r\ngenre=Platform\r\npublisher=id Software\r\nnote=Invasion of the Vorticons\r\n' \
  > "$d/GAMES/KEEN/GAME.TXT"
compare "every GAME.TXT field round-trips" "$d"

# ---------------------------------------------------------------------------
d="$WORK/exeoverride"
mkgame "$d/GAMES/GAMMA" AAA.EXE
printf 'MZ' > "$d/GAMES/GAMMA/ZZZ.EXE"
printf 'title=Gamma\r\nexe=ZZZ.EXE\r\n' > "$d/GAMES/GAMMA/GAME.TXT"
compare "GAME.TXT exe= overrides the discovered file" "$d"

# ---------------------------------------------------------------------------
d="$WORK/sorting"
for n in ZULU ALPHA MIKE BRAVO; do mkgame "$d/GAMES/$n" "$n.EXE"; done
compare "entries are sorted by title" "$d"

# ---------------------------------------------------------------------------
d="$WORK/titlecase"
mkgame "$d/GAMES/HELLOWOR" HELLO.EXE
mkgame "$d/GAMES/2FAST4YO" BIFI.EXE
compare "directory names are title-cased the same way" "$d"

# ---------------------------------------------------------------------------
echo
if [[ $FAIL -eq 0 ]]; then
  echo "SCAN.COM matches dgb.py scan on all $PASS fixtures"
else
  echo "SCAN.COM differential tests: $PASS passed, $FAIL FAILED"
  exit 1
fi

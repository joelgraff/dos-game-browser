#!/usr/bin/env bash
# Regression checks for tools/scan-games.py: discovery depth, DGB.CFG contents,
# capacity guards and required arguments.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$ROOT/tools/scan-games.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PY="$(command -v python3 || command -v python)"
STEP=0

fail() {
  echo "ASSERT FAIL: $*" >&2
  exit 1
}

step() {
  STEP=$((STEP + 1))
  echo "[$STEP] $*"
}

mkgame() {
  mkdir -p "$1"
  printf 'MZ' > "$1/$2"
}

# ---------------------------------------------------------------------------
step "discovery: games at depth 1, 2 and 3"
d="$WORK/depth"
mkgame "$d/GAMES/JILL" JILL.EXE
mkgame "$d/GAMES/APOGEE/KEEN" KEEN1.EXE
mkgame "$d/GAMES/EPIC/JAZZ/JJ1" JAZZ.EXE
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" --no-headers >/dev/null 2>&1 \
  || fail "scan failed on depth fixture"
lst="$d/DGB/GAMES.LST"
grep -Fq 'G|JILL|JILL.EXE' "$lst"            || fail "depth 1 game missing"
grep -Fq 'G|APOGEE\KEEN|KEEN1.EXE' "$lst"    || fail "depth 2 game missing"
grep -Fq 'G|EPIC\JAZZ\JJ1|JAZZ.EXE' "$lst"   || fail "depth 3 game missing"

# ---------------------------------------------------------------------------
step "discovery: a game's own subdirectories are not separate entries"
d="$WORK/nodescend"
mkgame "$d/GAMES/DOOM" DOOM.EXE
mkgame "$d/GAMES/DOOM/UTILS" EDITOR.EXE
mkgame "$d/GAMES/DOOM/DATA" VIEWER.EXE
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" --no-headers >/dev/null 2>&1 \
  || fail "scan failed on nodescend fixture"
count=$(grep -c '^G|' "$d/DGB/GAMES.LST")
[[ "$count" == "1" ]] || fail "expected 1 entry, got $count (descended into a game)"
grep -Fq 'G|DOOM|DOOM.EXE' "$d/DGB/GAMES.LST" || fail "DOOM entry missing"

# ---------------------------------------------------------------------------
step "discovery: directories deeper than 3 levels are ignored"
d="$WORK/toodeep"
mkgame "$d/GAMES/A/B/C/D" DEEP.EXE
mkgame "$d/GAMES/OK" OK.EXE
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" --no-headers >/dev/null 2>&1 \
  || fail "scan failed on toodeep fixture"
grep -Fq 'DEEP.EXE' "$d/DGB/GAMES.LST" && fail "4-level-deep dir should not be catalogued"
grep -Fq 'G|OK|OK.EXE' "$d/DGB/GAMES.LST" || fail "shallow game missing"

# ---------------------------------------------------------------------------
step "discovery: the launcher's own directory is never catalogued"
d="$WORK/exclude"
mkgame "$d/GAMES/REAL" REAL.EXE
mkdir -p "$d/GAMES/DGB"
printf 'MZ' > "$d/GAMES/DGB/BROWSER.COM"
printf 'x'  > "$d/GAMES/DGB/START.BAT"
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/GAMES/DGB" --no-headers >/dev/null 2>&1 \
  || fail "scan failed on exclude fixture"
grep -Fq '|DGB|' "$d/GAMES/DGB/GAMES.LST" && fail "launcher dir was catalogued as a game"
grep -Fq 'G|REAL|REAL.EXE' "$d/GAMES/DGB/GAMES.LST" || fail "real game missing"

# ---------------------------------------------------------------------------
# Regression: the booth layout nests the games root inside the launcher dir.
# Excluding the launcher dir unconditionally discarded the entire scan.
step "discovery: games root nested inside the launcher dir (booth layout)"
d="$WORK/boothlayout"
mkgame "$d/booth/GAMES/HELLOWOR" HELLO.EXE
mkgame "$d/booth/GAMES/TESTGAME" TEST.EXE
printf 'MZ' > "$d/booth/BROWSER.COM"
"$PY" "$SCAN" --games-root "$d/booth/GAMES" --launcher-dir "$d/booth" \
  --games-root-dos 'GAMES' --no-headers >/dev/null 2>&1 \
  || fail "scan failed on booth layout"
count=$(grep -c '^G|' "$d/booth/GAMES.LST")
[[ "$count" == "2" ]] || fail "expected 2 entries in booth layout, got $count"
grep -Fq 'G|HELLOWOR|HELLO.EXE' "$d/booth/GAMES.LST" || fail "HELLOWOR missing"

# ---------------------------------------------------------------------------
# Regression: a GAME.TXT exe= naming a file that lives in a subdirectory used
# to be recorded against the parent, so the launcher would CHDIR there and fail
# with DOS error 02. The recorded dir must follow the executable.
step "exe=: a subdirectory executable re-points the recorded directory"
d="$WORK/exeloc"
mkdir -p "$d/GAMES/COMMANDE/KEEN"
printf 'x'  > "$d/GAMES/COMMANDE/KEEN.BAT"          # DOSBox-style wrapper
printf 'MZ' > "$d/GAMES/COMMANDE/KEEN/KEEN1.EXE"    # the real executable
printf 'title=Commander Keen\r\nyear=1990\r\npublisher=id\r\nexe=KEEN1.EXE\r\n' \
  > "$d/GAMES/COMMANDE/GAME.TXT"
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" \
  --no-headers >/dev/null 2>"$WORK/exeloc.err" || fail "scan failed on exeloc fixture"
grep -Fq 'G|COMMANDE\KEEN|KEEN1.EXE' "$d/DGB/GAMES.LST" || {
  cat "$d/DGB/GAMES.LST" >&2; fail "dir should be re-pointed to COMMANDE\\KEEN"
}
grep -Fq 'Corrected game directories' "$WORK/exeloc.err" || {
  cat "$WORK/exeloc.err" >&2; fail "expected a correction warning"
}

# ---------------------------------------------------------------------------
step "exe=: matching is case-insensitive (DOS names are, Linux is not)"
d="$WORK/execase"
mkdir -p "$d/GAMES/JILL"
printf 'MZ' > "$d/GAMES/JILL/JILL.EXE"
printf 'title=Jill\r\nyear=1992\r\npublisher=Epic\r\nexe=jill.exe\r\n' \
  > "$d/GAMES/JILL/GAME.TXT"
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" \
  --no-headers >/dev/null 2>&1 || fail "scan failed on execase fixture"
grep -Fq 'G|JILL|JILL.EXE' "$d/DGB/GAMES.LST" || {
  cat "$d/DGB/GAMES.LST" >&2; fail "lowercase exe= should resolve to the real filename"
}

# ---------------------------------------------------------------------------
step "exe=: a name that exists nowhere warns and falls back to a real file"
d="$WORK/exemissing"
mkdir -p "$d/GAMES/GHOST"
printf 'MZ' > "$d/GAMES/GHOST/REAL.EXE"
printf 'title=Ghost\r\nyear=1990\r\npublisher=X\r\nexe=NOSUCH.EXE\r\n' \
  > "$d/GAMES/GHOST/GAME.TXT"
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" \
  --no-headers >/dev/null 2>"$WORK/exemissing.err" || fail "scan failed on exemissing fixture"
grep -Fq 'was not found anywhere' "$WORK/exemissing.err" || {
  cat "$WORK/exemissing.err" >&2; fail "expected a not-found warning"
}

# ---------------------------------------------------------------------------
step "DGB.CFG: GAMES_ROOT derived from an explicit --image-root"
d="$WORK/cfgimage"
mkgame "$d/GAMES/JILL" JILL.EXE
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" --image-root "$d" >/dev/null 2>&1 \
  || fail "scan failed on cfgimage fixture"
grep -q '^GAMES_ROOT=\\GAMES' "$d/DGB/DGB.CFG" || {
  cat "$d/DGB/DGB.CFG" >&2; fail "expected GAMES_ROOT=\\GAMES"
}
file "$d/DGB/DGB.CFG" | grep -q CRLF || fail "DGB.CFG must use CRLF"

# ---------------------------------------------------------------------------
step "DGB.CFG: nested games root under the image root"
d="$WORK/cfgnested"
mkgame "$d/DOS/GAMES/JILL" JILL.EXE
"$PY" "$SCAN" --games-root "$d/DOS/GAMES" --launcher-dir "$d/DGB" --image-root "$d" >/dev/null 2>&1 \
  || fail "scan failed on cfgnested fixture"
grep -q '^GAMES_ROOT=\\DOS\\GAMES' "$d/DGB/DGB.CFG" || {
  cat "$d/DGB/DGB.CFG" >&2; fail "expected GAMES_ROOT=\\DOS\\GAMES"
}

# ---------------------------------------------------------------------------
step "DGB.CFG: explicit --games-root-dos overrides --image-root"
d="$WORK/cfgexplicit"
mkgame "$d/GAMES/JILL" JILL.EXE
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" \
  --image-root "$d" --games-root-dos '\PLAY' >/dev/null 2>&1 \
  || fail "scan failed on cfgexplicit fixture"
grep -q '^GAMES_ROOT=\\PLAY' "$d/DGB/DGB.CFG" || {
  cat "$d/DGB/DGB.CFG" >&2; fail "explicit --games-root-dos should win"
}

# ---------------------------------------------------------------------------
step "DGB.CFG: skipped, with an explanation, when the DOS root is unknown"
d="$WORK/cfgunknown"
mkgame "$d/GAMES/JILL" JILL.EXE
err="$("$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" 2>&1 >/dev/null)" || true
[[ -f "$d/DGB/DGB.CFG" ]] && fail "DGB.CFG must not be guessed"
grep -Fq 'games-root-dos' <<<"$err" || fail "expected guidance naming --games-root-dos"
[[ -f "$d/DGB/GAMES.LST" ]] || fail "index should still be written"

# ---------------------------------------------------------------------------
step "DGB.CFG: --no-cfg suppresses the write"
d="$WORK/cfgoff"
mkgame "$d/GAMES/JILL" JILL.EXE
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" \
  --image-root "$d" --no-cfg >/dev/null 2>&1 || fail "scan failed with --no-cfg"
[[ -f "$d/DGB/DGB.CFG" ]] && fail "--no-cfg should suppress DGB.CFG"

# ---------------------------------------------------------------------------
step "capacity: an oversized catalog is refused and nothing is written"
d="$WORK/toobig"
for i in $(seq 0 349); do
  n=$(printf '%03d' "$i")
  mkgame "$d/GAMES/G$n" "G$n.EXE"
done
if "$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" \
     --no-headers >/dev/null 2>"$WORK/big.err"; then
  fail "expected non-zero exit for an oversized catalog"
fi
[[ -f "$d/DGB/GAMES.LST" ]] && fail "no index should be written when over the limit"
grep -Fq 'exceeds launcher limits' "$WORK/big.err" || {
  cat "$WORK/big.err" >&2; fail "expected a limits error"
}

# ---------------------------------------------------------------------------
step "capacity: headers pushing past the limit suggest --no-headers"
d="$WORK/hdrbig"
for i in $(seq 0 299); do
  n=$(printf '%03d' "$i")
  mkgame "$d/GAMES/G$n" "G$n.EXE"
  printf 'title=Game %s\r\ngenre=Genre%s\r\nexe=G%s.EXE\r\n' "$n" "$((i % 40))" "$n" \
    > "$d/GAMES/G$n/GAME.TXT"
done
if "$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" \
     >/dev/null 2>"$WORK/hdr.err"; then
  fail "expected refusal when headers push past the limit"
fi
grep -Fq -- '--no-headers' "$WORK/hdr.err" || {
  cat "$WORK/hdr.err" >&2; fail "expected --no-headers guidance"
}
# and it fits once headers are dropped
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" --no-headers >/dev/null 2>&1 \
  || fail "300 games should fit with --no-headers"

# ---------------------------------------------------------------------------
step "outputs: GAMES.LST is CRLF, GAME.TXT is CRLF"
d="$WORK/eol"
mkgame "$d/GAMES/JILL" JILL.EXE
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" --no-headers >/dev/null 2>&1
file "$d/DGB/GAMES.LST" | grep -q CRLF     || fail "GAMES.LST must use CRLF"
file "$d/GAMES/JILL/GAME.TXT" | grep -q CRLF || fail "GAME.TXT must use CRLF"

# ---------------------------------------------------------------------------
step "outputs: --emit-review carries the DOS games root into the review file"
d="$WORK/review"
mkgame "$d/GAMES/JILL" JILL.EXE
"$PY" "$SCAN" --games-root "$d/GAMES" --launcher-dir "$d/DGB" \
  --image-root "$d" --emit-review >/dev/null 2>&1 || fail "scan failed with --emit-review"
"$PY" - "$d/DGB/SETUP-REVIEW.json" <<'PY' || fail "review file did not validate"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["games_root_dos"] == "GAMES", d["games_root_dos"]
assert len(d["records"]) == 1, d["records"]
r = d["records"][0]
for k in ("dir", "exe", "title", "needs_review", "candidates", "setup"):
    assert k in r, f"missing {k}"
PY

# ---------------------------------------------------------------------------
step "arguments: the games root is required, never assumed"
if "$PY" "$SCAN" --launcher-dir "$WORK/x" >/dev/null 2>&1; then
  fail "--games-root must be required"
fi
if "$PY" "$SCAN" --games-root "$WORK/depth/GAMES" >/dev/null 2>&1; then
  fail "--launcher-dir must be required"
fi

# ---------------------------------------------------------------------------
step "arguments: a missing games root fails cleanly"
if "$PY" "$SCAN" --games-root "$WORK/nope" --launcher-dir "$WORK/x" >/dev/null 2>&1; then
  fail "expected failure for a nonexistent games root"
fi

echo
echo "scan-games regression tests passed ($STEP checks)"

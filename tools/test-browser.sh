#!/usr/bin/env bash
# Run BROWSER.COM's /T self-test under headless DOSBox against fixture trees
# and assert on the dumped output.
#
# Usage:
#   bash tools/test-browser.sh            # run all cases
#   bash tools/test-browser.sh -k cfg     # only cases whose name matches
#
# Requires: nasm, dosbox.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FILTER="${2:-}"
if [[ "${1:-}" == "-k" ]]; then FILTER="${2:-}"; else FILTER=""; fi

find_nasm() {
  local c
  for c in \
    "$(command -v nasm 2>/dev/null || true)" \
    "$ROOT/../dos-launcher-dev/tools/nasm-root/usr/bin/nasm" \
    "$HOME/Documents/dos-launcher-dev/tools/nasm-root/usr/bin/nasm"
  do
    if [[ -n "$c" && -x "$c" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

find_dosbox() {
  local c
  for c in dosbox-staging dosbox dosbox-x; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  # dosbox is sometimes present but not on a restricted PATH
  for c in /usr/bin/dosbox /usr/local/bin/dosbox; do
    if [[ -x "$c" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

NASM="$(find_nasm)" || { echo "nasm not found" >&2; exit 1; }
DOSBOX="$(find_dosbox)" || { echo "dosbox not found; install with: sudo apt install dosbox" >&2; exit 1; }

BIN="$WORK/BROWSER.COM"
"$NASM" -f bin -o "$BIN" "$ROOT/src/browser.asm"

PASS=0
FAIL=0
FAILED_CASES=()

# run_case <name> <fixture-dir>
# Runs BROWSER.COM /T with CWD = fixture dir; echoes captured stdout.
run_case() {
  local name="$1" dir="$2"
  cp "$BIN" "$dir/BROWSER.COM"
  cat > "$dir/T.CONF" <<EOF
[sdl]
autolock=false
[autoexec]
mount c $dir
c:
BROWSER.COM /T > OUT.TXT
exit
EOF
  ( cd "$dir" && SDL_VIDEODRIVER=dummy timeout 60 "$DOSBOX" -conf "$dir/T.CONF" -noconsole >/dev/null 2>&1 ) || true
  # DOS writes CRLF; normalize for host-side comparison
  tr -d '\r' < "$dir/OUT.TXT" 2>/dev/null || true
}

# expect <name> <output> <expected-line>
expect() {
  local name="$1" out="$2" want="$3"
  if grep -qxF "$want" <<<"$out"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("$name: expected line '$want'")
    echo "  FAIL [$name] expected line: $want"
    echo "  ---- actual ----"
    sed 's/^/  | /' <<<"$out"
    echo "  ----------------"
  fi
}

# expect_re <name> <output> <extended-regex>
expect_re() {
  local name="$1" out="$2" want="$3"
  if grep -qE "$want" <<<"$out"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("$name: expected match /$want/")
    echo "  FAIL [$name] expected match: $want"
    echo "  ---- actual ----"
    sed 's/^/  | /' <<<"$out"
    echo "  ----------------"
  fi
}

skip_case() {
  [[ -n "$FILTER" && "$1" != *"$FILTER"* ]]
}

# Minimal valid GAMES.LST used by the path cases.
make_lst() {
  printf '# test\r\nH|Action\r\nG|JILL|JILL.EXE|Jill of the Jungle|1992|Platform|Epic|A note\r\n' > "$1/GAMES.LST"
}

echo "test-browser: nasm=$NASM dosbox=$DOSBOX"

# ---------------------------------------------------------------------------
# Case: no DGB.CFG -> legacy defaults preserved
# ---------------------------------------------------------------------------
if ! skip_case "cfg-missing"; then
  echo "[cfg-missing] no DGB.CFG -> legacy GAMES\\ defaults"
  d="$WORK/cfg-missing"; mkdir -p "$d"; make_lst "$d"
  out="$(run_case cfg-missing "$d")"
  expect cfg-missing "$out" "CFG=0"
  expect cfg-missing "$out" 'PFX=GAMES\'
  expect cfg-missing "$out" 'PFXABS=\GAMES\'
fi

# ---------------------------------------------------------------------------
# Case: absolute root
# ---------------------------------------------------------------------------
if ! skip_case "cfg-abs"; then
  echo "[cfg-abs] GAMES_ROOT=\\GAMES"
  d="$WORK/cfg-abs"; mkdir -p "$d"; make_lst "$d"
  printf '; DOS Game Browser runtime config\r\nGAMES_ROOT=\\GAMES\r\n' > "$d/DGB.CFG"
  out="$(run_case cfg-abs "$d")"
  expect cfg-abs "$out" "CFG=1"
  expect cfg-abs "$out" 'PFX=GAMES\'
  expect cfg-abs "$out" 'PFXABS=\GAMES\'
fi

# ---------------------------------------------------------------------------
# Case: relative root (no leading backslash)
# ---------------------------------------------------------------------------
if ! skip_case "cfg-rel"; then
  echo "[cfg-rel] GAMES_ROOT=GAMES"
  d="$WORK/cfg-rel"; mkdir -p "$d"; make_lst "$d"
  printf 'GAMES_ROOT=GAMES\r\n' > "$d/DGB.CFG"
  out="$(run_case cfg-rel "$d")"
  expect cfg-rel "$out" "CFG=1"
  expect cfg-rel "$out" 'PFX=GAMES\'
  expect cfg-rel "$out" 'PFXABS=\GAMES\'
fi

# ---------------------------------------------------------------------------
# Case: nested root
# ---------------------------------------------------------------------------
if ! skip_case "cfg-nested"; then
  echo "[cfg-nested] GAMES_ROOT=\\DOS\\GAMES"
  d="$WORK/cfg-nested"; mkdir -p "$d"; make_lst "$d"
  printf 'GAMES_ROOT=\\DOS\\GAMES\r\n' > "$d/DGB.CFG"
  out="$(run_case cfg-nested "$d")"
  expect cfg-nested "$out" 'PFX=DOS\GAMES\'
  expect cfg-nested "$out" 'PFXABS=\DOS\GAMES\'
fi

# ---------------------------------------------------------------------------
# Case: trailing backslash already present -> must not double up
# ---------------------------------------------------------------------------
if ! skip_case "cfg-trailing"; then
  echo "[cfg-trailing] GAMES_ROOT=\\GAMES\\ (trailing slash)"
  d="$WORK/cfg-trailing"; mkdir -p "$d"; make_lst "$d"
  printf 'GAMES_ROOT=\\GAMES\\\r\n' > "$d/DGB.CFG"
  out="$(run_case cfg-trailing "$d")"
  expect cfg-trailing "$out" 'PFX=GAMES\'
  expect cfg-trailing "$out" 'PFXABS=\GAMES\'
fi

# ---------------------------------------------------------------------------
# Case: forward slashes normalized to backslashes
# ---------------------------------------------------------------------------
if ! skip_case "cfg-fwd"; then
  echo "[cfg-fwd] GAMES_ROOT=/DOS/GAMES"
  d="$WORK/cfg-fwd"; mkdir -p "$d"; make_lst "$d"
  printf 'GAMES_ROOT=/DOS/GAMES\r\n' > "$d/DGB.CFG"
  out="$(run_case cfg-fwd "$d")"
  expect cfg-fwd "$out" 'PFX=DOS\GAMES\'
  expect cfg-fwd "$out" 'PFXABS=\DOS\GAMES\'
fi

# ---------------------------------------------------------------------------
# Case: comment line before the key, and spaces after '='
# ---------------------------------------------------------------------------
if ! skip_case "cfg-comment"; then
  echo "[cfg-comment] comment line + spaces after ="
  d="$WORK/cfg-comment"; mkdir -p "$d"; make_lst "$d"
  printf '; a comment mentioning GAMES_ROOT in prose\r\nGAMES_ROOT=  \\PLAY\r\n' > "$d/DGB.CFG"
  out="$(run_case cfg-comment "$d")"
  expect cfg-comment "$out" 'PFX=PLAY\'
  expect cfg-comment "$out" 'PFXABS=\PLAY\'
fi

# ---------------------------------------------------------------------------
# Case: empty value -> fall back to defaults, never produce a bare '\'
# ---------------------------------------------------------------------------
if ! skip_case "cfg-empty"; then
  echo "[cfg-empty] GAMES_ROOT= (empty value)"
  d="$WORK/cfg-empty"; mkdir -p "$d"; make_lst "$d"
  printf 'GAMES_ROOT=\r\n' > "$d/DGB.CFG"
  out="$(run_case cfg-empty "$d")"
  expect cfg-empty "$out" 'PFX=GAMES\'
  expect cfg-empty "$out" 'PFXABS=\GAMES\'
fi

# ---------------------------------------------------------------------------
# Case: a commented-out key must not override the real one.
# Regression: init_paths originally matched GAMES_ROOT= anywhere in the buffer,
# so ';GAMES_ROOT=\WRONGDIR' above the real key silently won.
# ---------------------------------------------------------------------------
if ! skip_case "cfg-commented-key"; then
  echo "[cfg-commented-key] commented-out key above the real key"
  d="$WORK/cfg-commented-key"; mkdir -p "$d"; make_lst "$d"
  printf '; GAMES_ROOT=\\WRONGDIR\r\nGAMES_ROOT=\\RIGHTDIR\r\n' > "$d/DGB.CFG"
  out="$(run_case cfg-commented-key "$d")"
  expect cfg-commented-key "$out" 'PFX=RIGHTDIR\'
  expect cfg-commented-key "$out" 'PFXABS=\RIGHTDIR\'
fi

# ---------------------------------------------------------------------------
# Case: '#' comment style, and key indented with whitespace
# ---------------------------------------------------------------------------
if ! skip_case "cfg-hash-indent"; then
  echo "[cfg-hash-indent] # comment + indented key"
  d="$WORK/cfg-hash-indent"; mkdir -p "$d"; make_lst "$d"
  printf '# GAMES_ROOT=\\NOPE\r\n  GAMES_ROOT=\\INDENT\r\n' > "$d/DGB.CFG"
  out="$(run_case cfg-hash-indent "$d")"
  expect cfg-hash-indent "$out" 'PFX=INDENT\'
  expect cfg-hash-indent "$out" 'PFXABS=\INDENT\'
fi

# ---------------------------------------------------------------------------
# Case: hand-edited lowercase key still works
# ---------------------------------------------------------------------------
if ! skip_case "cfg-lowercase"; then
  echo "[cfg-lowercase] games_root=\\LOWER"
  d="$WORK/cfg-lowercase"; mkdir -p "$d"; make_lst "$d"
  printf 'games_root=\\LOWER\r\n' > "$d/DGB.CFG"
  out="$(run_case cfg-lowercase "$d")"
  expect cfg-lowercase "$out" 'PFX=LOWER\'
  expect cfg-lowercase "$out" 'PFXABS=\LOWER\'
fi

# ---------------------------------------------------------------------------
# Case: index parsing — entry count and titles
# ---------------------------------------------------------------------------
if ! skip_case "index-parse"; then
  echo "[index-parse] header + spacer + game entries"
  d="$WORK/index-parse"; mkdir -p "$d"
  {
    printf '# generated\r\n'
    printf 'H|Action\r\n'
    printf 'G|JILL|JILL.EXE|Jill of the Jungle|1992|Platform|Epic|note one\r\n'
    printf 'G|KEEN|KEEN1.EXE|Commander Keen|1990|Platform|Apogee|note two\r\n'
    printf 'H|Puzzle\r\n'
    printf 'G|TETRIS|TETRIS.EXE|Tetris|1986|Puzzle|Spectrum|note three\r\n'
  } > "$d/GAMES.LST"
  out="$(run_case index-parse "$d")"
  # 2 headers + 1 spacer (before the second header) + 3 games = 6 slots
  expect index-parse "$out" "NENT=6"
  expect_re index-parse "$out" '^E0 T1 O[0-9]+ Action$'
  expect_re index-parse "$out" '^E1 T0 O[0-9]+ Jill of the Jungle$'
  expect_re index-parse "$out" '^E2 T0 O[0-9]+ Commander Keen$'
  expect_re index-parse "$out" '^E3 T2 O[0-9]+ *$'
  expect_re index-parse "$out" '^E4 T1 O[0-9]+ Puzzle$'
  expect_re index-parse "$out" '^E5 T0 O[0-9]+ Tetris$'
  # The R lines re-read each record from disk via the stored offset, so they
  # only match if the recorded offsets are correct.
  expect index-parse "$out" "R1 DIR=JILL EXE=JILL.EXE YEAR=1992 PUB=Epic NOTE=note one"
  expect index-parse "$out" "R2 DIR=KEEN EXE=KEEN1.EXE YEAR=1990 PUB=Apogee NOTE=note two"
  expect index-parse "$out" "R5 DIR=TETRIS EXE=TETRIS.EXE YEAR=1986 PUB=Spectrum NOTE=note three"
fi

# ---------------------------------------------------------------------------
# Case: nested dir with subdirectory path survives the round trip
# ---------------------------------------------------------------------------
if ! skip_case "nested-dir"; then
  echo "[nested-dir] dir field containing a subdirectory"
  d="$WORK/nested-dir"; mkdir -p "$d"
  printf 'G|COMMANDE\\KEEN|KEEN1.EXE|Commander Keen|1990|Platform|Apogee|nested\r\n' > "$d/GAMES.LST"
  out="$(run_case nested-dir "$d")"
  expect nested-dir "$out" "NENT=1"
  expect nested-dir "$out" 'R0 DIR=COMMANDE\KEEN EXE=KEEN1.EXE YEAR=1990 PUB=Apogee NOTE=nested'
fi

# ---------------------------------------------------------------------------
# Case: short line (missing trailing fields) leaves later fields empty,
# rather than reading garbage from the next field.
# ---------------------------------------------------------------------------
if ! skip_case "short-line"; then
  echo "[short-line] record with missing trailing fields"
  d="$WORK/short-line"; mkdir -p "$d"
  printf 'G|SOLO|SOLO.EXE|Solo\r\n' > "$d/GAMES.LST"
  out="$(run_case short-line "$d")"
  expect short-line "$out" "R0 DIR=SOLO EXE=SOLO.EXE YEAR= PUB= NOTE="
fi

# ---------------------------------------------------------------------------
# Case: catalog well beyond the old 64-entry ceiling.
# This is the regression the whole storage rework exists for.
# ---------------------------------------------------------------------------
if ! skip_case "large-catalog"; then
  echo "[large-catalog] 250 games (old build silently truncated at 64)"
  d="$WORK/large-catalog"; mkdir -p "$d"
  {
    printf '# large\r\n'
    for i in $(seq 0 249); do
      n=$(printf '%03d' "$i")
      printf 'G|G%s|G%s.EXE|Game %s|19%02d|Genre|Pub%s|note %s\r\n' \
        "$n" "$n" "$n" "$((80 + i % 20))" "$n" "$n"
    done
  } > "$d/GAMES.LST"
  out="$(run_case large-catalog "$d")"
  expect large-catalog "$out" "NENT=250"
  expect_re large-catalog "$out" '^E0 T0 O[0-9]+ Game 000$'
  expect_re large-catalog "$out" '^E249 T0 O[0-9]+ Game 249$'
  # Last record re-read from disk proves offsets stay correct deep into the file
  expect large-catalog "$out" "R249 DIR=G249 EXE=G249.EXE YEAR=1989 PUB=Pub249 NOTE=note 249"
  expect large-catalog "$out" "R128 DIR=G128 EXE=G128.EXE YEAR=1988 PUB=Pub128 NOTE=note 128"
fi

# ---------------------------------------------------------------------------
# Case: more lines than MAX_ENT (320) must clamp, not overrun the table.
# ---------------------------------------------------------------------------
if ! skip_case "overflow"; then
  echo "[overflow] 400 games clamps at MAX_ENT"
  d="$WORK/overflow"; mkdir -p "$d"
  {
    for i in $(seq 0 399); do
      n=$(printf '%03d' "$i")
      printf 'G|G%s|G%s.EXE|Game %s|1990|Genre|Pub|note\r\n' "$n" "$n" "$n"
    done
  } > "$d/GAMES.LST"
  out="$(run_case overflow "$d")"
  expect overflow "$out" "NENT=320"
fi

# ---------------------------------------------------------------------------
# End-to-end launch cases.
#
# A stub DOS program writes RAN.TXT into whatever directory it starts in, so
# the marker's location proves the launcher resolved the game directory
# correctly and actually EXEC'd the child.
# ---------------------------------------------------------------------------
STUB_SRC="$WORK/stub.asm"
cat > "$STUB_SRC" <<'ASM'
        bits    16
        cpu     8086
        org     100h
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, fn
        int     21h
        jc      done
        mov     bx, ax
        mov     ah, 40h
        mov     cx, 3
        mov     dx, msg
        int     21h
        mov     ah, 3Eh
        int     21h
done:
        mov     ax, 4C00h
        int     21h
fn      db 'RAN.TXT',0
msg     db 'OK',13
ASM
STUB="$WORK/STUB.COM"
"$NASM" -f bin -o "$STUB" "$STUB_SRC"

# run_exec_case <name> <dir> -> stdout of BROWSER.COM /X
run_exec_case() {
  local name="$1" dir="$2"
  cp "$BIN" "$dir/BROWSER.COM"
  cat > "$dir/T.CONF" <<EOF
[sdl]
autolock=false
[autoexec]
mount c $dir
c:
BROWSER.COM /X > OUT.TXT
exit
EOF
  ( cd "$dir" && SDL_VIDEODRIVER=dummy timeout 60 "$DOSBOX" -conf "$dir/T.CONF" -noconsole >/dev/null 2>&1 ) || true
  tr -d '\r' < "$dir/OUT.TXT" 2>/dev/null || true
}

# Legacy layout: launcher dir holds GAMES\, no DGB.CFG.
if ! skip_case "launch-legacy"; then
  echo "[launch-legacy] no DGB.CFG, games under the launcher directory"
  d="$WORK/launch-legacy"; mkdir -p "$d/GAMES/JILL"
  cp "$STUB" "$d/GAMES/JILL/JILL.COM"
  printf 'G|JILL|JILL.COM|Jill|1992|Platform|Epic|note\r\n' > "$d/GAMES.LST"
  out="$(run_exec_case launch-legacy "$d")"
  expect launch-legacy "$out" "XDONE"
  expect launch-legacy "$out" "XREC DIR=JILL EXE=JILL.COM"
  if [[ -f "$d/GAMES/JILL/RAN.TXT" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); FAILED_CASES+=("launch-legacy: child did not run in GAMES/JILL")
    echo "  FAIL [launch-legacy] RAN.TXT missing from GAMES/JILL"
  fi
fi

# Configured root: launcher in DGB\, games at the drive root under GAMES\.
# A decoy DGB\GAMES\JILL must NOT win over the configured \GAMES\JILL.
if ! skip_case "launch-cfg"; then
  echo "[launch-cfg] DGB.CFG root wins over a same-named dir under the launcher"
  d="$WORK/launch-cfg"; mkdir -p "$d/DGB/GAMES/JILL" "$d/GAMES/JILL"
  cp "$STUB" "$d/GAMES/JILL/JILL.COM"
  cp "$STUB" "$d/DGB/GAMES/JILL/JILL.COM"          # decoy
  printf 'GAMES_ROOT=\\GAMES\r\n' > "$d/DGB/DGB.CFG"
  printf 'G|JILL|JILL.COM|Jill|1992|Platform|Epic|note\r\n' > "$d/DGB/GAMES.LST"
  cp "$BIN" "$d/DGB/BROWSER.COM"
  cat > "$d/T.CONF" <<EOF
[sdl]
autolock=false
[autoexec]
mount c $d
c:
cd \\DGB
BROWSER.COM /X > \\OUT.TXT
exit
EOF
  ( cd "$d" && SDL_VIDEODRIVER=dummy timeout 60 "$DOSBOX" -conf "$d/T.CONF" -noconsole >/dev/null 2>&1 ) || true
  out="$(tr -d '\r' < "$d/OUT.TXT" 2>/dev/null || true)"
  expect launch-cfg "$out" "XDONE"
  expect launch-cfg "$out" "XREC DIR=JILL EXE=JILL.COM"
  if [[ -f "$d/GAMES/JILL/RAN.TXT" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); FAILED_CASES+=("launch-cfg: child did not run in the configured \\GAMES\\JILL")
    echo "  FAIL [launch-cfg] RAN.TXT missing from \\GAMES\\JILL"
  fi
  if [[ -f "$d/DGB/GAMES/JILL/RAN.TXT" ]]; then
    FAIL=$((FAIL + 1)); FAILED_CASES+=("launch-cfg: decoy DGB\\GAMES\\JILL was launched instead")
    echo "  FAIL [launch-cfg] decoy under the launcher dir was launched"
  else
    PASS=$((PASS + 1))
  fi
fi

# ---------------------------------------------------------------------------
# ABORT.COM detection. The browser advertises the force-exit chord in its
# header, which is misleading when the TSR was never loaded, so it probes the
# INT 2Fh signature ABORT.COM installs with.
# ---------------------------------------------------------------------------
ABORT_COM="$WORK/ABORT.COM"
"$NASM" -f bin -o "$ABORT_COM" "$ROOT/src/abort.asm"

# run_tsr_case <name> <dir> <load-line>
run_tsr_case() {
  local name="$1" dir="$2" load="$3"
  cp "$BIN" "$dir/BROWSER.COM"
  cat > "$dir/T.CONF" <<EOF
[sdl]
autolock=false
[autoexec]
mount c $dir
c:
$load
BROWSER.COM /T > OUT.TXT
exit
EOF
  ( cd "$dir" && SDL_VIDEODRIVER=dummy timeout 60 "$DOSBOX" -conf "$dir/T.CONF" -noconsole >/dev/null 2>&1 ) || true
  tr -d '\r' < "$dir/OUT.TXT" 2>/dev/null || true
}

if ! skip_case "abort-present"; then
  echo "[abort-present] ABORT.COM resident is detected"
  d="$WORK/abort-present"; mkdir -p "$d/UTILS"; make_lst "$d"
  cp "$ABORT_COM" "$d/UTILS/ABORT.COM"
  out="$(run_tsr_case abort-present "$d" 'UTILS\ABORT.COM')"
  expect abort-present "$out" "ABORT=1"
  # the keyboard diagnostic must be readable back from the TSR
  expect_re abort-present "$out" '^KBD scancodes=[0-9]+ last=[0-9A-F]{2} ctrlalt=[0-9A-F]{2}$'
  # loading the TSR must not stop the batch before the browser runs
  expect abort-present "$out" "NENT=2"
fi

# A game that installs its own INT 09h and never chains keeps the vector, and
# ABORT.COM deliberately does not fight it.
#
# A timer-driven watchdog that stole the vector back was tried and reverted: it
# put us in front of a game that expects exclusive keyboard control, and reading
# port 60h before the game's own handler stopped Commander Keen from starting at
# all. A dead hotkey in such games is a far better outcome than a game that will
# not launch. This case exists to keep that decision from being quietly undone.
if ! skip_case "abort-watchdog"; then
  echo "[abort-watchdog] a game that seizes INT 09h keeps it (by design)"
  cat > "$WORK/steal.asm" <<'ASM'
        bits    16
        cpu     8086
        org     100h
start:
        mov     ax, 2509h
        mov     dx, dummy09
        int     21h
        xor     ax, ax
        mov     es, ax
        mov     ax, [es:46Ch]
        add     ax, 5
        mov     bx, ax
.wait:  mov     ax, [es:46Ch]
        cmp     ax, bx
        jb      .wait
        xor     ax, ax
        mov     es, ax
        mov     ax, [es:24h]
        mov     dx, [es:26h]
        mov     si, msg_kept
        mov     bx, cs
        cmp     dx, bx
        jne     .taken
        cmp     ax, dummy09
        jne     .taken
        jmp     .say
.taken: mov     si, msg_taken
.say:   mov     dx, si
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h
dummy09:
        push    ax
        mov     al, 20h
        out     20h, al
        pop     ax
        iret
msg_kept   db 'WATCHDOG=NO',13,10,'$'
msg_taken  db 'WATCHDOG=YES',13,10,'$'
ASM
  "$NASM" -f bin -o "$WORK/STEAL.COM" "$WORK/steal.asm"

  # Control: with no TSR the thief must keep the vector, proving the probe works.
  d="$WORK/wd-none"; mkdir -p "$d"; cp "$WORK/STEAL.COM" "$d/"
  cat > "$d/T.CONF" <<EOF
[sdl]
autolock=false
[autoexec]
mount c $d
c:
STEAL.COM > OUT.TXT
exit
EOF
  ( cd "$d" && SDL_VIDEODRIVER=dummy timeout 60 "$DOSBOX" -conf "$d/T.CONF" -noconsole >/dev/null 2>&1 ) || true
  out="$(tr -d '\r' < "$d/OUT.TXT" 2>/dev/null || true)"
  expect abort-watchdog "$out" "WATCHDOG=NO"

  # Default (no /W): the thief must STILL keep it -- we do not steal back.
  d="$WORK/wd-tsr"; mkdir -p "$d/UTILS"
  cp "$WORK/STEAL.COM" "$d/"; cp "$ABORT_COM" "$d/UTILS/ABORT.COM"
  cat > "$d/T.CONF" <<EOF
[sdl]
autolock=false
[autoexec]
mount c $d
c:
UTILS\\ABORT.COM
STEAL.COM > OUT.TXT
exit
EOF
  ( cd "$d" && SDL_VIDEODRIVER=dummy timeout 60 "$DOSBOX" -conf "$d/T.CONF" -noconsole >/dev/null 2>&1 ) || true
  out="$(tr -d '\r' < "$d/OUT.TXT" 2>/dev/null || true)"
  expect abort-watchdog "$out" "WATCHDOG=NO"

  # With /W the vector must come back -- the opt-in escape hatch for games
  # that seize the keyboard.
  d="$WORK/wd-optin"; mkdir -p "$d/UTILS"
  cp "$WORK/STEAL.COM" "$d/"; cp "$ABORT_COM" "$d/UTILS/ABORT.COM"
  cat > "$d/T.CONF" <<EOF
[sdl]
autolock=false
[autoexec]
mount c $d
c:
UTILS\\ABORT.COM /W
STEAL.COM > OUT.TXT
exit
EOF
  ( cd "$d" && SDL_VIDEODRIVER=dummy timeout 60 "$DOSBOX" -conf "$d/T.CONF" -noconsole >/dev/null 2>&1 ) || true
  out="$(tr -d '\r' < "$d/OUT.TXT" 2>/dev/null || true)"
  expect abort-watchdog "$out" "WATCHDOG=YES"
fi

if ! skip_case "abort-absent"; then
  echo "[abort-absent] no ABORT.COM is reported as absent"
  d="$WORK/abort-absent"; mkdir -p "$d"; make_lst "$d"
  out="$(run_tsr_case abort-absent "$d" 'REM no tsr')"
  expect abort-absent "$out" "ABORT=0"
  expect abort-absent "$out" "NENT=2"
fi

# ---------------------------------------------------------------------------
# The entry table is 11.5KB of the ~20KB the browser occupies and is idle while
# a child runs, so it is handed back and rebuilt afterwards. Memory-hungry games
# (Commander Keen reports "Out of memory! Try Unloading TSRs!") need it.
# Measured under DOSBox: 612KB free without the hand-back, 624KB with it.
# ---------------------------------------------------------------------------
if ! skip_case "exec-memory"; then
  echo "[exec-memory] the entry table is handed back to the child"
  d="$WORK/exec-memory"; mkdir -p "$d/GAMES/MEMREP"
  cat > "$WORK/memrep.asm" <<'ASM'
        bits    16
        cpu     8086
        org     100h
start:
        mov     ah, 4Ah
        mov     bx, 20h
        int     21h
        mov     ah, 48h
        mov     bx, 0FFFFh
        int     21h
        mov     ax, bx
        mov     cl, 6
        shr     ax, cl
        mov     di, buf
        call    putdec
        mov     byte [di], '$'
        mov     dx, msg
        mov     ah, 09h
        int     21h
        mov     dx, buf
        mov     ah, 09h
        int     21h
        mov     dx, crlf
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h
putdec:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.d1:    xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .d1
.d2:    pop     ax
        add     al, '0'
        mov     [di], al
        inc     di
        dec     cx
        jnz     .d2
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
msg     db 'FREEKB=$'
crlf    db 13,10,'$'
buf     times 8 db 0
ASM
  "$NASM" -f bin -o "$d/GAMES/MEMREP/MEMREP.COM" "$WORK/memrep.asm"
  printf '# t\r\nG|MEMREP|MEMREP.COM|Mem Report|1990|Test|x|n\r\n' > "$d/GAMES.LST"
  cp "$BIN" "$d/BROWSER.COM"
  cat > "$d/T.CONF" <<EOF
[sdl]
autolock=false
[autoexec]
mount c $d
c:
BROWSER.COM /X > OUT.TXT
exit
EOF
  ( cd "$d" && SDL_VIDEODRIVER=dummy timeout 60 "$DOSBOX" -conf "$d/T.CONF" -noconsole >/dev/null 2>&1 ) || true
  out="$(tr -d '\r' < "$d/OUT.TXT" 2>/dev/null || true)"
  freekb="$(grep -oE 'FREEKB=[0-9]+' <<<"$out" | cut -d= -f2 | head -1)"
  if [[ -n "$freekb" && "$freekb" -ge 620 ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("exec-memory: child saw ${freekb:-no} KB free, expected >= 620")
    echo "  FAIL [exec-memory] child saw ${freekb:-no} KB free (expected >= 620)"
    sed 's/^/  | /' <<<"$out"
  fi
  # and the table must be rebuilt afterwards -- this lookup needs its offset
  expect exec-memory "$out" "XREC DIR=MEMREP EXE=MEMREP.COM"
fi

# ---------------------------------------------------------------------------
# Case: missing GAMES.LST reports failure rather than hanging
# ---------------------------------------------------------------------------
if ! skip_case "lst-missing"; then
  echo "[lst-missing] no GAMES.LST"
  d="$WORK/lst-missing"; mkdir -p "$d"
  out="$(run_case lst-missing "$d")"
  expect lst-missing "$out" "LST=FAIL"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "browser self-test: $PASS assertions passed"
else
  echo "browser self-test: $PASS passed, $FAIL FAILED"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi

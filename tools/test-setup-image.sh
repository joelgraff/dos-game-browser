#!/usr/bin/env bash
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

PYTHON_CMD="$(find_python)" || {
  echo "Python 3 not found. Install python3/python/py." >&2
  exit 1
}

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

mk_fixture() {
  local base="$1"
  mkdir -p "$base/img/GAMES/ALPHA" "$base/img/GAMES/BETA" "$base/img/DGB/UTILS"
  printf 'x' > "$base/img/GAMES/ALPHA/PLAY.COM"
  printf 'x' > "$base/img/GAMES/ALPHA/RUN.EXE"
  printf 'x' > "$base/img/GAMES/ALPHA/START.BAT"
  printf 'x' > "$base/img/GAMES/BETA/GAME.EXE"
}

assert_contains() {
  local file="$1"
  local text="$2"
  if ! grep -Fq "$text" "$file"; then
    echo "ASSERT FAIL: expected '$text' in $file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq "$text" "$file"; then
    echo "ASSERT FAIL: did not expect '$text' in $file" >&2
    exit 1
  fi
}

assert_file_equals_text() {
  local file="$1"
  local expected="$2"
  local tmp_expected
  tmp_expected="$(mktemp)"
  printf '%s' "$expected" > "$tmp_expected"
  if ! cmp -s "$file" "$tmp_expected"; then
    echo "ASSERT FAIL: expected exact content '$expected' in $file" >&2
    rm -f "$tmp_expected"
    exit 1
  fi
  rm -f "$tmp_expected"
}

assert_file_not_equals_text() {
  local file="$1"
  local expected="$2"
  local tmp_expected
  tmp_expected="$(mktemp)"
  printf '%s' "$expected" > "$tmp_expected"
  if cmp -s "$file" "$tmp_expected"; then
    echo "ASSERT FAIL: expected $file to differ from '$expected'" >&2
    rm -f "$tmp_expected"
    exit 1
  fi
  rm -f "$tmp_expected"
}

echo "[1/5] conflict mode: fail"
case1="$tmpdir/case1"
mk_fixture "$case1"
printf 'existing' > "$case1/img/DGB/BROWSER.COM"
set +e
$PYTHON_CMD "$ROOT/tools/setup-image.py" \
  --image-root "$case1/img" \
  --scan-root GAMES \
  --launcher-path C:\\DGB \
  --on-conflict fail \
  > "$case1/out.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "ASSERT FAIL: expected conflict fail to return non-zero" >&2
  exit 1
fi
assert_contains "$case1/out.log" "setup failed: refusing to overwrite existing launcher file"
assert_not_contains "$case1/out.log" "Traceback"

echo "[2/5] conflict mode: skip"
case2="$tmpdir/case2"
mk_fixture "$case2"
printf 'existing' > "$case2/img/DGB/BROWSER.COM"
$PYTHON_CMD "$ROOT/tools/setup-image.py" \
  --image-root "$case2/img" \
  --scan-root GAMES \
  --launcher-path C:\\DGB \
  --on-conflict skip \
  > "$case2/out.log" 2>&1
assert_contains "$case2/out.log" "skipped existing files: 1"
assert_contains "$case2/img/DGB/GAMES.LST" "G|ALPHA|START.BAT|"
assert_contains "$case2/img/DGB/GAMES.LST" "G|BETA|GAME.EXE|"
assert_not_contains "$case2/img/DGB/GAMES.LST" "..\\"

# Ensure skip preserved existing launcher file.
assert_file_equals_text "$case2/img/DGB/BROWSER.COM" "existing"

echo "[3/5] conflict mode: overwrite"
case3="$tmpdir/case3"
mk_fixture "$case3"
printf 'existing' > "$case3/img/DGB/BROWSER.COM"
$PYTHON_CMD "$ROOT/tools/setup-image.py" \
  --image-root "$case3/img" \
  --scan-root GAMES \
  --launcher-path C:\\DGB \
  --on-conflict overwrite \
  > "$case3/out.log" 2>&1
assert_contains "$case3/out.log" "overwritten files:      1"

assert_file_not_equals_text "$case3/img/DGB/BROWSER.COM" "existing"

echo "[4/5] custom scan-root path mapping"
case4="$tmpdir/case4"
mkdir -p "$case4/img/DOSGAMES/RPG/FOO" "$case4/img/DGB/UTILS"
printf 'x' > "$case4/img/DOSGAMES/RPG/FOO/START.BAT"
$PYTHON_CMD "$ROOT/tools/setup-image.py" \
  --image-root "$case4/img" \
  --scan-root DOSGAMES \
  --launcher-path C:\\DGB \
  --on-conflict overwrite \
  > "$case4/out.log" 2>&1
assert_contains "$case4/img/DGB/GAMES.LST" "G|RPG\\FOO|START.BAT|"
assert_not_contains "$case4/img/DGB/GAMES.LST" "..\\"

echo "[5/5] invalid scan-root input"
case5="$tmpdir/case5"
mkdir -p "$case5/img/DGB"
set +e
$PYTHON_CMD "$ROOT/tools/setup-image.py" \
  --image-root "$case5/img" \
  --scan-root DOES_NOT_EXIST \
  --launcher-path C:\\DGB \
  --on-conflict overwrite \
  > "$case5/out.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "ASSERT FAIL: expected invalid scan-root to return non-zero" >&2
  exit 1
fi
assert_contains "$case5/out.log" "scan root not found"
assert_not_contains "$case5/out.log" "Traceback"

echo "setup-image smoke tests passed"

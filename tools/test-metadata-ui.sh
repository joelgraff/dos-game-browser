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

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for metadata-ui smoke tests." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
PORT="${METADATA_UI_TEST_PORT:-$((8800 + RANDOM % 1000))}"
cleanup() {
  if [[ -n "${pid:-}" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

mkdir -p "$tmpdir/GAMES/ALPHA" "$tmpdir/GAMES/BETA" "$tmpdir/DGB"
printf 'x' > "$tmpdir/GAMES/ALPHA/START.BAT"
printf 'x' > "$tmpdir/GAMES/BETA/BETA.EXE"
cat > "$tmpdir/DGB/SETUP-REVIEW.json" <<JSON
{
  "version": 1,
  "scan_root": "$tmpdir/GAMES",
  "launcher_dir": "$tmpdir/DGB",
  "records": [
    {
      "dir": "$tmpdir/GAMES/ALPHA",
      "exe": "START.BAT",
      "title": "Alpha",
      "year": "",
      "genre": "Other",
      "publisher": "",
      "note": "",
      "needs_review": true,
      "candidates": ["START.BAT"]
    },
    {
      "dir": "$tmpdir/GAMES/BETA",
      "exe": "BETA.EXE",
      "title": "Beta",
      "year": "",
      "genre": "Action",
      "publisher": "",
      "note": "",
      "needs_review": true,
      "candidates": ["BETA.EXE"]
    }
  ]
}
JSON

echo "[1/7] start metadata-ui"
$PYTHON_CMD "$ROOT/tools/metadata-ui.py" \
  --review-file "$tmpdir/DGB/SETUP-REVIEW.json" \
  --host 127.0.0.1 \
  --port "$PORT" \
  --no-browser \
  > "$tmpdir/server.log" 2>&1 &
pid=$!

echo "[2/7] fetch state"
ok=0
for i in $(seq 1 400); do
  if curl -sf "http://127.0.0.1:$PORT/api/state" > "$tmpdir/state.json"; then
    ok=1
    break
  fi
done
if [[ "$ok" -ne 1 ]]; then
  echo "ASSERT FAIL: metadata-ui did not become ready" >&2
  cat "$tmpdir/server.log" >&2 || true
  exit 1
fi
if ! grep -Fq '"unresolved": 2' "$tmpdir/state.json"; then
  echo "ASSERT FAIL: expected unresolved=2 in api/state" >&2
  cat "$tmpdir/state.json" >&2
  exit 1
fi

echo "[3/7] reject invalid year"
bad_code="$(curl -sS -o "$tmpdir/bad-save.json" -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/api/record/0" \
  -H 'Content-Type: application/json' \
  -d '{"year":"79"}')"
if [[ "$bad_code" != "400" ]]; then
  echo "ASSERT FAIL: expected HTTP 400 for invalid year, got $bad_code" >&2
  cat "$tmpdir/bad-save.json" >&2 || true
  exit 1
fi
if ! grep -Fq 'year must be between 1980 and 2099' "$tmpdir/bad-save.json"; then
  echo "ASSERT FAIL: expected invalid year error details" >&2
  cat "$tmpdir/bad-save.json" >&2 || true
  exit 1
fi

echo "[4/7] save metadata"
curl -sf -X POST "http://127.0.0.1:$PORT/api/record/0" \
  -H 'Content-Type: application/json' \
  -d '{"year":"1992","publisher":"Epic","note":"Shareware"}' \
  > "$tmpdir/save.json"
if ! grep -Fq '"ok": true' "$tmpdir/save.json"; then
  echo "ASSERT FAIL: expected ok=true from save endpoint" >&2
  cat "$tmpdir/save.json" >&2
  exit 1
fi
if ! grep -Fq '"needs_review": false' "$tmpdir/save.json"; then
  echo "ASSERT FAIL: expected needs_review=false after save" >&2
  cat "$tmpdir/save.json" >&2
  exit 1
fi

echo "[5/7] bulk update unresolved"
curl -sf -X POST "http://127.0.0.1:$PORT/api/bulk-update" \
  -H 'Content-Type: application/json' \
  -d '{"ids":[1],"patch":{"year":"1991","publisher":"Apogee","note":"Bulk note"}}' \
  > "$tmpdir/bulk.json"
if ! grep -Fq '"ok": true' "$tmpdir/bulk.json"; then
  echo "ASSERT FAIL: expected ok=true from bulk endpoint" >&2
  cat "$tmpdir/bulk.json" >&2
  exit 1
fi
if ! grep -Fq '"count": 1' "$tmpdir/bulk.json"; then
  echo "ASSERT FAIL: expected count=1 from bulk endpoint" >&2
  cat "$tmpdir/bulk.json" >&2
  exit 1
fi

echo "[6/7] regenerate index"
curl -sf -X POST "http://127.0.0.1:$PORT/api/regenerate" > "$tmpdir/regen.json"
if ! grep -Fq '"ok": true' "$tmpdir/regen.json"; then
  echo "ASSERT FAIL: expected ok=true from regenerate endpoint" >&2
  cat "$tmpdir/regen.json" >&2
  exit 1
fi
if ! grep -Fq 'G|ALPHA|START.BAT|Alpha|1992|Other|Epic|Shareware' "$tmpdir/DGB/GAMES.LST"; then
  echo "ASSERT FAIL: expected regenerated GAMES.LST entry" >&2
  cat "$tmpdir/DGB/GAMES.LST" >&2
  exit 1
fi
if ! grep -Fq 'G|BETA|BETA.EXE|Beta|1991|Action|Apogee|Bulk note' "$tmpdir/DGB/GAMES.LST"; then
  echo "ASSERT FAIL: expected regenerated GAMES.LST beta entry" >&2
  cat "$tmpdir/DGB/GAMES.LST" >&2
  exit 1
fi

echo "[7/7] verify file outputs"
if ! grep -Fq 'year=1992' "$tmpdir/GAMES/ALPHA/GAME.TXT"; then
  echo "ASSERT FAIL: expected year in GAME.TXT" >&2
  cat "$tmpdir/GAMES/ALPHA/GAME.TXT" >&2
  exit 1
fi
if ! grep -Fq 'publisher=Epic' "$tmpdir/GAMES/ALPHA/GAME.TXT"; then
  echo "ASSERT FAIL: expected publisher in GAME.TXT" >&2
  cat "$tmpdir/GAMES/ALPHA/GAME.TXT" >&2
  exit 1
fi
if ! grep -Fq 'year=1991' "$tmpdir/GAMES/BETA/GAME.TXT"; then
  echo "ASSERT FAIL: expected bulk year in BETA GAME.TXT" >&2
  cat "$tmpdir/GAMES/BETA/GAME.TXT" >&2
  exit 1
fi
if ! grep -Fq 'publisher=Apogee' "$tmpdir/GAMES/BETA/GAME.TXT"; then
  echo "ASSERT FAIL: expected bulk publisher in BETA GAME.TXT" >&2
  cat "$tmpdir/GAMES/BETA/GAME.TXT" >&2
  exit 1
fi
if ! grep -Fq '"needs_review": false' "$tmpdir/DGB/SETUP-REVIEW.json"; then
  echo "ASSERT FAIL: expected updated needs_review=false in review file" >&2
  cat "$tmpdir/DGB/SETUP-REVIEW.json" >&2
  exit 1
fi

echo "metadata-ui smoke tests passed"

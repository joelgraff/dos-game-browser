#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Running metadata-ui bash harness..."
bash "$ROOT/tools/test-metadata-ui.sh"

if command -v pwsh >/dev/null 2>&1; then
  echo "Running metadata-ui PowerShell harness with pwsh..."
  pwsh -File "$ROOT/tools/test-metadata-ui.ps1"
elif command -v powershell >/dev/null 2>&1; then
  echo "Running metadata-ui PowerShell harness with powershell..."
  powershell -ExecutionPolicy Bypass -File "$ROOT/tools/test-metadata-ui.ps1"
else
  echo "PowerShell runtime not found (pwsh/powershell). Skipping PowerShell harness."
fi

echo "All available metadata-ui regression harnesses completed."

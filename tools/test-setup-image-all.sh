#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Running setup-image bash harness..."
bash "$ROOT/tools/test-setup-image.sh"

if command -v pwsh >/dev/null 2>&1; then
  echo "Running setup-image PowerShell harness with pwsh..."
  pwsh -File "$ROOT/tools/test-setup-image.ps1"
elif command -v powershell >/dev/null 2>&1; then
  echo "Running setup-image PowerShell harness with powershell..."
  powershell -ExecutionPolicy Bypass -File "$ROOT/tools/test-setup-image.ps1"
else
  echo "PowerShell runtime not found (pwsh/powershell). Skipping PowerShell harness."
fi

echo "All available setup-image regression harnesses completed."

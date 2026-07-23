#!/usr/bin/env pwsh
# Launch DOS Game Browser under DOSBox / DOSBox Staging on Windows or Linux PowerShell.
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { '' }

function Invoke-Python {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $python3 = Get-Command python3 -ErrorAction SilentlyContinue
    if ($python3) {
        & $python3.Source @Arguments
        return
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        & $python.Source @Arguments
        return
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        & $py.Source -3 @Arguments
        return
    }

    throw 'Python not found. Install Python 3 and ensure python3, python, or py is on PATH.'
}

function Find-DosBox {
    $candidates = @('dosbox-staging', 'dosbox')
    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and (Test-Path $cmd.Source)) {
            return $cmd.Source
        }
    }

    $fallbacks = @(
        (Join-Path $Root '..\dos-launcher-dev\tools\dosbox-staging\dosbox'),
        (Join-Path $Root '..\dos-launcher-dev\tools\dosbox-staging\dosbox.exe'),
        $(if ($HomeDir) { Join-Path $HomeDir 'Documents\dos-launcher-dev\tools\dosbox-staging\dosbox' } else { $null }),
        $(if ($HomeDir) { Join-Path $HomeDir 'Documents\dos-launcher-dev\tools\dosbox-staging\dosbox.exe' } else { $null })
    )

    foreach ($path in $fallbacks) {
        if ($path -and (Test-Path $path)) {
            return (Resolve-Path $path).Path
        }
    }

    throw "DOSBox not found. Install DOSBox Staging or classic DOSBox and ensure it is on PATH."
}

$db = Find-DosBox

$browserCom = Join-Path $Root 'booth\BROWSER.COM'
if (-not (Test-Path $browserCom) -or (Get-Item $browserCom).Length -eq 0) {
    Write-Host 'Building browser...'
    & (Join-Path $Root 'tools\build.ps1')
}

$gamesLst = Join-Path $Root 'booth\GAMES.LST'
if (-not (Test-Path $gamesLst)) {
    $gamesRoot = Join-Path $Root 'booth\GAMES'
    $hasGameInputs = $false
    if (Test-Path $gamesRoot) {
        $hasGameInputs = [bool](Get-ChildItem -Path $gamesRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -ieq 'GAME.TXT' -or
                $_.Extension -ieq '.exe' -or
                $_.Extension -ieq '.com' -or
                $_.Extension -ieq '.bat'
            } |
            Select-Object -First 1)
    }

    if ($hasGameInputs) {
        Write-Host 'Scanning games...'
        Invoke-Python -Arguments @((Join-Path $Root 'tools\scan-games.py'))
    } else {
        Write-Host 'No games in booth/GAMES yet.'
        Write-Host '  python tools/fetch-samples.py   # or: py -3 tools/fetch-samples.py'
        Write-Host '  python tools/scan-games.py      # or: py -3 tools/scan-games.py'
        Set-Content -Path $gamesLst -Value "# GAMES.LST - empty`r`n" -Encoding ascii -NoNewline
    }
}

$conf = Join-Path $Root 'config\dosbox.local.conf'
$mountPath = (Resolve-Path (Join-Path $Root 'booth')).Path

@"
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
mount C "$mountPath"
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
"@ | Set-Content -Path $conf -Encoding ascii -NoNewline

Write-Host "Using DOSBox: $db"
$helpText = & $db --help 2>&1 | Out-String
if ($helpText -match 'noprimaryconf') {
    & $db --noprimaryconf --conf $conf @args
} else {
    & $db -conf $conf -noconsole @args
}

#!/usr/bin/env pwsh
# Assemble BROWSER.COM, ABORT.COM, VDETECT.COM with NASM (Windows-friendly).
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { '' }

function Find-Nasm {
    $candidate = Get-Command nasm -ErrorAction SilentlyContinue
    if ($candidate -and (Test-Path $candidate.Source)) {
        return $candidate.Source
    }

    $fallbacks = @(
        (Join-Path $Root '..\dos-launcher-dev\tools\nasm-root\usr\bin\nasm'),
        (Join-Path $Root '..\dos-launcher-dev\tools\nasm-root\usr\bin\nasm.exe'),
        $(if ($HomeDir) { Join-Path $HomeDir 'Documents\dos-launcher-dev\tools\nasm-root\usr\bin\nasm' } else { $null }),
        $(if ($HomeDir) { Join-Path $HomeDir 'Documents\dos-launcher-dev\tools\nasm-root\usr\bin\nasm.exe' } else { $null })
    )

    foreach ($path in $fallbacks) {
        if ($path -and (Test-Path $path)) {
            return (Resolve-Path $path).Path
        }
    }

    throw 'nasm not found. Install NASM and ensure it is on PATH.'
}

$Nasm = Find-Nasm
Write-Host "NASM=$Nasm"

$utilsDir = Join-Path $Root 'booth\UTILS'
New-Item -ItemType Directory -Force -Path $utilsDir | Out-Null

& $Nasm -f bin -o (Join-Path $Root 'booth\UTILS\ABORT.COM') (Join-Path $Root 'src\abort.asm')
& $Nasm -f bin -o (Join-Path $Root 'booth\UTILS\VDETECT.COM') (Join-Path $Root 'src\vdetect.asm')
& $Nasm -f bin -o (Join-Path $Root 'booth\BROWSER.COM') (Join-Path $Root 'src\browser.asm')

$startBat = Join-Path $Root 'booth\START.BAT'
if (Test-Path $startBat) {
    $content = Get-Content -Path $startBat -Raw -Encoding ascii
    $normalized = ($content -replace "`r`n", "`n" -replace "`r", "`n") -replace "`n", "`r`n"
    Set-Content -Path $startBat -Value $normalized -Encoding ascii -NoNewline
}

Get-Item (Join-Path $Root 'booth\BROWSER.COM'), (Join-Path $Root 'booth\UTILS\ABORT.COM'), (Join-Path $Root 'booth\UTILS\VDETECT.COM') |
    Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize

Write-Host 'Build OK'

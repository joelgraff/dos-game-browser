#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Invoke-Python {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $python3 = Get-Command python3 -ErrorAction SilentlyContinue
    $python = Get-Command python -ErrorAction SilentlyContinue
    $py = Get-Command py -ErrorAction SilentlyContinue

    if ($python3) {
        & $python3.Source @Arguments
        if (-not $AllowFailure -and $LASTEXITCODE -ne 0) { throw "Python command failed: $($LASTEXITCODE)" }
        return $LASTEXITCODE
    }
    if ($python) {
        & $python.Source @Arguments
        if (-not $AllowFailure -and $LASTEXITCODE -ne 0) { throw "Python command failed: $($LASTEXITCODE)" }
        return $LASTEXITCODE
    }
    if ($py) {
        & $py.Source -3 @Arguments
        if (-not $AllowFailure -and $LASTEXITCODE -ne 0) { throw "Python command failed: $($LASTEXITCODE)" }
        return $LASTEXITCODE
    }

    throw 'Python not found. Install python3/python/py.'
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $content = Get-Content -Path $Path -Raw
    if (-not $content.Contains($Text)) {
        throw "ASSERT FAIL: expected '$Text' in $Path"
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $content = Get-Content -Path $Path -Raw
    if ($content.Contains($Text)) {
        throw "ASSERT FAIL: did not expect '$Text' in $Path"
    }
}

function Assert-FileEqualsText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    if ($text -ne $Expected) {
        throw "ASSERT FAIL: expected exact content '$Expected' in $Path"
    }
}

function Assert-FileNotEqualsText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    if ($text -eq $Expected) {
        throw "ASSERT FAIL: expected $Path to differ from '$Expected'"
    }
}

function New-Fixture {
    param([Parameter(Mandatory = $true)][string]$Base)

    New-Item -ItemType Directory -Force -Path (Join-Path $Base 'img/GAMES/ALPHA') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Base 'img/GAMES/BETA') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Base 'img/DGB/UTILS') | Out-Null

    Set-Content -Path (Join-Path $Base 'img/GAMES/ALPHA/PLAY.COM') -Value 'x' -Encoding ascii -NoNewline
    Set-Content -Path (Join-Path $Base 'img/GAMES/ALPHA/RUN.EXE') -Value 'x' -Encoding ascii -NoNewline
    Set-Content -Path (Join-Path $Base 'img/GAMES/ALPHA/START.BAT') -Value 'x' -Encoding ascii -NoNewline
    Set-Content -Path (Join-Path $Base 'img/GAMES/BETA/GAME.EXE') -Value 'x' -Encoding ascii -NoNewline
}

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

try {
    Write-Host '[1/5] conflict mode: fail'
    $case1 = Join-Path $tmpDir 'case1'
    New-Fixture -Base $case1
    Set-Content -Path (Join-Path $case1 'img/DGB/BROWSER.COM') -Value 'existing' -Encoding ascii -NoNewline
    $out1 = Join-Path $case1 'out.log'
    $rc = Invoke-Python -AllowFailure -Arguments @(
        (Join-Path $Root 'tools/setup-image.py'),
        '--image-root', (Join-Path $case1 'img'),
        '--scan-root', 'GAMES',
        '--launcher-path', 'C:\DGB',
        '--on-conflict', 'fail'
    ) *> $out1
    if ($rc -eq 0) { throw 'ASSERT FAIL: expected conflict fail to return non-zero' }
    Assert-Contains -Path $out1 -Text 'setup failed: refusing to overwrite existing launcher file'
    Assert-NotContains -Path $out1 -Text 'Traceback'

    Write-Host '[2/5] conflict mode: skip'
    $case2 = Join-Path $tmpDir 'case2'
    New-Fixture -Base $case2
    Set-Content -Path (Join-Path $case2 'img/DGB/BROWSER.COM') -Value 'existing' -Encoding ascii -NoNewline
    $out2 = Join-Path $case2 'out.log'
    Invoke-Python -Arguments @(
        (Join-Path $Root 'tools/setup-image.py'),
        '--image-root', (Join-Path $case2 'img'),
        '--scan-root', 'GAMES',
        '--launcher-path', 'C:\DGB',
        '--on-conflict', 'skip'
    ) *> $out2
    Assert-Contains -Path $out2 -Text 'skipped existing files: 1'
    Assert-Contains -Path (Join-Path $case2 'img/DGB/GAMES.LST') -Text 'G|ALPHA|START.BAT|'
    Assert-Contains -Path (Join-Path $case2 'img/DGB/GAMES.LST') -Text 'G|BETA|GAME.EXE|'
    Assert-NotContains -Path (Join-Path $case2 'img/DGB/GAMES.LST') -Text '..\'
    Assert-FileEqualsText -Path (Join-Path $case2 'img/DGB/BROWSER.COM') -Expected 'existing'

    Write-Host '[3/5] conflict mode: overwrite'
    $case3 = Join-Path $tmpDir 'case3'
    New-Fixture -Base $case3
    Set-Content -Path (Join-Path $case3 'img/DGB/BROWSER.COM') -Value 'existing' -Encoding ascii -NoNewline
    $out3 = Join-Path $case3 'out.log'
    Invoke-Python -Arguments @(
        (Join-Path $Root 'tools/setup-image.py'),
        '--image-root', (Join-Path $case3 'img'),
        '--scan-root', 'GAMES',
        '--launcher-path', 'C:\DGB',
        '--on-conflict', 'overwrite'
    ) *> $out3
    Assert-Contains -Path $out3 -Text 'overwritten files:      1'
    Assert-FileNotEqualsText -Path (Join-Path $case3 'img/DGB/BROWSER.COM') -Expected 'existing'

    Write-Host '[4/5] custom scan-root path mapping'
    $case4 = Join-Path $tmpDir 'case4'
    New-Item -ItemType Directory -Force -Path (Join-Path $case4 'img/DOSGAMES/RPG/FOO') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $case4 'img/DGB/UTILS') | Out-Null
    Set-Content -Path (Join-Path $case4 'img/DOSGAMES/RPG/FOO/START.BAT') -Value 'x' -Encoding ascii -NoNewline
    $out4 = Join-Path $case4 'out.log'
    Invoke-Python -Arguments @(
        (Join-Path $Root 'tools/setup-image.py'),
        '--image-root', (Join-Path $case4 'img'),
        '--scan-root', 'DOSGAMES',
        '--launcher-path', 'C:\DGB',
        '--on-conflict', 'overwrite'
    ) *> $out4
    Assert-Contains -Path (Join-Path $case4 'img/DGB/GAMES.LST') -Text 'G|RPG\FOO|START.BAT|'
    Assert-NotContains -Path (Join-Path $case4 'img/DGB/GAMES.LST') -Text '..\'

    Write-Host '[5/5] invalid scan-root input'
    $case5 = Join-Path $tmpDir 'case5'
    New-Item -ItemType Directory -Force -Path (Join-Path $case5 'img/DGB') | Out-Null
    $out5 = Join-Path $case5 'out.log'
    $rc5 = Invoke-Python -AllowFailure -Arguments @(
        (Join-Path $Root 'tools/setup-image.py'),
        '--image-root', (Join-Path $case5 'img'),
        '--scan-root', 'DOES_NOT_EXIST',
        '--launcher-path', 'C:\DGB',
        '--on-conflict', 'overwrite'
    ) *> $out5
    if ($rc5 -eq 0) { throw 'ASSERT FAIL: expected invalid scan-root to return non-zero' }
    Assert-Contains -Path $out5 -Text 'scan root not found'
    Assert-NotContains -Path $out5 -Text 'Traceback'

    Write-Host 'setup-image smoke tests passed'
}
finally {
    if (Test-Path $tmpDir) {
        Remove-Item -Path $tmpDir -Recurse -Force
    }
}

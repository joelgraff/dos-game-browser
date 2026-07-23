#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Get-PythonCommand {
    $python3 = Get-Command python3 -ErrorAction SilentlyContinue
    if ($python3) {
        return @{ Exe = $python3.Source; Prefix = @() }
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return @{ Exe = $python.Source; Prefix = @() }
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return @{ Exe = $py.Source; Prefix = @('-3') }
    }

    throw 'Python not found. Install python3/python/py.'
}

if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
    throw 'curl is required for metadata-ui smoke tests.'
}

$pyCmd = Get-PythonCommand
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
$port = if ($env:METADATA_UI_TEST_PORT) { [int]$env:METADATA_UI_TEST_PORT } else { Get-Random -Minimum 8800 -Maximum 9800 }
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$serverProc = $null
try {
    New-Item -ItemType Directory -Path (Join-Path $tmpDir 'GAMES/ALPHA') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpDir 'GAMES/BETA') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpDir 'DGB') -Force | Out-Null
    Set-Content -Path (Join-Path $tmpDir 'GAMES/ALPHA/START.BAT') -Value 'x' -Encoding ascii -NoNewline
    Set-Content -Path (Join-Path $tmpDir 'GAMES/BETA/BETA.EXE') -Value 'x' -Encoding ascii -NoNewline

    $reviewPath = Join-Path $tmpDir 'DGB/SETUP-REVIEW.json'
    $review = @{
        version = 1
        scan_root = (Join-Path $tmpDir 'GAMES')
        launcher_dir = (Join-Path $tmpDir 'DGB')
        records = @(
            @{
                dir = (Join-Path $tmpDir 'GAMES/ALPHA')
                exe = 'START.BAT'
                title = 'Alpha'
                year = ''
                genre = 'Other'
                publisher = ''
                note = ''
                needs_review = $true
                candidates = @('START.BAT')
            },
            @{
                dir = (Join-Path $tmpDir 'GAMES/BETA')
                exe = 'BETA.EXE'
                title = 'Beta'
                year = ''
                genre = 'Action'
                publisher = ''
                note = ''
                needs_review = $true
                candidates = @('BETA.EXE')
            }
        )
    }
    $review | ConvertTo-Json -Depth 8 | Set-Content -Path $reviewPath -Encoding utf8

    Write-Host '[1/7] start metadata-ui'
    $serverLog = Join-Path $tmpDir 'server.log'
    $serverErr = Join-Path $tmpDir 'server.err.log'
    $args = @()
    $args += $pyCmd.Prefix
    $args += @(
        (Join-Path $Root 'tools/metadata-ui.py'),
        '--review-file', $reviewPath,
        '--host', '127.0.0.1',
        '--port', "$port",
        '--no-browser'
    )
    $serverProc = Start-Process -FilePath $pyCmd.Exe -ArgumentList $args -NoNewWindow -RedirectStandardOutput $serverLog -RedirectStandardError $serverErr -PassThru

    Write-Host '[2/7] fetch state'
    $ok = $false
    $state = $null
    for ($i = 0; $i -lt 400; $i++) {
        try {
            $state = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/state" -Method Get -ErrorAction Stop
            $ok = $true
            break
        }
        catch {
        }
    }
    if (-not $ok) {
        $out = if (Test-Path $serverLog) { Get-Content -Path $serverLog -Raw } else { '' }
        $err = if (Test-Path $serverErr) { Get-Content -Path $serverErr -Raw } else { '' }
        throw "ASSERT FAIL: metadata-ui did not become ready. Out: $out Err: $err"
    }
    if ($state.unresolved -ne 2) {
        throw 'ASSERT FAIL: expected unresolved=2 in api/state'
    }

    Write-Host '[3/7] reject invalid year'
    $badBody = @{ year = '79' } | ConvertTo-Json -Depth 3
    $badResp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/record/0" -Method Post -ContentType 'application/json' -Body $badBody -SkipHttpErrorCheck
    if ($badResp.StatusCode -ne 400) {
        throw "ASSERT FAIL: expected HTTP 400 for invalid year, got $($badResp.StatusCode)"
    }
    if (-not $badResp.Content.Contains('year must be between 1980 and 2099')) {
        throw 'ASSERT FAIL: expected invalid year error details'
    }

    Write-Host '[4/7] save metadata'
    $body = @{ year = '1992'; publisher = 'Epic'; note = 'Shareware' } | ConvertTo-Json -Depth 5
    $save = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/record/0" -Method Post -ContentType 'application/json' -Body $body
    if (-not $save.ok) {
        throw 'ASSERT FAIL: expected ok=true from save endpoint'
    }
    if ($save.record.needs_review) {
        throw 'ASSERT FAIL: expected needs_review=false after save'
    }

    Write-Host '[5/7] bulk update unresolved'
    $bulkBody = @{ ids = @(1); patch = @{ year = '1991'; publisher = 'Apogee'; note = 'Bulk note' } } | ConvertTo-Json -Depth 8
    $bulk = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/bulk-update" -Method Post -ContentType 'application/json' -Body $bulkBody
    if (-not $bulk.ok) {
        throw 'ASSERT FAIL: expected ok=true from bulk endpoint'
    }
    if ($bulk.count -ne 1) {
        throw 'ASSERT FAIL: expected count=1 from bulk endpoint'
    }

    Write-Host '[6/7] regenerate index'
    $regen = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/regenerate" -Method Post
    if (-not $regen.ok) {
        throw 'ASSERT FAIL: expected ok=true from regenerate endpoint'
    }
    $lstPath = Join-Path $tmpDir 'DGB/GAMES.LST'
    $lstText = Get-Content -Path $lstPath -Raw
    if (-not $lstText.Contains('G|ALPHA|START.BAT|Alpha|1992|Other|Epic|Shareware')) {
        throw 'ASSERT FAIL: expected regenerated GAMES.LST entry'
    }
    if (-not $lstText.Contains('G|BETA|BETA.EXE|Beta|1991|Action|Apogee|Bulk note')) {
        throw 'ASSERT FAIL: expected regenerated GAMES.LST beta entry'
    }

    Write-Host '[7/7] verify file outputs'
    $gameTxt = Get-Content -Path (Join-Path $tmpDir 'GAMES/ALPHA/GAME.TXT') -Raw
    if (-not $gameTxt.Contains('year=1992')) {
        throw 'ASSERT FAIL: expected year in GAME.TXT'
    }
    if (-not $gameTxt.Contains('publisher=Epic')) {
        throw 'ASSERT FAIL: expected publisher in GAME.TXT'
    }

    $betaTxt = Get-Content -Path (Join-Path $tmpDir 'GAMES/BETA/GAME.TXT') -Raw
    if (-not $betaTxt.Contains('year=1991')) {
        throw 'ASSERT FAIL: expected bulk year in BETA GAME.TXT'
    }
    if (-not $betaTxt.Contains('publisher=Apogee')) {
        throw 'ASSERT FAIL: expected bulk publisher in BETA GAME.TXT'
    }

    $reviewUpdated = Get-Content -Path $reviewPath -Raw
    if (-not $reviewUpdated.Contains('"needs_review": false')) {
        throw 'ASSERT FAIL: expected updated needs_review=false in review file'
    }

    Write-Host 'metadata-ui smoke tests passed'
}
finally {
    if ($serverProc -and -not $serverProc.HasExited) {
        Stop-Process -Id $serverProc.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $tmpDir) {
        Remove-Item -Path $tmpDir -Recurse -Force
    }
}

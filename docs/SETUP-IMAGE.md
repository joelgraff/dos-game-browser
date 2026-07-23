# Mounted Image Setup (Phase 1)

This guide covers first-time bootstrap of DOS Game Browser into an existing
mounted DOS image that already contains games.

## Goals

- Install launcher artifacts into a target DOS directory (for example `C:\DGB`).
- Scan a game tree recursively for launchable files.
- Generate `GAMES.LST` and placeholder `GAME.TXT` metadata.
- Produce `SETUP-REVIEW.json` for post-scan metadata cleanup.

## Basic usage

```bash
python tools/setup-image.py --image-root /path/to/mounted/image
```

## One-shot deployment flow

If you want Phase 1 and Phase 2 in a single script, use the deployment driver:

```bash
python tools/deploy-image.py --image-root ~/Documents/TESTIMG
```

That wrapper runs `setup-image.py` first, then launches `metadata-ui.py`
against the generated review file.

Useful options:

```bash
python tools/deploy-image.py --image-root ~/Documents/TESTIMG --no-browser
python tools/deploy-image.py --image-root ~/Documents/TESTIMG --setup-only
python tools/deploy-image.py --image-root ~/Documents/TESTIMG --port 8785
```

Default behavior:

- `--scan-root` defaults to `GAMES` under `--image-root`.
- Launcher files are installed into `C:\DGB` under the mounted image.
- Existing launcher files cause a safe failure (`--on-conflict fail`).

## Common examples

Scan default `GAMES` and install launcher at `C:\DGB`:

```bash
python tools/setup-image.py --image-root /mnt/dos
```

Scan a custom root and use a different launcher DOS path:

```bash
python tools/setup-image.py --image-root /mnt/dos --scan-root DOSGAMES --launcher-path C:\\LAUNCH
```

Preview writes only:

```bash
python tools/setup-image.py --image-root /mnt/dos --dry-run --verbose
```

## Conflict policy

Use `--on-conflict` to control behavior when target launcher files already
exist (`BROWSER.COM`, `START.BAT`, `UTILS\ABORT.COM`, `UTILS\VDETECT.COM`).

- `fail` (default): abort immediately, no overwrite.
- `skip`: keep existing files and continue.
- `overwrite`: replace existing files with current booth versions.

Examples:

```bash
python tools/setup-image.py --image-root /mnt/dos --on-conflict skip
python tools/setup-image.py --image-root /mnt/dos --on-conflict overwrite
```

## Path semantics

`GAMES.LST` entries are generated relative to `--scan-root`.

That means:

- If `--scan-root` is `GAMES`, a game in `GAMES/ALPHA` becomes `dir=ALPHA`.
- If `--scan-root` is `DOSGAMES`, a game in `DOSGAMES/RPG/FOO` becomes
  `dir=RPG\FOO`.

This keeps runtime paths stable and avoids parent-relative entries.

## Executable selection

For each discovered directory, launch-file preference is:

1. `.BAT`
2. `.EXE`
3. `.COM`

Within each extension class, preferred names such as `start.bat` and
`game.exe` are prioritized before generic candidates.

## Outputs

Written under launcher target directory unless `--dry-run`:

- `GAMES.LST`
- `SETUP-REVIEW.json`
- copied launcher files (`BROWSER.COM`, `START.BAT`, `UTILS/*`)

Also writes or updates per-folder `GAME.TXT` placeholders under scanned game
folders when metadata is missing.

## Recommended workflow

1. Run setup with `--dry-run --verbose` first.
2. Run real setup with chosen conflict policy.
3. Review generated `SETUP-REVIEW.json` and each `GAME.TXT`.
4. Re-run setup or `tools/scan-games.py` after metadata edits.
5. Boot image and run `START.BAT` from launcher directory.

## Phase 2 metadata web UI (MVP)

After Phase 1 generates `SETUP-REVIEW.json`, you can review and edit metadata
in a local browser UI.

Start from launcher directory:

```bash
python tools/metadata-ui.py --launcher-dir /mnt/dos/DGB
```

Or point to an explicit review file:

```bash
python tools/metadata-ui.py --review-file /mnt/dos/DGB/SETUP-REVIEW.json --port 8765
```

What it does:

- Loads records from `SETUP-REVIEW.json`
- Lets you filter unresolved entries and edit fields (`title`, `year`,
  `genre`, `publisher`, `exe`, `setup`, `note`)
- Writes each save directly to the game folder `GAME.TXT`
- Updates `SETUP-REVIEW.json` (`needs_review` recalculated per record)
- Regenerates `GAMES.LST` from the same scan root via a one-click action
  (`Regenerate GAMES.LST`)
- Supports bulk stamping of shared fields (`year`, `publisher`, `genre`) for
  unresolved records currently shown by the active filter

Review shortcuts:

- `Ctrl+S` save current record
- `[` previous record, `]` next record
- `N` jump to next unresolved record in current filter

Use `--no-browser` when running over SSH/headless hosts.

### Phase 2 regression smoke tests

```bash
bash tools/test-metadata-ui.sh
bash tools/test-metadata-ui-all.sh
```

PowerShell-only invocation:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\test-metadata-ui.ps1
```

## Regression smoke test

Run the host-side smoke harness before release changes to setup behavior:

```bash
bash tools/test-setup-image.sh
```

Run all available harnesses in one command (bash always, PowerShell when
installed):

```bash
bash tools/test-setup-image-all.sh
```

PowerShell variant (Windows or Linux PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\test-setup-image.ps1
```

It validates conflict modes (`fail`, `skip`, `overwrite`), input validation
failures, and path mapping for both default and custom `--scan-root` layouts.

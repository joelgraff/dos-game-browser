# DOS Game Browser

A lightweight full-screen game launcher for **real MS-DOS x86 hardware** (8086 and up), with a text UI that works on MDA / CGA / EGA / VGA.

You prepare the install on a modern PC, then copy the `booth/` tree to CompactFlash, an IDE DOM, a hard disk image, or any FAT volume the target machine can boot.

| Component | Role |
|-----------|------|
| `BROWSER.COM` | Menu / browser (reads `GAMES.LST`, launches games) |
| `UTILS\ABORT.COM` | TSR: **Ctrl+Alt+Backspace** force-exits a hung game |
| `UTILS\VDETECT.COM` | Optional video detect → `VIDEO.CFG` |
| `GAMES.LST` | Index file (auto-generated) |
| `GAMES\<dir>\` | One folder per game + optional `GAME.TXT` metadata |

**Tested under DOSBox / DOSBox Staging.** Designed for real DOS; please report hardware quirks.

## Features

- 8086-safe assembly (`nasm -f bin`), no 32-bit protected-mode requirement for the launcher itself
- Category headers (genre / year), A–Z jump, detail pane (title, year, publisher, note)
- Restores video mode, keyboard state, and IRQ vectors after games (and after force-exit)
- Silences common Sound Blaster / OPL leftovers after abort
- Host-side tools to **scan games → config**, **fetch free samples**, and **stage CF media**

## Repository layout

```text
dos-game-browser/
  booth/                 ← what you copy to the DOS machine
    BROWSER.COM          prebuilt binary (also rebuildable)
    START.BAT
    GAMES.LST            generated — not always committed
    GAMES/               your games (gitignored)
    UTILS/ABORT.COM
    UTILS/VDETECT.COM
  src/                   NASM sources
  tools/                 build, run, scan, fetch, media
  docs/FORMAT.md         GAME.TXT / GAMES.LST format
  config/dosbox.conf     reference DOSBox conf
```

Prebuilt `.COM` binaries ship in `booth/` so you can deploy without installing a cross-assembler. Sources are the source of truth; rebuild anytime with `tools/build.sh`.

---

## Quick start (host machine)

### 1. Dependencies

| Tool | Purpose |
|------|---------|
| **NASM** | Rebuild launcher (`sudo apt install nasm`) |
| **Python 3** | `scan-games.py`, `fetch-samples.py` |
| **DOSBox** or **DOSBox Staging** | Optional local test |
| **zip** / **unzip** | Optional; fetch uses Python’s zipfile |

Python command note: if `python3` is unavailable on your host, use `python` (or `py -3` on Windows). Host scripts auto-detect these variants.

### Host command compatibility

- Python invocations in docs use `python`, but host scripts auto-detect `python3`, `python`, and `py -3`.
- DOSBox launch scripts auto-detect both `dosbox-staging` and `dosbox` command names.
- PowerShell scripts support both Windows-style and Linux-style fallback tool paths.

### 2. Build (optional if prebuilts present)

Linux/macOS:

```bash
cd dos-game-browser
chmod +x tools/*.sh
./tools/build.sh
```

Windows (PowerShell):

```powershell
cd dos-game-browser
powershell -ExecutionPolicy Bypass -File .\tools\build.ps1
```

### One-shot deployment and review

If you already have a mounted image tree such as `~/Documents/TESTIMG`, run:

```bash
python tools/deploy-image.py --image-root ~/Documents/TESTIMG
```

This runs Phase 1 setup, installs the launcher into the image, scans the game
tree, and then starts the local Phase 2 metadata review UI against the
generated `SETUP-REVIEW.json`.

Use `--no-browser` if you want to open the UI yourself, or `--setup-only` if
you want Phase 1 only.

### 3. Get sample games (recommended first run)

Games are **not** in git (copyright and size). Fetch a free/shareware pack:

```bash
python tools/fetch-samples.py --list
python tools/fetch-samples.py               # download + seed GAME.TXT
python tools/scan-games.py                  # write booth/GAMES.LST
```

Or drop your own game folders into `booth/GAMES/<8CHARDIR>/` and run `scan-games.py`.

### 4. Test in DOSBox

Linux/macOS:

```bash
./tools/run.sh
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run.ps1
```

Controls in the browser:

| Key | Action |
|-----|--------|
| ↑ ↓ / PgUp PgDn / Home End | Move |
| Enter | Launch game |
| A–Z | Jump to title |
| Esc | Quit browser |
| **Ctrl+Alt+Backspace** | Force-exit running game (ABORT TSR) |

---

## First-time mounted image setup (Phase 1)

If you already have a mounted DOS image with installed games, you can bootstrap
the launcher directly on that image:

```bash
python tools/setup-image.py --image-root /path/to/mounted/image
```

Useful options:

```bash
python tools/setup-image.py --image-root /mnt/dos --scan-root GAMES --launcher-path C:\\DGB
python tools/setup-image.py --image-root /mnt/dos --dry-run --verbose
python tools/setup-image.py --image-root /mnt/dos --on-conflict overwrite
```

Notes:

- Scanning is recursive under `--scan-root`.
- `--scan-root` is treated as the GAMES root used for generated `GAMES.LST` paths.
- When multiple launch files exist in one directory, selection order is:
  `.BAT`, then `.EXE`, then `.COM`.
- The setup writes `GAMES.LST` and `SETUP-REVIEW.json` under the launcher path.
- Existing launcher files are protected by default (`--on-conflict fail`). Use
  `--on-conflict skip` or `--on-conflict overwrite` if needed.
- Run `bash tools/test-setup-image.sh` (or PowerShell
  `.\tools\test-setup-image.ps1`) to validate setup conflict and path mapping
  behavior after tool changes.
- Run `bash tools/test-setup-image-all.sh` to execute bash checks and, when
  available, the PowerShell checks in one pass.

Detailed guide: [docs/SETUP-IMAGE.md](docs/SETUP-IMAGE.md)

## Phase 2 metadata UI (MVP)

After `setup-image.py` creates `SETUP-REVIEW.json`, launch the local metadata
editor:

```bash
python tools/metadata-ui.py --launcher-dir /path/to/launcher-dir
```

You can also point directly at the review file:

```bash
python tools/metadata-ui.py --review-file /path/to/SETUP-REVIEW.json
```

Use the UI save action to update `GAME.TXT`, then click `Regenerate GAMES.LST`
to rebuild the launcher index from the same scan root.

Use `Bulk Apply to Filtered Unresolved` to stamp shared fields (year,
publisher, genre) across unresolved records currently visible in the filter.

Review shortcuts:

- `Ctrl+S` save current record
- `[` previous record, `]` next record
- `N` jump to next unresolved record in current filter

Regression checks:

```bash
bash tools/test-metadata-ui.sh
bash tools/test-metadata-ui-all.sh
```

## Autogenerating the launcher config

The browser does **not** scan directories at runtime. It only reads `GAMES.LST`.

**Workflow:**

1. Install each game under `booth/GAMES\<DIR>\` (8.3-friendly directory names).
2. Optionally edit `booth/GAMES\<DIR>\GAME.TXT` (title, year, genre, exe, …).
3. Run the scanner — it picks a launch executable if `exe=` is missing, seeds incomplete `GAME.TXT`, and writes the index:

```bash
python tools/scan-games.py
python tools/scan-games.py --sort year
python tools/scan-games.py --sort title --no-headers
python tools/scan-games.py --apply-catalog   # fill gaps from sample-catalog.json
```

See [docs/FORMAT.md](docs/FORMAT.md) for field definitions and [docs/HARDWARE.md](docs/HARDWARE.md) for CF/real-hardware notes.

Example `GAME.TXT`:

```ini
title=Jill of the Jungle
year=1992
genre=Platform
publisher=Epic MegaGames
exe=JILL.EXE
note=Epic MegaGames shareware platformer
```

---

## Deploy to real DOS hardware

Modern PC does all the work; the target only needs FAT + MS-DOS (or FreeDOS).

Recommended workflow:

1. Clone this repo onto a modern computer.
2. Mount the target DOS disk image, CF card, or USB-backed FAT volume.
3. Stage the launcher into its own directory on the target, for example `C:\DGB\`.
4. Scan the game image to build `GAMES.LST`.
5. Open the generated per-game metadata and hand-edit anything the scanner could not know.
6. Re-stage the image and boot the target machine.

### A. Stage a media tree

```bash
./tools/make-media.sh              # → media/booth/
./tools/make-media.sh --zip        # + media/dos-game-browser-booth.zip
./tools/make-media.sh /mnt/cf      # copy onto a mounted CF/USB volume
```

### B. Target disk layout

Copy the **contents** of `media/booth/` (or `booth/`) to a dedicated launcher directory such as `C:\DGB\`:

```text
C:\DGB\
  BROWSER.COM
  START.BAT
  GAMES.LST
  GAMES\
    HELLOWOR\
    ...
  UTILS\
    ABORT.COM
    VDETECT.COM
```

### C. Boot / auto-start

In `AUTOEXEC.BAT` (example):

```bat
@ECHO OFF
C:
CD \DGB
CALL START.BAT
```

Or run `START.BAT` manually. `START.BAT` loads `ABORT.COM` once, then loops `BROWSER.COM` so Esc returns to the menu rather than bare DOS (kiosk style).

### D. Hardware notes

- **CPU:** 8086+ for the launcher; individual games may need 286/386/486 and EMS/XMS.
- **Video:** Text UI auto-selects color vs mono attributes.
- **Memory:** Keep DOS lean; many games want conventional memory free. Load ABORT only (small TSR).
- **Sound:** Configure each game’s setup for your card (SB/AdLib/PC speaker). Abort tries to silence SB/OPL after force-exit.
- **Media:** FAT16 CF cards via IDE adapters are common for 286–Pentium industrial boards; ensure the BIOS can boot the volume.

---

## Adding your own games

1. Create `booth/GAMES/MYGAME/` (max 8 characters recommended for pure DOS).
2. Copy the game files in.
3. `python tools/scan-games.py` — this scans the image, discovers launch files, and writes or refreshes `GAME.TXT` and `GAMES.LST`.
4. Review the generated `GAME.TXT` files and hand-edit title, year, genre, publisher, exe, and note where needed.
5. Re-run `python tools/scan-games.py` after edits.
6. `./tools/make-media.sh` and recopy to the CF card or mounted image.

If a game lives in a subfolder (`GAMES\COMMANDE\KEEN\KEEN1.EXE`), the scanner records `dir=COMMANDE\KEEN` so the working directory is correct at launch.

The scanner considers DOS launch files with `.EXE`, `.COM`, and `.BAT` extensions.

If you want to speed up metadata cleanup, you can use an AI assistant with a prompt like this after scanning:

```text
You are helping prepare a DOS game launcher catalog.

I have a folder tree under booth/GAMES/ with DOS game binaries and per-game GAME.TXT files generated by a scanner.

Task:
- Inspect the discovered binaries and existing GAME.TXT files.
- Infer the most likely title, year, genre, publisher, executable, setup program, and one-line note.
- Keep entries accurate and conservative; do not invent facts when the binary name is unclear.
- Prefer the real launch executable over setup or catalog tools.
- Preserve DOS 8.3-friendly filenames and backslashes in paths.
- Output only the updated GAME.TXT contents, one file at a time.

If information cannot be determined with confidence, leave the field blank and say why.
```

---

## Sample games policy

| In git | Not in git |
|--------|------------|
| Launcher sources + prebuilt `.COM` | Game binaries / assets |
| `tools/sample-catalog.json` (URLs + metadata) | Downloaded ZIPs |
| Docs and host tools | Your private game library |

`tools/fetch-samples.py` only pulls entries marked freeware, public domain, or traditional shareware demos. **You** are responsible for license compliance for anything you add.

To extend the sample pack, edit `tools/sample-catalog.json` and re-run fetch.

---

## Rebuild from source

```bash
./tools/build.sh
# equivalent:
# nasm -f bin -o booth/UTILS/ABORT.COM   src/abort.asm
# nasm -f bin -o booth/UTILS/VDETECT.COM src/vdetect.asm
# nasm -f bin -o booth/BROWSER.COM       src/browser.asm
```

## Related work

An earlier exploration tree may live alongside this project (`dos-launcher-dev`) with Total DOS Launcher experiments, RLoader booth notes, and abort-TSR history. **This repository (`dos-game-browser`) is the current, self-contained iteration** intended for public use.

## License

MIT for the launcher sources and tools — see [LICENSE](LICENSE).  
Third-party games keep their original licenses.

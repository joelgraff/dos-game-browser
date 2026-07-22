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

### 2. Build (optional if prebuilts present)

```bash
cd dos-game-browser
chmod +x tools/*.sh
./tools/build.sh
```

### 3. Get sample games (recommended first run)

Games are **not** in git (copyright and size). Fetch a free/shareware pack:

```bash
python3 tools/fetch-samples.py --list
python3 tools/fetch-samples.py              # download + seed GAME.TXT
python3 tools/scan-games.py                 # write booth/GAMES.LST
```

Or drop your own game folders into `booth/GAMES/<8CHARDIR>/` and run `scan-games.py`.

### 4. Test in DOSBox

```bash
./tools/run.sh
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

## Autogenerating the launcher config

The browser does **not** scan directories at runtime. It only reads `GAMES.LST`.

**Workflow:**

1. Install each game under `booth/GAMES\<DIR>\` (8.3-friendly directory names).
2. Optionally edit `booth/GAMES\<DIR>\GAME.TXT` (title, year, genre, exe, …).
3. Run the scanner — it picks a launch executable if `exe=` is missing, seeds incomplete `GAME.TXT`, and writes the index:

```bash
python3 tools/scan-games.py
python3 tools/scan-games.py --sort year
python3 tools/scan-games.py --sort title --no-headers
python3 tools/scan-games.py --apply-catalog   # fill gaps from sample-catalog.json
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

### A. Stage a media tree

```bash
./tools/make-media.sh              # → media/booth/
./tools/make-media.sh --zip        # + media/dos-game-browser-booth.zip
./tools/make-media.sh /mnt/cf      # copy onto a mounted CF/USB volume
```

### B. Target disk layout

Copy the **contents** of `media/booth/` (or `booth/`) to `C:\` (or another drive):

```text
C:\
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
CD \
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
3. `python3 tools/scan-games.py` — review the generated `GAME.TXT` and fix `exe=` if it picked the wrong binary (setup, catalog, etc. are skipped automatically).
4. Re-run scan after edits.
5. `./tools/make-media.sh` and recopy to the CF card.

If a game lives in a subfolder (`GAMES\COMMANDE\KEEN\KEEN1.EXE`), the scanner records `dir=COMMANDE\KEEN` so the working directory is correct at launch.

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

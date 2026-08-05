# DOS Game Browser

A lightweight full-screen game launcher for **real MS-DOS x86 hardware** (8086 and up), with a text UI that works on MDA / CGA / EGA / VGA.

You prepare the install on a modern PC, then copy the `bin/` files to CompactFlash, an IDE DOM, a hard disk image, or any FAT volume the target machine can boot.

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
  dgb.py                 ← one entry point for everything
  dgb/                   host-side tooling (Python, no dependencies)
  bin/                   prebuilt DOS binaries, copied to the target
    BROWSER.COM  START.BAT  UTILS/ABORT.COM  UTILS/VDETECT.COM
  src/                   NASM sources
  tools/                 test harnesses
  docs/FORMAT.md         GAME.TXT / GAMES.LST format
  config/dosbox.conf     reference DOSBox conf
```

Your games are never stored in the repository, and the layout on the target
machine is yours to choose — the tooling builds it wherever you point it.

```bash
python dgb.py --help      # every command
python dgb.py doctor      # what this machine has installed
```

Prebuilt `.COM` binaries ship in `bin/` so you can deploy without installing a cross-assembler. Sources are the source of truth; rebuild anytime with `python dgb.py build`.

---

## Quick start (host machine)

### 1. Dependencies

| Tool | Purpose |
|------|---------|
| **NASM** | Rebuild launcher (`sudo apt install nasm`) |
| **Python 3** | all host-side tooling (`dgb.py`) |
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
python dgb.py build
```

Windows (PowerShell):

```powershell
cd dos-game-browser
python dgb.py build
```

### 3. Get sample games (recommended first run)

Games are **not** in git (copyright and size). Fetch a free/shareware pack:

```bash
python dgb.py samples --list
python dgb.py samples               # download + seed GAME.TXT
python dgb.py scan --games-root <games> --launcher-dir <launcher>   # write GAMES.LST
```

Or point the scanner at wherever your game folders already live.

### 4. Test in DOSBox

Linux/macOS:

```bash
python dgb.py run
```

Windows (PowerShell):

```powershell
python .\tools\launch-dosbox.py
```

To test a mounted image like `Documents/TESTIMG` where DGB is under `C:\DGB`:

```bash
python dgb.py run --image-root ~/Documents/TESTIMG --launcher-dir DGB
```

Optional local default override (kept out of git):

```bash
python dgb.py run --image-root ~/Documents/TESTIMG --launcher-dir DGB --save-local
python dgb.py run
```

This writes `dgb-local.json` in your local clone only.

Controls in the browser:

| Key | Action |
|-----|--------|
| ↑ ↓ / PgUp PgDn / Home End | Move |
| Enter | Launch game |
| A–Z | Jump to title |
| Esc | Quit browser — `START.BAT` immediately relaunches it (kiosk loop) |
| **Shift+Esc** | Maintenance exit — leaves the loop, drops to DOS (ERRORLEVEL 42) |
| Ctrl+Alt+Esc | Same, but only on real hardware (see below) |
| **F12** | Force-exit running game (ABORT TSR — see caveat below) |
| **Ctrl+Alt+Backspace** | Same, for keyboards without F12 |

#### Getting out of the browser

`Esc` quits `BROWSER.COM`, but `START.BAT` is a kiosk loop and relaunches it
straight away — deliberately, so a booth cannot be dropped to a DOS prompt by a
stray keypress. Use **Shift+Esc** to leave the loop for real.

Shift+Esc is intentionally **not** shown anywhere in the UI: on a public booth
the way out should not be discoverable by visitors.

Ctrl+Alt+Esc does the same thing but only works on real hardware: desktop window
managers grab that combination for themselves, so under DOSBox it never reaches
DOS and just unfocuses the window. Once at the DOS prompt, `exit` closes DOSBox;
`Ctrl+F9` kills it outright from anywhere.

The browser shows the force-exit hint only when `ABORT.COM` is actually
resident; if it is not loaded you get a dim `ABORT.COM not loaded` notice
instead, so the header never promises something that will not work.

#### Force-exit does not work in every game

`ABORT.COM` sees the hotkey by sitting in the INT 09h keyboard chain, so it
depends on the game leaving keyboard interrupts alone. Most do.

Measured on the test image: Jill of the Jungle, Sopwith and Commander Keen all
force-exit correctly. **Digger Remastered does not**, and cannot.

Its `/T` reading after a session, with `/W` enabled so the sampling runs:

```text
KBD scancodes=2 last=FA ctrlalt=00 grabs=0 irq1off=0 wdticks=157
```

`wdticks=157` shows the sampler ran for the whole session, so the zeroes are
real: `grabs=0` means the interrupt vector still pointed at us, and `irq1off=0`
means the keyboard IRQ was never masked. Yet only two interrupts arrived, both
`FAh` — the keyboard's acknowledgement of Digger's own controller commands
during start-up, not keystrokes.

The explanation is that Digger polls port 60h directly in a tight loop. Reading
that port clears the controller's output-buffer flag and deasserts the IRQ, so a
fast enough loop consumes each scancode before the interrupt is ever serviced.
There is no interrupt left to hook, which is why no hotkey, modifier-free or
otherwise, can reach us. Reading the port ourselves from a timer tick would
simply steal the keys back from the game and break its controls.

`F12` exists as a second trigger because it needs no modifier: if a game chains
to us but leaves the Ctrl/Alt state inconsistent, the chord fails while F12 still
works. It cannot help when the game does not call us at all — no key can.

To tell those two cases apart, play the game, press the key several times, quit
normally, then run `BROWSER.COM /T`. The counter is zeroed when a game is
launched, so the reading covers only that session:

| `/T` reading | Meaning |
|---|---|
| `KBD scancodes=0` | The game owns the keyboard outright; no key can work |
| `KBD scancodes>0` | We are being called — worth reporting, the trigger is at fault |

To tell which case you are in, play the game, quit it normally, then run:

```bat
C:\DGB> BROWSER.COM /T > TEST.TXT
```

`KBD scancodes=0` means the game owned the keyboard outright and the TSR was
never called.

The force-exit re-arms itself each time a game is launched. It used to fire
only once per boot, which looked exactly like "this game captures the keyboard"
because a freshly started session always worked on the first attempt.

##### `ABORT.COM /W` (diagnostic; rarely needed otherwise)

There is one way to get the hotkey working in such games: watch the interrupt
vector from the timer and take it back whenever a game grabs it. This is
available but **off by default**:

```bat
IF EXIST UTILS\ABORT.COM UTILS\ABORT.COM /W
```

With `/W`, `ABORT.COM` checks 18 times a second whether INT 09h still points at
it, and if not, chains to whatever took it and moves back in front.

It is opt-in because it is genuinely risky: it puts our handler ahead of a game
that expects exclusive keyboard control, and we read port 60h before the game
does. This was first shipped on by default and looked like it stopped Commander
Keen from starting; that turned out to be a memory problem, since fixed, but the
risk is real and per-game. Try it, and if a game misbehaves drop the `/W`.

`/W` is also what makes `BROWSER.COM /T` informative about a game: the
`irq1off` and `wdticks` counters are sampled from the timer tick, so without it
they always read zero and cannot be distinguished from "nothing happened".

Reading a `/T` line after playing:

| Field | Meaning |
|-------|---------|
| `scancodes` | Keyboard interrupts our handler saw during the game |
| `last` | Last byte read from port 60h (`FAh` is a controller ACK, not a key) |
| `grabs` | Times the `/W` watchdog had to reclaim INT 09h |
| `armed` | 0 means the hotkey was already spent — it re-arms per launch |
| `pend` | 1 means the chord was recognised but the abort never completed |
| `busydos` | Aborts recognised but blocked because DOS was busy |
| `irq1off` | Timer ticks with the keyboard IRQ masked off |
| `wdticks` | Ticks the sampler ran. **Zero makes the two above meaningless** |

The counters cover one game only: they are reset when a game is launched and
frozen the moment it exits.

### Diagnosing path problems on the target machine

`BROWSER.COM` has a self-test mode that runs the real config and index parsing
and prints what it resolved, which is the fastest way to see why a game will not
start on real hardware:

```bat
C:\DGB> BROWSER.COM /T > TEST.TXT
```

It reports whether `DGB.CFG` was found, the resolved games-root prefixes, the
entry count, and every parsed entry with the record re-read from disk. The same
hook drives the automated tests (`bash tools/test-browser.sh`), so what you see
on hardware is what CI checks.

---

## First-time mounted image setup (Phase 1)

If you already have a mounted DOS image with installed games, you can bootstrap
the launcher directly on that image:

```bash
python dgb.py install --image-root /path/to/mounted/image
```

Useful options:

```bash
python dgb.py install --image-root /mnt/dos --scan-root GAMES --launcher-path C:\\DGB
python dgb.py install --image-root /mnt/dos --dry-run --verbose
python dgb.py install --image-root /mnt/dos --on-conflict overwrite
```

Notes:

- `dgb.py install` installs the launcher files, then runs the scanner
  for discovery and index generation. There is only one scanner.
- `--scan-root` is the games root used for generated `GAMES.LST` paths.
- Game directories may sit **1 to 3 levels** below the games root, so
  `<root>/GAME/`, `<root>/PUBLISHER/GAME/` and `<root>/PUBLISHER/SERIES/GAME/`
  all work. A directory holding a launchable file *is* a game and is not
  descended into, so a game's own `UTILS\` or `DATA\` subfolders never turn into
  extra catalog entries.
- When multiple launch files exist in one directory, selection order is:
  `.BAT`, then `.EXE`, then `.COM`.
- The setup writes `GAMES.LST` under the launcher path.
- The setup writes `DGB.CFG` under the launcher path, with `GAMES_ROOT` derived
  from `--image-root`. The DOS games root is never inferred from host directory
  nesting — pass `--games-root-dos` to `scan-games.py` to state it outright.
- Existing launcher files are protected by default (`--on-conflict fail`). Use
  `--on-conflict skip` or `--on-conflict overwrite` if needed.
- Run `bash tools/test-setup-image.sh` (or PowerShell
  `.\tools\test-setup-image.ps1`) to validate setup conflict and path mapping
  behavior after tool changes.
- Run `bash tools/test-setup-image-all.sh` to execute bash checks and, when
  available, the PowerShell checks in one pass.

Detailed guide: [docs/SETUP-IMAGE.md](docs/SETUP-IMAGE.md)

## Regression tests

| Script | Covers |
|--------|--------|
| `tools/test-browser.sh` | `BROWSER.COM` itself, under headless DOSBox |
| `tools/test-scan-games.sh` | Scanner: discovery depth, `DGB.CFG`, capacity guards |
| `tools/test-setup-image.sh` | Launcher install and conflict policy |

`tools/test-browser.sh` assembles `src/browser.asm` and runs it under headless
DOSBox against fixture trees, asserting on the `/T` self-test output. It covers
`DGB.CFG` parsing, index parsing and offsets, catalogs past the old 64-entry
ceiling, and two end-to-end launches that verify a child process actually starts
in the correct game directory.

```bash
bash tools/test-browser.sh
bash tools/test-browser.sh -k cfg    # only cases matching "cfg"
bash tools/test-scan-games.sh
```

`test-browser.sh` requires `nasm` and `dosbox` (`sudo apt install nasm dosbox`).
It sets the SDL dummy video and audio drivers itself, so it runs on a headless
machine with no X server and no sound card.

All four suites run in CI on every push and pull request
(`.github/workflows/tests.yml`, about 30 seconds). That workflow also rebuilds
from source and fails if the prebuilt `bin/*.COM` binaries differ from the
sources they claim to come from — deploying a stale binary is otherwise silent,
and costs a lot of debugging time.

## Autogenerating the launcher config

The browser does **not** scan directories at runtime. It only reads `GAMES.LST`.

**Workflow:**

1. Put each game in its own directory under your games root (8.3-friendly names).
2. Optionally edit `GAME.TXT` in that directory (title, year, genre, exe, …).
3. Run the scanner — it picks a launch executable if `exe=` is missing, seeds incomplete `GAME.TXT`, and writes the index:

```bash
python dgb.py scan --games-root <games> --launcher-dir <launcher>
python dgb.py scan --games-root <games> --launcher-dir <launcher> --sort year
python dgb.py scan --games-root <games> --launcher-dir <launcher> --sort title --no-headers
python dgb.py scan --games-root <games> --launcher-dir <launcher> --apply-catalog
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
python dgb.py stage --out <dir>
python dgb.py stage --out <dir>
python dgb.py stage --out <dir>
```

### B. Target disk layout

Copy the staged files (or `bin/`) to a dedicated launcher directory such as `C:\DGB\`:

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

1. Create `<games-root>/MYGAME/` (max 8 characters recommended for pure DOS).
2. Copy the game files in.
3. Run the scanner — it discovers launch files and writes or refreshes `GAME.TXT` and `GAMES.LST`:

   ```bash
   python dgb.py scan --games-root <games> --launcher-dir <launcher>
   ```
4. Review the generated `GAME.TXT` files and hand-edit title, year, genre, publisher, exe, and note where needed.
5. Re-run the scanner after edits.
6. `python dgb.py stage --out <dir>

If a game lives in a subfolder (`GAMES\COMMANDE\KEEN\KEEN1.EXE`), the scanner records `dir=COMMANDE\KEEN` so the working directory is correct at launch.

The scanner considers DOS launch files with `.EXE`, `.COM`, and `.BAT` extensions.

If you want to speed up metadata cleanup, you can use an AI assistant with a prompt like this after scanning:

```text
You are helping prepare a DOS game launcher catalog.

I have a folder tree of DOS game binaries and per-game GAME.TXT files generated by a scanner.

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
python dgb.py build
# equivalent:
# nasm -f bin -o bin/UTILS/ABORT.COM   src/abort.asm
# nasm -f bin -o bin/UTILS/VDETECT.COM src/vdetect.asm
# nasm -f bin -o bin/BROWSER.COM       src/browser.asm
```

## Related work

An earlier exploration tree may live alongside this project (`dos-launcher-dev`) with Total DOS Launcher experiments, RLoader booth notes, and abort-TSR history. **This repository (`dos-game-browser`) is the current, self-contained iteration** intended for public use.

## License

MIT for the launcher sources and tools — see [LICENSE](LICENSE).  
Third-party games keep their original licenses.

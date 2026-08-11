# Install on the DOS machine

For when the DOS machine is the only machine involved. You write one floppy on
whatever computer you have, carry it over, and do everything else in DOS.

You need a modern computer only to write the floppy. After that it plays no part.

---

## 1. Write the floppy

```bash
python dgb.py stage --out /mnt/floppy
```

On Windows that would be `python dgb.py stage --out A:\`. Any directory works if
you would rather copy it to a USB stick or a CF card in an adapter.

That writes about 17 KB — the launcher, the scanner, the abort TSR, and an
`INSTALL.TXT` repeating these steps in case you read it at the DOS machine
rather than here.

## 2. Copy it onto the DOS machine

Put the floppy in the drive and run the installer on it:

```
A:
INSTALL C:
```

That creates `C:\DGB`, copies everything in, and prints the next step. Give it a
different drive letter if that suits the machine better — `INSTALL D:`.

By hand it is only four commands, if you would rather see them:

```
MD C:\DGB
MD C:\DGB\UTILS
COPY A:\*.*        C:\DGB
COPY A:\UTILS\*.*  C:\DGB\UTILS
```

`C:\DGB` is only a suggestion. Anywhere on a writable drive is fine.

What you just copied, about 28 KB in all:

| File | Role |
|------|------|
| `BROWSER.COM` | The launcher: reads `GAMES.LST`, runs games |
| `SCAN.COM` | Builds `GAMES.LST` — step 4 below |
| `START.BAT` | Loads the abort TSR, then loops the browser |
| `UTILS\ABORT.COM` | TSR: **Scroll Lock** force-exits a stuck game |
| `UTILS\VDETECT.COM` | Optional video detection |
| `DGB.CFG` | Settings, all commented out — see below |
| `INSTALL.TXT` | These instructions, readable with `TYPE` |
| `INSTALL.BAT` | The copy step above, done for you |

## 3. Put your games somewhere

One directory per game:

```
C:\GAMES\JILL\JILL.EXE
C:\GAMES\KEEN\KEEN1.EXE
```

Game directories may sit up to **three levels** below the games root, so a
publisher or series level is fine:

```
C:\GAMES\APOGEE\KEEN\KEEN1.EXE
C:\GAMES\EPIC\JAZZ\JJ1\JAZZ.EXE
```

A directory holding a `.EXE`, `.COM` or `.BAT` *is* a game, and is not searched
any deeper — so a game's own `UTILS\` or `DATA\` subfolder will not turn into a
separate menu entry.

## 4. Build the index

From the launcher directory, naming the root your games are under:

```
C:
CD \DGB
SCAN C:\GAMES
```

```
Scanning C:\GAMES
Wrote GAMES.LST with 18 games, and DGB.CFG.
```

`SCAN` writes two files next to `BROWSER.COM`:

- `GAMES.LST` — the menu index
- `DGB.CFG` — a note of where the games are, so the launcher can find them

Re-run `SCAN` whenever you add or remove games.

## 5. Start it

```
START
```

`START.BAT` loads the abort TSR and then loops the browser, so pressing Esc
returns you to the menu rather than to DOS. That is deliberate for an unattended
machine.

To start it automatically at boot, add this to `AUTOEXEC.BAT`:

```
C:
CD \DGB
CALL START.BAT
```

---

## Naming the games

By default each entry is named after its directory, so `C:\GAMES\JILL` shows up
as "Jill". To do better, put a `GAME.TXT` in the game's directory:

```
title=Jill of the Jungle
year=1992
genre=Platform
publisher=Epic MegaGames
note=Classic Epic platformer
```

Then re-run `SCAN`. Any text editor will do — DOS `EDIT` is fine:

```
EDIT C:\GAMES\JILL\GAME.TXT
```

Every field is optional. `exe=` is worth setting when a directory holds several
programs and `SCAN` picks the wrong one:

```
exe=JILL.EXE
```

Full field list: [FORMAT.md](FORMAT.md).

## Getting out

| Key | Effect |
|-----|--------|
| Esc | Quits the browser — `START.BAT` restarts it |
| **Shift+Esc** | Leaves the loop and drops to DOS |
| Ctrl+Alt+Esc | The same, on real hardware |

Shift+Esc is not shown anywhere on screen, so that a machine left in a public
space cannot be trivially exited.

## If a game locks up

Press **Scroll Lock**. The abort TSR terminates the game and returns you to the
menu. Ctrl+Alt+Backspace does the same thing.

This will not work in every game — some read the keyboard hardware directly and
never generate the interrupt the TSR watches. See
[DIAGNOSTICS.md](DIAGNOSTICS.md).

### If a game needs that key

`DGB.CFG` in the launcher directory holds the settings — that is
`C:\DGB\DGB.CFG`, next to `BROWSER.COM`, not one level up.

It arrives with everything commented out, so the defaults apply. Changing the
value is not enough: **delete the leading `;` too**, or the line stays a
comment and nothing happens.

```ini
;ABORT_KEY=SCRLOCK  <- still a comment, does nothing
ABORT_KEY=F11       <- active
```

A key name, `F1` to `F12`, or a raw make-code in hex. The names are listed in
`DGB.CFG` itself and in the
[FORMAT.md](FORMAT.md#key-names-and-their-make-codes). `EDIT` works fine:

```
EDIT C:\DGB\DGB.CFG
```

Re-running `SCAN` keeps the setting — it rewrites `GAMES_ROOT` and leaves
everything else alone. The browser's header shows whichever key is active, so
you can confirm it took.

## Limits

`SCAN` and the browser handle up to **256 games**. `SCAN` on DOS records the
directory, executable and everything in `GAME.TXT`, but does not do the genre
grouping or the curated executable preferences that the Python scanner does — if
you want those, prepare the disk on a modern machine instead:
[Prepare an image](02-prepare-image.md).

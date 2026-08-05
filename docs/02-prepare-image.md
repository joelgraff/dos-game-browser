# Prepare a card or image on a modern PC

For when you assemble everything on a modern computer — mounting a CF card, an
SD card, or a disk image — and move it to the DOS machine afterwards.

This is the fullest path: the Python scanner can do things `SCAN.COM` cannot,
including genre grouping and recognising DOSBox launch scripts that would fail
on real hardware.

---

## 1. Mount the target

Mount the card or image so it appears as an ordinary directory. Everything
below calls that directory the **image root** — it is what will become `C:` on
the DOS machine.

```bash
# a card via a reader
/media/you/DOSCARD

# or a loopback-mounted image
sudo mount -o loop,offset=32256 dos.img /mnt/dos
```

## 2. Put your games on it

One directory per game, up to three levels below the games root:

```
/mnt/dos/GAMES/JILL/JILL.EXE
/mnt/dos/GAMES/APOGEE/KEEN/KEEN1.EXE
```

No games yet? Fetch a few free ones:

```bash
python dgb.py samples --list
python dgb.py samples --dest /mnt/dos/GAMES
```

## 3. Install the launcher

```bash
python dgb.py install --image-root /mnt/dos
```

That copies the launcher into `/mnt/dos/DGB` (the files are listed in
[guide 1](01-install-on-dos.md#2-copy-it-onto-the-dos-machine)), scans
`/mnt/dos/GAMES`, and writes `GAMES.LST` and `DGB.CFG`.

```
DOS Game Browser setup
  image root:   /mnt/dos
  scan root:    /mnt/dos/GAMES
  launcher dos: C:\DGB
  launcher dir: /mnt/dos/DGB

Installing launcher files...

Scanning image for launchable executables...
  APOGEE\KEEN\KEEN1.EXE: Commander Keen 1
  JILL\JILL.EXE: Jill of the Jungle

Wrote 18 games -> /mnt/dos/DGB/GAMES.LST
Wrote runtime config -> /mnt/dos/DGB/DGB.CFG (GAMES_ROOT=\GAMES)
```

### Useful options

```bash
# games somewhere other than GAMES/
python dgb.py install --image-root /mnt/dos --scan-root DOSGAMES

# launcher somewhere other than C:\DGB
python dgb.py install --image-root /mnt/dos --launcher-path C:\\LAUNCH

# see what it would do, touching nothing
python dgb.py install --image-root /mnt/dos --dry-run --verbose
```

Existing launcher files are protected: a second `install` fails rather than
overwriting. Use `--on-conflict skip` to leave them, or `--on-conflict overwrite`
to replace them — which is what you want after rebuilding.

## 4. Boot it

Add to `AUTOEXEC.BAT` on the target:

```bat
C:
CD \DGB
CALL START.BAT
```

Or run `START.BAT` by hand.

Before committing the card to hardware, it is worth
[testing it under DOSBox](03-test-in-dosbox.md) — same image, no reboot.

---

## Fixing up the metadata

The scan prints how many entries it could not fully identify:

```
  records needing metadata review: 3
```

Each game gets a `GAME.TXT` seeded next to it. Edit them in any editor:

```ini
title=Jill of the Jungle
year=1992
genre=Platform
publisher=Epic MegaGames
exe=JILL.EXE
note=Classic Epic platformer
```

Then rebuild the index:

```bash
python dgb.py scan --games-root /mnt/dos/GAMES --launcher-dir /mnt/dos/DGB \
                   --image-root /mnt/dos
```

`genre` drives the grouping headers in the menu, so it is the one most worth
filling in. Full field list: [FORMAT.md](FORMAT.md).

## Corrections the scanner makes

Some things get reported on stderr rather than silently applied:

```
Entry corrections (review these):
  COMMANDE: ignoring DOSBox-only script(s) KEEN.BAT, KEEN1WEB.BAT; using KEEN\KEEN1.EXE
  2FAST4YO: exe=BIFI.EXE is not in that directory; using BIFI3\BIFI.EXE
```

**DOSBox-only scripts.** Repacks often ship `.BAT` launchers that configure the
emulator (`cycles max`, `config -set`, `mount`). They work under DOSBox and fail
on real hardware, so the scanner prefers the real executable and says so.

**Relocated executables.** When `exe=` names a file that is actually one level
down, the recorded directory follows the file — otherwise the launcher would
change into the wrong directory and fail with DOS error 02.

## Capacity

Up to **320 entries**, counting the group headers and the blank line before
each. The scanner refuses to write an index that would exceed this rather than
producing one the launcher silently truncates:

```
generated GAMES.LST exceeds launcher limits:
  - index needs 379 launcher slots but BROWSER.COM holds 320 (300 games plus
    79 slots of category headers and spacers). Re-run with --no-headers to fit.
```

`--no-headers` drops the grouping and buys back roughly two slots per genre.

## Staging without mounting

If you would rather copy files yourself:

```bash
python dgb.py stage --out ./staged
```

That writes the launcher files and an `INSTALL.TXT`. Copy the contents to a
directory on the target, then build the index there with `SCAN`, or here with
`dgb.py scan`.

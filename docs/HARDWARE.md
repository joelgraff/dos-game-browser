# Deploying to real DOS hardware

The launcher is developed and smoke-tested under **DOSBox / DOSBox Staging**. The supported production target is **original IBM PC–compatible hardware** running MS-DOS 5.x/6.x (or FreeDOS).

## Host vs target

| Role | Machine | Work done here |
|------|---------|----------------|
| **Host** | Modern Linux/macOS/Windows | Assemble binaries, fetch games, edit `GAME.TXT`, run `scan-games.py`, stage media |
| **Target** | 8086–Pentium DOS PC | Boot DOS, run `START.BAT` / `BROWSER.COM` only |

Never rely on long filenames, Unicode, or a network stack on the target.

## Recommended media

- CompactFlash (or SD) in an IDE/CF adapter — common for industrial 286–486 boards  
- DOM / flash IDE modules  
- Physical HDD / SSD with a DOS-compatible controller  
- For tiny demos: 1.44 MB floppy (launcher + a few small games)

Format **FAT16** for volumes up to 2 GiB (widest BIOS/DOS compatibility). Install a bootable MS-DOS (or FreeDOS) system first, then copy the booth tree.

## Copy checklist

1. On the host: `python3 tools/scan-games.py` then `./tools/make-media.sh`
2. Mount the CF/USB volume on the host (or use a USB card reader)
3. Copy **contents** of `media/booth/` to `C:\` (or e.g. `C:\GAMESYS\`)
4. Edit target `AUTOEXEC.BAT` to `CALL C:\START.BAT` if you want kiosk auto-start
5. Safely eject, insert in the target, boot

If the booth is not at `C:\`, either:

- `CD` to that directory before `BROWSER.COM`, or  
- Keep `GAMES.LST` next to `BROWSER.COM` (the browser also tries `C:\GAMES.LST`)

Game paths inside `GAMES.LST` are relative to a `GAMES\` directory beside the browser when you use the default layout from `scan-games.py` (`dir` field under `GAMES\`).

## Memory and TSRs

- Load **only** `UTILS\ABORT.COM` for force-exit (small).  
- Avoid large network stacks, mouse drivers, or disk caches if conventional memory is tight.  
- Games may need EMS/XMS (`HIMEM.SYS` / `EMM386` / FreeDOS equivalents) — configure per title, not in the browser.

## Force-exit

With `ABORT.COM` resident: **Ctrl+Alt+Backspace** terminates the current process so control returns to the browser loop. After abort, the browser restores IRQ vectors, text mode, and attempts to silence Sound Blaster / OPL / PC speaker leftovers.

Not every protected-mode or DPMI title will unwind cleanly; still better than a cold reboot for most real-mode shareware.

## Video

`BROWSER.COM` uses direct text VRAM (`B800` color / `B000` mono) and adjusts attributes. `VDETECT.COM` can write `VIDEO.CFG` if you build multi-profile batch wrappers; v1 of the browser does not require it.

## Verification on host before CF burn

```bash
./tools/build.sh
python3 tools/fetch-samples.py --only HELLOWOR
python3 tools/scan-games.py
./tools/run.sh
```

Confirm menu navigation and that Enter launches the hello-world stub, then stage media.

# Real hardware notes

Media, memory and video specifics for the target machine. This is reference
only — for what to actually type, use the guide that matches your situation:

| | |
|-|-|
| No modern PC involved | [Install on DOS](01-install-on-dos.md) |
| Preparing a card or image on a modern PC | [Prepare an image](02-prepare-image.md) |
| Trying it under emulation first | [Test in DOSBox](03-test-in-dosbox.md) |

## Host and target

| Role | Machine | What happens there |
|------|---------|--------------------|
| **Host** | Modern Linux, macOS or Windows | Assemble binaries, fetch games, edit `GAME.TXT`, scan, write media |
| **Target** | 8086 to Pentium, MS-DOS 5/6 or FreeDOS | Boot DOS and run `START.BAT` |

Nothing on the target may rely on long filenames, Unicode, or a network stack.
The launcher is 8086 code with no CPU-specific instructions, so a genuine XT is
a supported target rather than an aspiration.

Use case 1 needs no host at all: `SCAN.COM` builds the index on the DOS machine
itself.

## Media

- CompactFlash or SD in an IDE adapter — the usual choice for 286–486 boards
- DOM or flash IDE modules
- A real hard disk, with a controller DOS can see
- A 1.44 MB floppy is enough for the launcher plus a few small games

Format **FAT16**, up to 2 GiB per volume, for the widest BIOS and DOS
compatibility. Install a bootable MS-DOS or FreeDOS first, then add the
launcher.

## Where things go

The launcher directory and the games tree are separate, and neither location is
assumed — you say where the games are when you scan, and that answer is recorded
in `DGB.CFG` as `GAMES_ROOT`.

```text
C:\DGB\          BROWSER.COM, SCAN.COM, START.BAT, DGB.CFG, GAMES.LST, UTILS\
C:\GAMES\        one directory per game, up to three levels deep
```

Putting the games *inside* the launcher directory works but is not recommended:
the scanner has to exclude its own files, and it is easier to reason about when
the two trees are separate.

`BROWSER.COM` looks for `GAMES.LST` in the current directory, then `C:\GAMES.LST`
— so run it from the launcher directory, which is what `START.BAT` does.

## Auto-start

To land on the menu at boot, add this to `AUTOEXEC.BAT`:

```bat
C:
CD \DGB
CALL START.BAT
```

`CALL` matters: without it, control never returns to `AUTOEXEC.BAT`.

## Memory

`BROWSER.COM` stays resident as the parent process while a game runs, costing
that game about 8.9 KB; `ABORT.COM` costs about 1.1 KB more. The launcher hands
its 11 KB entry table back to DOS before starting a child and takes it back
afterwards, which is what makes the difference between a game starting and not.

A real machine with drivers loaded has considerably less free memory than
DOSBox's ~620 KB. If a game reports running out, check `MEM` on the target
before suspecting the launcher — and see
[Diagnostics](DIAGNOSTICS.md#a-game-starts-then-reports-out-of-memory).

## Video

The browser picks colour or monochrome attributes automatically and drives text
mode only, so MDA, CGA, EGA and VGA all work. `UTILS\VDETECT.COM` reports what
it detected if the screen looks wrong on unusual hardware.

## Keyboard

The force-exit key defaults to **Scroll Lock**, which exists on an 83-key XT
keyboard — F11 and F12 do not. See the
[FORMAT.md](FORMAT.md#runtime-dgbcfg) for how to change it, and
[Diagnostics](DIAGNOSTICS.md#the-force-exit-does-nothing) for the games where no
hotkey can reach.

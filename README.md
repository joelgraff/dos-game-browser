# DOS Game Browser

A full-screen game launcher for **real MS-DOS hardware** — 8086 and up, text UI
on MDA, CGA, EGA or VGA. Pick a game from a menu, play it, come back to the menu.

Written in 8086 assembly so it runs on the machines it is for, with host-side
tooling in Python so preparing a disk works the same on Linux, macOS and Windows.

```text
  Arrows move  Enter=Play                F12 or CTRL+ALT+BKSP exits game
  ------------------------------------------------------------------------
  * Platform
      Commander Keen 1
      Jill of the Jungle
      Pharaohs Tomb
  * Puzzle
      Tetris
```

## Which guide do you want?

| You are… | Guide |
|----------|-------|
| Setting it up **on the DOS machine itself**, carrying files over on a floppy | **[Install on DOS](docs/01-install-on-dos.md)** |
| Preparing a **CF card or disk image** on a modern PC, to move over later | **[Prepare an image](docs/02-prepare-image.md)** |
| Wanting to **try it under DOSBox** before touching real hardware | **[Test in DOSBox](docs/03-test-in-dosbox.md)** |

All three end up in the same place: a launcher directory holding `BROWSER.COM`
and a `GAMES.LST` index, alongside your games.

## What gets installed

| File | Role |
|------|------|
| `BROWSER.COM` | The launcher: reads `GAMES.LST`, runs games |
| `SCAN.COM` | Builds `GAMES.LST` on the DOS machine |
| `START.BAT` | Loads the abort TSR, then loops the browser |
| `UTILS\ABORT.COM` | TSR: **F12** force-exits a stuck game |
| `UTILS\VDETECT.COM` | Optional video detection |
| `GAMES.LST` | The index — generated, not hand-written |
| `DGB.CFG` | Records where your games are |

About 17 KB in total. Your games live wherever you keep them; nothing assumes a
particular layout.

## Host tooling

One entry point, nothing to install beyond Python 3:

```bash
python dgb.py doctor      # what this machine has, and what it lets you do
python dgb.py build       # assemble the DOS binaries (needs NASM)
python dgb.py scan        # games tree -> GAMES.LST + DGB.CFG
python dgb.py install     # launcher into a mounted image, then scan
python dgb.py stage       # launcher onto a floppy or CF card
python dgb.py run         # start it under DOSBox
python dgb.py samples     # download some free games to try
python dgb.py test        # the test suite
```

Prebuilt binaries ship in `bin/`, so deploying needs neither NASM nor DOSBox.
`doctor` reports what is missing and what that stops you doing.

## Keys

| Key | Action |
|-----|--------|
| ↑ ↓ · PgUp PgDn · Home End | Move |
| Enter | Play |
| A–Z | Jump to a title |
| Esc | Quit — `START.BAT` restarts it, which is the kiosk behaviour |
| **F12** | Force-exit a running game |
| Ctrl+Alt+Backspace | Same as F12, for keyboards without one |

There is also a maintenance exit that leaves the `START.BAT` loop and drops to
DOS. It is deliberately absent from the UI so visitors to a booth cannot find
it: **Shift+Esc**, or Ctrl+Alt+Esc on real hardware. Under DOSBox use Shift+Esc,
because window managers intercept the other one.

### Force-exit does not work in every game

`ABORT.COM` watches the keyboard interrupt. A game that reads the keyboard
hardware directly never generates one, and no hotkey can reach us. Measured on
a real catalog: Jill of the Jungle, Sopwith and Commander Keen all force-exit
correctly; Digger Remastered cannot. [Diagnostics](docs/DIAGNOSTICS.md) shows
how to tell which case a game is in.

## Repository layout

```text
dgb.py            one entry point for all host-side tasks
dgb/              the Python tooling
src/              NASM sources: browser, scan, abort, vdetect
bin/              prebuilt .COM files, copied to the target
tests/            the test suite (python dgb.py test)
docs/             the three guides, plus reference
config/           a reference DOSBox conf
```

Games are never stored here, and the layout on the target machine is yours to
choose — the tooling builds it wherever you point it.

## Reference

- **[GAME.TXT and GAMES.LST formats](docs/FORMAT.md)** — fields and limits
- **[Real hardware notes](docs/HARDWARE.md)** — media, memory, video, CF cards
- **[Diagnostics](docs/DIAGNOSTICS.md)** — when something does not work

## Tests

```bash
python dgb.py test              # everything, about 30 seconds
python dgb.py test --quick      # skip the DOSBox suites
```

Stdlib `unittest`, nothing to install. The DOSBox suites need `nasm` and
`dosbox` and skip cleanly without them. CI runs the suite on every push, and
fails if the prebuilt binaries in `bin/` do not match the sources they claim to
come from.

## Games

Games are **not** included — copyright and size. `python dgb.py samples --list`
shows a small set of freeware and public-domain titles the tooling can fetch for
trying things out. You are responsible for licence compliance for anything else
you add.

## Building from source

```bash
python dgb.py build
```

Needs NASM. Sources in `src/` are authoritative; `bin/` holds the prebuilt
results so the project can be deployed without a cross-assembler, and CI
verifies the two agree.

## License

MIT for the launcher sources and tooling — see [LICENSE](LICENSE).
Third-party games keep their original licences.

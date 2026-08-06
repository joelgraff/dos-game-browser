# DOS Game Browser

A full-screen game launcher for **real MS-DOS hardware** — 8086 and up, text UI
on MDA, CGA, EGA or VGA. Pick a game from a menu, play it, come back to the menu.

The launcher is 8086 assembly so it runs on the machines it is for. The tooling
that prepares a disk is Python, so it works the same on Linux, macOS and Windows.

```text
  Arrows move  Enter=Play                F12 or CTRL+ALT+BKSP exits game
  ------------------------------------------------------------------------
  * Platform
      Commander Keen 1
      Jill of the Jungle
  * Puzzle
      Tetris
```

## Start here

| You are… | Guide |
|----------|-------|
| Setting it up **on the DOS machine**, carrying files over on a floppy | **[Install on DOS](docs/01-install-on-dos.md)** |
| Preparing a **CF card or disk image** on a modern PC | **[Prepare an image](docs/02-prepare-image.md)** |
| Trying it under **DOSBox** first | **[Test in DOSBox](docs/03-test-in-dosbox.md)** |
| Stuck | **[Diagnostics](docs/DIAGNOSTICS.md)** |

Reference: **[file formats and limits](docs/FORMAT.md)** ·
**[real hardware notes](docs/HARDWARE.md)**

## Keys

| Key | Action |
|-----|--------|
| ↑ ↓ · PgUp PgDn · Home End | Move |
| Enter | Play |
| A–Z | Jump to a title |
| Esc | Quit — `START.BAT` restarts it, which is the kiosk behaviour |
| **F12** | Force-exit a running game ([not every game](docs/DIAGNOSTICS.md#the-force-exit-does-nothing)) |

`F12` is the default; set `ABORT_KEY=F11` in `DGB.CFG` if a game needs it for
play. Anything from `F1` to `F12`, or a raw scancode.

There is also a maintenance exit that leaves the loop and drops to DOS, kept out
of the UI so a machine in a public space cannot be trivially exited:
**Shift+Esc**.

## Tooling

```bash
python dgb.py doctor      # what this machine has, and what it lets you do
python dgb.py --help      # all commands
```

`doctor` is the place to start if something is missing. Prebuilt binaries ship
in `bin/`, so deploying needs neither NASM nor DOSBox — only rebuilding and
local testing do.

## Layout

```text
dgb.py     one entry point for host-side tasks     src/    NASM sources
dgb/       the Python tooling                      bin/    prebuilt .COM files
docs/      the guides above                        tests/  python dgb.py test
```

Games are never stored here, and the layout on the target is yours to choose —
the tooling builds it wherever you point it.

## Contributing

```bash
python dgb.py test        # 58 tests, about 30 seconds, nothing to install
python dgb.py build       # rebuild the .COM files (needs NASM)
```

CI runs the suite on every push and fails if `bin/` does not match `src/`.
The DOSBox-backed tests skip cleanly when DOSBox is absent.

Games are **not** included — copyright and size. `python dgb.py samples --list`
shows a few freeware and public-domain titles for trying things out; you are
responsible for licence compliance for anything else you add.

## License

MIT for the launcher sources and tooling — see [LICENSE](LICENSE).
Third-party games keep their original licences.

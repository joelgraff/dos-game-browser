# DOS Game Browser

A full-screen game launcher for **real MS-DOS hardware** — 8086 and up, text UI
on MDA, CGA, EGA or VGA. Pick a game from a menu, play it, come back to the menu.

The launcher is 8086 assembly so it runs on the machines it is for. The tooling
that prepares a disk is Python, so it works the same on Linux, macOS and Windows.

```text
  Arrows move  Enter=Play            SCRLOCK or CTRL+ALT+BKSP exits game
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
| **Scroll Lock** | Force-exit a running game ([not every game](docs/DIAGNOSTICS.md#the-force-exit-does-nothing)) |

There is also a maintenance exit that leaves the loop and drops to DOS, kept out
of the UI so a machine in a public space cannot be trivially exited:
**Shift+Esc**.

## Choosing the force-exit key

Scroll Lock is the default: no common DOS game reads it, and unlike F11/F12 it
exists on an 83-key XT keyboard. To change it, edit `DGB.CFG` and **delete the
leading `;`, or the line stays a comment**:

```ini
ABORT_KEY=F11
```

It takes a key name, `F1`–`F12`, or a raw make-code in hex —
[the full list is in FORMAT.md](docs/FORMAT.md#key-names-and-their-make-codes).
Ctrl+Alt+Backspace always works as well, whatever you set, so a mistake here
cannot lock you out.

## Status

Feature-complete for its purpose, and exercised end to end under DOSBox — the
test suite drives the real `.COM` files, not a model of them.

Worth knowing before you deploy:

- **Nothing here has been run on period hardware yet.** Everything is verified
  under DOSBox and by construction. DOSBox is more forgiving than an 8086 about
  memory and keyboard handling, so treat the first run on a real machine as the
  actual test.
- **The force-exit hotkey cannot reach every game.** Digger Remastered is the
  known case, and *why* is still open — see
  [Diagnostics](docs/DIAGNOSTICS.md#the-force-exit-does-nothing). Ctrl+Alt+Del
  and the machine's power switch remain the fallback; most games are fine.
- **Games that ship a DOSBox launch script** work under emulation and fail on
  real DOS. The scanner detects and skips those in favour of the real
  executable, but a script it does not recognise would slip through.
- `DGB.CFG` is read up to 1 KB. Past that the launcher says `TRUNCATED` in its
  self-test rather than silently ignoring a setting.

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
python dgb.py test        # the suite; about a minute, nothing to install
python dgb.py build       # rebuild the .COM files (needs NASM)
```

CI runs the suite on every push and fails if `bin/` does not match `src/`.
Tests that need NASM or DOSBox skip cleanly when those are absent, so the
count you see locally depends on what is installed.

Games are **not** included — copyright and size. `python dgb.py samples --list`
shows a few freeware and public-domain titles for trying things out; you are
responsible for licence compliance for anything else you add.

## License

MIT for the launcher sources and tooling — see [LICENSE](LICENSE).
Third-party games keep their original licences.

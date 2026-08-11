# Diagnostics

`BROWSER.COM` can report what it actually resolved, rather than leaving you to
infer it from a blank screen. Run it from the launcher directory:

```
C:\DGB> BROWSER.COM /T > TEST.TXT
```

Under DOSBox the mount is a host directory, so read the file directly:
`~/your-image/DGB/TEST.TXT`.

```text
DGB SELFTEST
ABORT=1
KBD scancodes=26 last=15 ctrlalt=00 grabs=0 armed=1 pend=0 busydos=0 irq1off=0 wdticks=157
CFG=1
PFX=GAMES\
PFXABS=\GAMES\
NENT=18
E0 T1 O137 Action
E1 T0 O147 Bouncy Ball
...
R1 DIR=BOUNCYBA EXE=BOUNCYB.COM YEAR=1983 PUB=Public Domain NOTE=Demo
```

| Line | Meaning |
|------|---------|
| `ABORT=` | 1 if `ABORT.COM` is resident |
| `CFG=` | 1 if `DGB.CFG` was found and read |
| `PFX` / `PFXABS` | The games root the launcher resolved, relative and absolute |
| `NENT=` | Entries loaded from `GAMES.LST`, headers and spacers included |
| `E<n>` | One per entry: type (0 game, 1 header, 2 spacer), file offset, title |
| `R<n>` | The full record re-read from disk using that offset |
| `KBD` | Keyboard state — see [below](#the-force-exit-does-nothing) |
| `KBC` | 8042 controller state around the last game — see [below](#the-kbc-line) |

The `R` lines matter more than they look: they are re-read from `GAMES.LST` by
seeking to the offset stored in the entry, so if they are right, the index is
genuinely being parsed correctly.

---

## "ERROR: GAMES.LST not found"

The launcher looks for `GAMES.LST` in the current directory, then `C:\GAMES.LST`.
You are probably running `BROWSER.COM` from somewhere other than the launcher
directory, or the index was never built.

```
C:
CD \DGB
SCAN C:\GAMES
```

## "ERROR: cannot run game" with DOS error code 02

Error 02 is *file not found*. The launcher changed into the game's directory but
the executable was not there. The last line of the error screen shows the path
it tried.

Almost always the recorded directory and the executable disagree — commonly a
`GAME.TXT` with `exe=KEEN1.EXE` in a directory where the real file is in a
`KEEN\` subdirectory. The Python scanner corrects this automatically and reports
it:

```
Entry corrections (review these):
  COMMANDE: exe=KEEN1.EXE is not in that directory; using KEEN\KEEN1.EXE
```

Re-run the scan. If you built the index with `SCAN.COM` on DOS, check that
`exe=` names a file that is actually in that directory.

## A game starts, then reports "Out of memory"

`BROWSER.COM` stays resident as the parent process while a game runs, so it
costs the game some conventional memory. It keeps that to about 8.9 KB by
handing its 11 KB entry table back to DOS before starting a child, and taking it
back afterwards.

If a game still runs out:

- load fewer TSRs and drivers before `START.BAT`
- check `MEM` on the target; a real machine with drivers can have far less free
  than DOSBox's ~620 KB
- `ABORT.COM` costs about 1.1 KB resident and can be left out — you lose
  force-exit

## The force-exit does nothing

`ABORT.COM` sees the hotkey by sitting in the keyboard interrupt chain. Some
games read the keyboard hardware directly and never generate an interrupt, and
no hotkey can reach us in those.

First check it is loaded at all, and which key it is watching — the self-test
reports both:

```
ABORT=1 HINT=SCRLOCK or CTRL+ALT+BKSP exits game
```

`HINT` is exactly what the browser's header shows, and it names the key that is
really in force. If it still says `SCRLOCK` after you set `ABORT_KEY`, check
three things:

- the line is **not** commented out — `;ABORT_KEY=F11` does nothing, the `;`
  has to go
- the file is the one next to `BROWSER.COM`, in the launcher directory, not one
  level up in the image root
- the value is one the parser accepts — a name from the
  [FORMAT.md table](FORMAT.md#key-names-and-their-make-codes), `F1`-`F12`, or a
  hex make-code. Anything else falls back to the default
`ABORT=0` means the TSR is not resident at all: `START.BAT` loads it, but only
if `UTILS\ABORT.COM` is present.

Then play the game, press the abort key a few times, quit normally, and run the
self-test. The counters are reset when a game starts and frozen when it exits,
so the `KBD` line describes that session and nothing else:

| Reading | Meaning |
|---------|---------|
| `scancodes=0` | Our handler never ran. The game owns the keyboard; nothing can be done |
| `scancodes>0`, `pend=1` | The chord was recognised but the abort never completed |
| `scancodes>0`, `busydos>0` | Recognised, but DOS was too busy to terminate the game |
| `armed=0` | The hotkey was already spent — it should re-arm per game, so this is a bug |
| `last=FA` | `FAh` is a keyboard controller acknowledgement, not a keystroke: the game is talking to the keyboard hardware itself |

Measured on a real catalog: Jill of the Jungle, Sopwith and Commander Keen all
force-exit correctly. Digger Remastered does not, and why is **still open**.

Its reading is `scancodes=2 last=FA grabs=0 irq1off=0`. That was once written up
as "it polls port 60h and consumes each scancode first", but the same reading
argues against that being the whole story: `grabs=0` means the vector stayed
ours and `irq1off=0` means IRQ1 was never masked, so the handler was installed
and reachable and still saw almost nothing. Draining port 60h does not by itself
prevent the interrupt — reading the port does not clear the request latched in
the 8259, so the handler should still have been entered on every key.

`last=FA` is the keyboard's ACK to a command, so Digger does talk to the
hardware directly. The leading theory is that it tells the 8042 to stop raising
IRQ1 and then polls, which every counter on the `KBD` line would report as
innocent. The `KBC` line below exists to test that.

`grabs`, `irq1off` and `wdticks` are only sampled when the TSR hooks the timer,
which it does for `/W` and `/P`. **`wdticks=0` means the sampler never ran, so
`grabs` and `irq1off` mean nothing** — they will read zero whether or not
anything happened.

### The KBC line

```
KBC base=45 game=44 last=44
```

The 8042 command byte, sampled at three points: `base` when the game was
launched, `game` about two seconds in, `last` most recently. **Bit 0 is the
keyboard interrupt enable.** A game that clears it stops IRQ1 being raised at
all, and then no `INT 09h` handler can see the keyboard however firmly it holds
the vector — a failure invisible everywhere else on the `KBD` line, because the
PIC mask stays clear and the vector stays ours.

| Reading | Meaning |
|---------|---------|
| `base=45 game=44` | odd → even: **the game turned the keyboard interrupt off.** This is the case worth finding |
| `base` and `game` equal | the game left the controller alone; look elsewhere |
| `base=--` | the controller did not answer the query at all. Expected under DOSBox, which does not emulate it — this line is only meaningful on real hardware |
| `game=--`, `last=--`, `base` present | no game has run since the TSR loaded, or the controller was busy at every sample |

A dash is never a value: a sample that was not taken prints `--` so it cannot be
confused with a byte of `00`.

Sampling needs the timer hook, so run the game with the probe:

```bat
UTILS\ABORT.COM /P
```

`/P` samples and reports without touching anything — unlike `/W` it never
reclaims the vector, so it cannot change how a game behaves. Under `/P`,
`grabs` counts *ticks on which the vector was somebody else's* rather than times
it was taken back, which makes it a cleaner reading of whether a game hooks
`INT 09h` at all.

### `ABORT.COM /W`

The other opt-in timer mode. It watches the keyboard interrupt vector and takes
it back if a game grabs it:

```bat
IF EXIST UTILS\ABORT.COM UTILS\ABORT.COM /W
```

It is off by default because it puts the TSR in front of a game that expects
exclusive keyboard control, which is a real risk per game. Measured on the test
catalog, no game actually needed it — `grabs=0` throughout. Its main present use
is making the diagnostic counters meaningful.

## The menu is missing games

- `NENT` in the self-test shows how many entries were loaded. If it is lower
  than expected, the index is short, not the browser.
- Game directories must sit at most **three levels** below the games root.
- A directory holding a launchable file is a game and is not searched deeper, so
  a game nested inside another game's folder will not appear.
- The scanner refuses to write an index over **320 entries** rather than writing
  one that gets truncated; it says so on stderr.

## Nothing appears at all / the screen is wrong

`UTILS\VDETECT.COM` reports what video hardware the launcher detects. The
browser picks colour or monochrome attributes automatically; if it guesses
wrong on unusual hardware, that is worth reporting.

## Checking the binaries match the sources

Prebuilt `.COM` files ship in `bin/`, and a stale one is invisible and expensive
to debug — an entire debugging session in this project was spent on an image
holding an old binary.

```bash
python dgb.py build
git status --short bin/
```

Anything listed means what you deployed was not built from the current sources.
CI enforces this on every push.

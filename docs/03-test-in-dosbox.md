# Test it under DOSBox

For trying the whole thing on a modern machine before committing anything to
real hardware — the same image, the same launcher, the same games, without a
reboot or a card reader.

DOSBox is not a substitute for testing on the target: emulation is more
forgiving about memory and keyboard handling than a real 8086 is. It is very
good at catching the ordinary problems, though — a wrong path, a missing game, a
badly chosen executable.

---

## 1. Check DOSBox is available

```bash
python dgb.py doctor
```

```
Python      3.12.3  (linux)
NASM        /usr/bin/nasm
DOSBox      /usr/bin/dosbox
Prebuilt    present (BROWSER.COM 9088B, ABORT.COM 3978B)
SCAN.COM    present (10160B) - the index can be built on the DOS machine

Everything needed is present.
```

If DOSBox is missing, install it. Detection covers `PATH`, the usual
`Program Files` locations on Windows, `.app` bundles and both Homebrew prefixes
on macOS, and flatpak.

```bash
sudo apt install dosbox          # Debian/Ubuntu
brew install dosbox              # macOS
```

To use a particular build instead of the detected one, pass `--dosbox`:

```bash
python dgb.py run --dosbox ~/builds/dosbox-x/dosbox-x --image-root ~/dos-image
```

## 2. Point it at an image

Any directory works — a mounted card, a loopback-mounted image, or just a
directory laid out the way the target will be.

If the image is already prepared (see [Prepare an image](02-prepare-image.md)):

```bash
python dgb.py run --image-root ~/dos-image --launcher-dir DGB
```

If it is not, add `--install` and both happen in one step — the launcher is
copied in, the games are scanned, and DOSBox starts:

```bash
python dgb.py run --install --image-root ~/dos-image
```

`run` on its own never installs anything. Pointed at an unprepared image it
stops and tells you, rather than starting DOSBox into a prompt where nothing
works.

That mounts the image root as `C:`, changes into the launcher directory, and
runs `START.BAT` — exactly what happens on the real machine.

Tired of typing it?

```bash
python dgb.py run --image-root ~/dos-image --launcher-dir DGB --save
python dgb.py run
```

The saved settings go in `dgb-local.json`, which is git-ignored.

## 3. Getting out again

| Key | Effect |
|-----|--------|
| Esc | Quits the browser — `START.BAT` restarts it |
| **Shift+Esc** | Leaves the loop, drops to the DOS prompt |
| `exit` at the prompt | Closes DOSBox |
| Ctrl+F9 | Kills DOSBox from anywhere, including mid-game |

Use **Shift+Esc**, not Ctrl+Alt+Esc: desktop window managers grab that
combination before DOSBox sees it, and the window merely loses focus.

---

## Getting files back out

The mount **is** a host directory, so there is nothing to copy:

```
C:\DGB\TEST.TXT   is   ~/dos-image/DGB/TEST.TXT
```

Anything written inside DOSBox appears there immediately, and you can edit
`GAMES.LST` or `GAME.TXT` in your usual editor while DOSBox is running. That
also sidesteps DOSBox having no `MORE`, which makes long files awkward to read
with `TYPE`.

## Games that misbehave under DOSBox but not on hardware

**Repack launch scripts.** Many downloads ship a `.BAT` that configures the
emulator. Those work here and fail on real DOS, which is why the scanner skips
them in favour of the real executable. If a game works under DOSBox and not on
the target, this is the first thing to check.

**Memory.** DOSBox gives roughly 620 KB free. A real machine with drivers loaded
may have considerably less, so a game that just fits here may not fit there.

**The keyboard.** Force-exit behaviour differs, because DOSBox's keyboard
emulation is not identical to real hardware. Confirm it on the target.

## When something does not work

`BROWSER.COM` has a self-test that reports what it actually resolved:

```
C:\DGB> BROWSER.COM /T > TEST.TXT
```

Then read `~/dos-image/DGB/TEST.TXT` on the host. It reports whether `DGB.CFG`
was found, the resolved paths, every parsed entry, and keyboard state. See
[DIAGNOSTICS.md](DIAGNOSTICS.md) for how to read it.

## Using the reference config

`dgb.py run` passes its settings on the command line and does not read
`config/dosbox.conf`. That file is a reference for the settings worth having
(`memsize=16`, `machine=svga_s3`, EMS and XMS enabled) if you would rather
drive DOSBox yourself:

```bash
dosbox -conf config/dosbox.conf
```

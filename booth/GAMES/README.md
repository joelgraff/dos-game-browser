# Games directory

Put each game in its own 8.3-friendly folder under this directory:

```text
GAMES\
  JILLOFTH\
    JILL.EXE
    GAME.TXT
```

## Metadata

Create or edit `GAME.TXT` in each folder (see `docs/FORMAT.md`), then rebuild the index:

```bash
python tools/scan-games.py
```

## Getting sample games

Games are **not** included in this repository. On a machine with network access:

```bash
python tools/fetch-samples.py          # free/public-domain pack
python tools/fetch-samples.py --list   # show catalog
python tools/scan-games.py             # rebuild GAMES.LST
```

Or copy any MS-DOS games you own into `booth/GAMES/<DIR>/` and run `scan-games.py`.

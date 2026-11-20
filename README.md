# Afterimage map tracker

An in-game map tracker for **Afterimage**: a UE4SS Lua mod that draws a
marker on the game's own map for every check (treasure boxes, items lying on
the ground, coin rocks; 868 places). Each unchecked one shows the inventory
icon of the item it holds, a label names the item, and a check you have
collected keeps its icon, dimmed and grey, under a grey `x`. It tracks the loaded save: nothing to
connect, no other program to run.

It was split out of the Afterimage Archipelago randomizer, whose mod
(`AfterimageAP`) has the same overlay built in. This mod is the overlay alone,
for playing the normal game. It also follows a randomizer game if the
randomizer's client is running (see "Randomizer support").

## Install

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (tested with 4.0.0)
   for Afterimage: extract it into `Afterimage\Binaries\Win64\` of the game
   folder, next to `Afterimage-Win64-Shipping.exe`.
2. Copy the `AfterimageMapTracker` folder of this repo into
   `Afterimage\Binaries\Win64\ue4ss\Mods\`.
3. Enable it. The folder has an empty `enabled.txt`, which enables it; or add
   the line `AfterimageMapTracker : 1` to `ue4ss\Mods\mods.txt`.
4. Start the game, load a save and open the map.

The mod writes nothing to your save and changes nothing in the game. It
logs to the UE4SS console and `UE4SS.log` with the prefix
`[AfterimageMapTracker]`.

## Using it

- At the default zoom, the marker nearest the middle of the map view gets a
  label: pan the map (arrow keys) onto a marker to read it.
- Zoomed in to 2.0 or more (`D`, about 3 to 4 taps), every visible marker
  gets one. Zoomed out to the area overview, the markers are hidden.
- Icons and labels keep one size on screen at every zoom, so zooming in
  spreads them out.
- Where an item's icon cannot be loaded, a coloured symbol is drawn instead:

| Marker | Meaning |
|---|---|
| item icon | unchecked check (any kind) |
| `#` magenta | treasure box (no icon) |
| `o` cyan | item lying on the ground (no icon) |
| `$` yellow | coin rock (no icon) |
| `x` grey over a faint grey icon | checked (any kind) |

Coin rocks and dew bundles show the game's dew (currency) icon. Boss drops
and quest rewards have no position on the map, so they are not drawn. The
Sea of Souls chests are on the voyage map, not on the area map.

## Configuration

Optional: a text file `AfterimageMapTracker.flag` in the folder of the game
exe (`Afterimage\Binaries\Win64\`), with any of these words, separated by
spaces or new lines. It is read again every 2 s while the map is open, so
you can change it without restarting the game.

| Word | Effect |
|---|---|
| `legend` | show a legend in the map's bottom left (off by default) |
| `noicons` | coloured symbols instead of item icons |
| `nolabels` | no labels |
| `norocks` | hide the coin rocks (307 of the 868) |
| `nocollected` | hide checked locations instead of drawing a grey `x` |
| `plaincollected` | a checked location shows only the grey `x` (default: the `x` over its dimmed, greyed icon) |
| `vanilla` | always track the save and ignore a randomizer list (below) |
| `noload` | never load an icon the map has not loaded itself (some balms and weapon recolours then keep the symbol) |
| `off` | draw nothing (unless a randomizer list is in use) |
| `both` | draw even when the randomizer's mod is enabled (see "Coexistence") |

For example, a file holding `legend norocks` shows the legend and hides the
coin rocks. Without `AfterimageMapTracker.flag`, the mod reads the
randomizer launcher's `AfterimageAP_tracker.flag` (same words) if there is
one.

## Randomizer support (optional)

The tracker labels each check with the item it holds in the unrandomized
game. In a randomized game, that is wrong. If the Archipelago randomizer's
client is running, it writes its list of open checks
(`AfterimageAP_missing.txt`, next to the game exe). When that list belongs to
the save being played (the randomizer marks its saves), the tracker shows the
checks on that list and their state, and labels each one with the placed
item if the list names it. It uses only the file; no randomizer code is
needed. The word `vanilla` turns this off.

## Coexistence with the randomizer's mod

The randomizer's mod (`AfterimageAP`) contains the same overlay. If both mods
are enabled, every marker would be drawn twice. So this mod draws nothing
while UE4SS loads `AfterimageAP` (its `enabled.txt`, or
`AfterimageAP : 1` in `mods.txt`), and logs why. The randomizer's overlay
then does the tracking. Disable one of the two mods, or add the word `both`
to the flag file to draw anyway.

## Repository layout

| Path | What |
|---|---|
| `AfterimageMapTracker/` | the mod folder to copy into `ue4ss/Mods` |
| `AfterimageMapTracker/Scripts/main.lua` | entry point: config, coexistence check, starts the overlay |
| `AfterimageMapTracker/Scripts/map_overlay.lua` | the overlay (markers, icons, labels, legend, tracking) |
| `AfterimageMapTracker/Scripts/transition.lua` | pauses the overlay around pawn switches (the flying fish) |
| `AfterimageMapTracker/Scripts/data_*.lua` | generated data: positions, locations (save id, kind, vanilla item, icon), item name to icon |
| `data/` | inputs of the generated data, copied from the randomizer repo |
| `tools/gen_tracker_data.py` | writes the `data_*.lua` files from `data/` |
| `tools/item_icons.py` | writes `data/item_icons.tsv` from the game data dumps in the randomizer repo |
| `tests/map_overlay_test.py` | offline tests (real Lua 5.4 through `lupa`, fake UE4SS objects) |
| `dev/map_probe.lua` | the randomizer repo's in-game experiment modes for the map, used by the tests |
| `docs/game-internals.md` | research notes: the map's widgets, transform, zoom, icons |

## Regenerating the data

The data comes from the Afterimage randomizer repo (location table, world
positions, English item names, icon frames). With a checkout of it next to
this one:

```
python tools/gen_tracker_data.py --source ../afterimage_rando
```

copies the inputs into `data/` and rewrites the three `data_*.lua` files.
Without `--source`, it regenerates them from the `data/` already here. To
rebuild the icon table from the game data dumps in the randomizer repo
first: `python tools/item_icons.py --source ../afterimage_rando`.

## Tests

```
python -m venv .venv-test
.venv-test\Scripts\pip install lupa
.venv-test\Scripts\python tests\map_overlay_test.py
```

They run the overlay and `main.lua` in Lua 5.4 against fake UE4SS objects:
markers, tracking, flag words, the randomizer list, zoom, labels, icons, the
coexistence check. How it looks needs the game.

## Future work

- (Done: collected checks keep their icon, dimmed under the grey `x`;
  flag word `plaincollected` for the `x` only.)

## Credits

By CATastrophe-1987, split out of his Afterimage Archipelago randomizer. Runs
on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS). Afterimage is a game by
Aurogon Shanghai; this is a fan-made mod, not affiliated with its makers.

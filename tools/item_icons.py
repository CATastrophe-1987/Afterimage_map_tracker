"""Item id -> icon frame, from the game's item data table, for the map overlay.

    python tools/item_icons.py --source ../afterimage_rando   # writes data/item_icons.tsv
    python tools/gen_tracker_data.py                          # puts the icons into the Lua data

The game data it reads lives in the randomizer repo (--source, default
../afterimage_rando): data/tab_rows_zh.tsv and the mapitemicons probe's
data/overlay_icons_2026-11-20/loaded_textures_map_open.txt. Names and
locations come from this repo's data/ (tools/gen_tracker_data.py --source
refreshes them).

Every item row of the game's .tab tables (data/tab_rows_zh.tsv, dumped by
tools/tabrows.py) has its inventory icon in the column `UI_icon_path`: the
name of a VtaSlateTexture atlas frame (`Icon_Potion_HPPotionSmall`,
`Icon_Bg_Twojump`, ...), not the item id (only about half the location items
have a frame named `Icon_<id>`). The frames live in
/Game/Assets/Texture2D/ItemIcon/Frames/ (atlas Icon64) or, a few,
/Game/Assets/UMG/TextureAtlases/ItemIcon/Frames/ (atlases Icon256A..D).
Which ones are loaded with the map open comes from the "mapitemicons"
probe's list of every loaded texture (2026-11-20,
data/overlay_icons_2026-11-20/loaded_textures_map_open.txt; frame names
compare without case, as UE's names do: the table says
`Icon_Accessories_002`, the asset is `icon_Accessories_002`). The rest (the
balms' `Icon_Potion_bottle*`, some `_C01` recolours) exist in the game's
files (LoadAsset found all 12 asked) and are loaded by the overlay when
needed; a recolour that cannot be had falls back to its base frame.

Coins (`Coins_<n>`, the coin rocks' bundles) have no item row: they get the
HUD's dew (currency) icon, `ST_HUD1_Button_Gold` (a blue drop with a
swirl; found by the same probe, a full object path since it is not an item
icon frame), not Se's Coin (`Icon_Quest_Coin01`, a key item).

Columns: item id, frame, atlas directory if seen loaded with the map
("" if not: loaded on demand), English name, number of locations holding it
in the vanilla game.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT.parent / "afterimage_rando"   # the randomizer repo (--source)
TAB_ROWS = SOURCE / "data" / "tab_rows_zh.tsv"
LOADED = SOURCE / "data" / "overlay_icons_2026-11-20" / "loaded_textures_map_open.txt"
OUT = ROOT / "data" / "item_icons.tsv"
COIN_FRAME = "/Game/Assets/UMG/TextureAtlases/HUD/Frames/ST_HUD1_Button_Gold.ST_HUD1_Button_Gold"   # the HUD's dew (currency) icon, a full path: not an item icon frame


def item_frames() -> dict[str, str]:
    """Item id -> UI_icon_path, from every item row (the row with a type_enum
    wins: food ids are also in the cooking table)."""
    csv.field_size_limit(10 ** 9)
    with TAB_ROWS.open(encoding="utf-8", newline="") as f:
        rows = list(csv.reader(f, delimiter="\t"))
    header = rows[0]
    col = {name: i for i, name in enumerate(header)}

    def get(row, name):
        i = col[name]
        return row[i] if i < len(row) else ""

    frames: dict[str, tuple[str, bool]] = {}
    for row in rows[1:]:
        item, frame = get(row, "ID"), get(row, "UI_icon_path")
        if not item or not frame:
            continue
        typed = bool(get(row, "type_enum"))
        if item not in frames or (typed and not frames[item][1]):
            frames[item] = (frame, typed)
    return {item: frame for item, (frame, _) in frames.items()}


def loaded_frames() -> dict[str, str]:
    """Lower-case frame name -> its directory, for the frames seen loaded."""
    out = {}
    if LOADED.exists():
        for line in LOADED.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.search(r"VtaSlateTexture (/Game/\S*?/Frames)/([^/.\s]+)\.", line)
            if m:
                out.setdefault(m.group(2).lower(), m.group(1))
                out.setdefault(f"{m.group(1)}/{m.group(2)}.{m.group(2)}".lower(), m.group(1))   # full paths
    return out


def english_names() -> dict[str, str]:
    out = {}
    for row in (ROOT / "data" / "item_names_en.tsv").read_text(encoding="utf-8").splitlines():
        fields = row.split("\t")
        if row and not row.startswith("#") and len(fields) >= 2 and fields[1]:
            out[fields[0]] = fields[1]
    return out


def main() -> int:
    global TAB_ROWS, LOADED
    parser = argparse.ArgumentParser(description="Item id -> icon frame (data/item_icons.tsv).")
    parser.add_argument("--source", type=Path, default=SOURCE, help="the randomizer repo (game data dumps)")
    args = parser.parse_args()
    TAB_ROWS = args.source / "data" / "tab_rows_zh.tsv"
    LOADED = args.source / "data" / "overlay_icons_2026-11-20" / "loaded_textures_map_open.txt"
    if not TAB_ROWS.exists():
        raise SystemExit(f"{TAB_ROWS} not found: pass --source <randomizer repo>")
    frames = item_frames()
    loaded = loaded_frames()
    english = english_names()
    locations = json.loads((ROOT / "data" / "locations.json").read_text(encoding="utf-8"))
    held = Counter(e["item"] for e in locations if e["kind"] in ("BOX", "PICKUP", "ROCK"))
    every = {e["item"] for e in locations}          # boss drops too (no map position)
    for item in every:
        if item.startswith("Coins_"):
            frames[item] = COIN_FRAME
    lines = ["# item id\ticon frame\tatlas dir (seen loaded with the map open)\tEnglish name\tvanilla locations"
             "   (tools/item_icons.py, from the item table's UI_icon_path)"]
    for item in sorted(frames):
        frame = frames[item]
        lines.append(f"{item}\t{frame}\t{loaded.get(frame.lower(), '')}\t{english.get(item, '')}\t{held.get(item, 0)}")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")

    loc_items = [i for i in held]
    with_frame = [i for i in loc_items if i in frames]
    seen = [i for i in with_frame if frames[i].lower() in loaded]
    n_loc = sum(held.values())
    n_frame = sum(held[i] for i in with_frame)
    n_seen = sum(held[i] for i in seen)
    print(f"{len(frames)} items with an icon frame; location items: {len(with_frame)} of {len(loc_items)} "
          f"with a frame, {len(seen)} seen loaded; locations: {n_frame} of {n_loc} with a frame, {n_seen} seen loaded")
    print(f"all location item ids (boss drops too): {sum(1 for i in every if i in frames)} of {len(every)} with a frame")
    missing = sorted(set(loc_items) - set(with_frame))
    unseen = sorted(i for i in with_frame if i not in seen)
    if missing:
        print("no frame:", missing)
    if unseen:
        print("frame not seen loaded:", [(i, frames[i]) for i in unseen])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

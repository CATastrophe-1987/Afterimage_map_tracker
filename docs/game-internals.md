# Game internals: the in-game map and the overlay

These notes are the map chapter of `docs/game-internals.md` in the
Afterimage randomizer repo (the "Map overlay probe" chapter: the map's
widgets, the overlay transform, "Map zoom: TargetZoom", "Map zoom: the panel
is scaled", the standalone tracker, checked locations, kinds and labels, item
icons), copied as they were at randomizer commit 0c14a89. They are research
logs from in-game runs. Paths in them refer to the randomizer repo:
`client/AfterimageAP/Scripts/` is `AfterimageMapTracker/Scripts/` here
(`map_probe.lua` is `dev/map_probe.lua`), `tools/gen_lua_data.py` is
`tools/gen_tracker_data.py`, and the experiment runner
(`tools/run_experiment.ps1`, `experiment.lua`), the screenshots and the
probe logs under `data/` stay in the randomizer repo.

## Map overlay probe (to run)

First step toward an in-game map overlay of checks. Experiment mode
`mapprobe` (`positions_test.lua`, then `map_probe.lua`):

```
powershell -ExecutionPolicy Bypass -File tools\run_experiment.ps1 -Mode mapprobe -TimeoutSeconds 900 -Tail 25
```

1. The game starts and loads save slot 4 by itself (about 70 s).
2. **Position sweep** (a few minutes, hands off): every streaming sublevel is
   loaded invisibly, like the catalog. Writes `AfterimageAP_positions.txt`:
   each check's and boss's position from its serialized
   `RootComponent.RelativeLocation` (the catalog's registered location read
   (0, 0) for 543 of 561 actors), plus each sublevel's bounds.
3. **Map probe**: when the runner beeps and prints `>>> ACTION: open the
   in-game map`, open the map and leave it open. The widgets that appear are
   dumped to `AfterimageAP_mapprobe.txt` (tree, canvas positions and sizes,
   textures, text, zoom/offset-like properties, the player's world position).
   Then a magenta "AP TEST" label is added to the map's busiest canvas panel.
4. When it says you can close the map, note whether and where the label
   showed. The runner then closes the game and restores slot 4 from
   `%USERPROFILE%\Documents\AfterimageSaveBackup_2026-11-16`.

Both output files land next to the game exe.

**Run on 2026-11-16:** the sweep placed all 561 checks (none at 0,0), 1,220
sublevel bounds and the boss actors; saved as `data/positions.tsv`. But
afterwards the player's own rooms were unloaded and only a backdrop showed,
so the map could not be opened. Run the map part on its own, in an untouched
world:

```
powershell -ExecutionPolicy Bypass -File tools\run_experiment.ps1 -Mode mapui -TimeoutSeconds 500 -Tail 25
```

(`positions` runs the sweep alone.)

**`mapui` run on 2026-11-16 (slot 4):** the "AP TEST" label showed on the map.
The map (`Minimap_C`, `/Game/Assets/UMG/Minimap`) is one image of a render
target (`MinimapFinalRT`) inside an Overlay that the ScaleBox zooms and
scrolls; two CanvasPanels share that overlay and its pixel space:
`CustomSignPanel` (player signs) and `MapNamePanel` (area names; "Rubiwood
Desert" at 672.1, 428.3). Markers added there move with the map. Dump:
`data/mapprobe_2026-11-16.txt`. Still unknown: world position -> map pixel.
`mapui` now also dumps the player's MinimapComponent, the MinimapConfig struct,
`DT_MinimapConfig` rows and the render target size; run it on a save with the
whole map discovered (more area labels to fit against):

```
powershell -ExecutionPolicy Bypass -File tools
un_experiment.ps1 -Mode mapui -Slot 1 -TimeoutSeconds 500 -Tail 25
```

**`mapui` run on slot 1 (100% save), 2026-11-16** (`data/mapprobe_slot1_2026-11-16.txt`):

- `DT_MinimapConfig` (struct `MinimapConfig`: LevelName, LevelNameRune,
  thumbnails, MapLevel) is the game's own area list: 27 rows, Lv1 Rubiwood
  Desert ... Lv5-01 Resting Town, Lv5 Resting Path, Lv18 Field of Hydro,
  Lv26 Misty Waters, Lv27 Teardrop.
- The map image is a 1280x720 render target (`MinimapFinalRT`) re-rendered
  for the current pan and zoom, so the label panel's positions are view
  pixels: Rubiwood's label was at (672, 428) in one run and (-9580, -2357)
  in the next. An overlay must re-place markers when the view changes.
- `MinimapComponent` (`/Script/Minimap`, on the player) holds `PreviewLoc` /
  `CacheLoc` (the view position in map units; 3158.6, 5593.8 here) and
  references `MinimapCollection` (`MinimapInfoCollection`) and
  `MinimapUIInfoCollection`, the likely per-room map layout.
- Fitting the 24 area labels to the areas' world centres gives no usable
  linear transform (rms ~1900 px): the map is probably laid out per room, not
  as a scaled copy of the world.

Next: mode `mapdata` (no map opening, fully automatic) dumps the component and
both collections deep, to `AfterimageAP_mapdata.txt`:

```
powershell -ExecutionPolicy Bypass -File tools\run_experiment.ps1 -Mode mapdata -Slot 1 -ManualLoad -TimeoutSeconds 900 -Tail 15
```

**Loading saves for UI probes.** By default an experiment calls
`ContinueGame()` from the title screen. That skips the menu flow and leaves
the title menu alive underneath, which disturbed the map probes above (their
widget lists and view state may not match normal play). With `-ManualLoad`
the runner prompts you to load the save through the menus, and the experiment
starts 8 s after a gameplay (LD_) room is visible. Use it for `mapui` and
`mapdata`; the earlier `mapui` dumps should be redone that way.

**Title menu and `-MenuLoad` (2026-11-16).** Recordings
(`data/titlerecord*_2026-11-16.txt`): the title menu is `GameTitleMenu_C`
(items are `OptionItem1_C`, e.g. `StartGame`), the profile list is
`ArchivedMenu_C` with one `ArchivedItem_C` per slot (`ArchivedItem1..4`).
Keyboard/controller confirm runs no hookable Blueprint function (the game's
Lua UI handles it; only `SetSelected` highlights fire), but the entries'
mouse-click events hand off to the same code. `menu_load.lua` calls them:
StartGame's `Button_55` click, then the slot's `Button_1P` click (or
`ArchivedInfo_P1` for slots that also hold a 42 save). Verified on slot 4:
loaded straight into the game, no fallback. Use `-MenuLoad` for UI probes.

**`-MenuLoad` by key presses (2026-11-17).** Clicking from Lua left the
title menu holding keyboard focus, so `-MenuLoad` now uses real keys sent by
the runner: Enter on START GAME, then Down/Up one at a time until a hook on
`ArchivedItem_C:SetSelected` reports `ArchivedItem<slot>` (entry N is
GameSave<N>), then Enter. Key presses are sometimes lost in the profile
menu (one run needed 7 moves for 3 steps; an unverified Down x3 loaded
GameSave3 instead of GameSave4), so the selection is always confirmed
before Enter. Verified on slot 4 (level 6, Lv1) and slot 1 (GameSave1, level
99, which stands in Nigredo Tower). After this load, holding Right moved the
player 274 units, so input reaches the character.

**Minimap data (`mode mapdata`, `data/mapdata_2026-11-16.txt`).**
`MinimapCollection` (`/Script/Minimap.MinimapInfoCollection`): world `Bound`
X -179109.8 .. 339040.4, Y (= world Z) -141217.9 .. 97729.9;
`MinimapScale` 0.04 (map px per world unit; the full map is about
20726 x 9558 px); tile sections 512 x 576. The UI collection
(`MinimapEditorUIInfoCollection`) has the same scale with 2048 x 1152 tiles.
Not yet read: the map properties `MinimapInfoMap`, `MapGroupInfo`,
`LevelRangeInfo` (per-area / per-room placement); `mapdata` now reads maps
too. Rerun, fully automatic:

```
powershell -ExecutionPolicy Bypass -File tools\run_experiment.ps1 -Mode mapdata -MenuLoad -TimeoutSeconds 600 -Tail 15
```

**World -> map conversion (2026-11-16, `data/mapdata_2026-11-16.txt`,
`data/minimap_bounds.tsv`).** `MinimapInfoMap` holds one `MinimapInfo` per
area: its world `Bound` (X, Z) and a map texture
(`/Game/Assets/Minimap/LevelSections/<area>`) whose pixel size is exactly
the bound times `MinimapScale` (Lv5: 51200 x 25600 units -> 2048 x 1024 px).
So the map is a 0.04-scale copy of the world:

    map_x = (world_x - (-179109.83)) * 0.04
    map_y = (world_z - (-141217.89)) * 0.04     (vertical direction on screen: to confirm)

551 of the 560 catalogued checks (`data/positions.tsv`) lie inside their own
area's bound with the second axis = world Z; the 9 others are border rooms
(Lv5 incl. Resting Town, Lv11). The earlier label fit's scale 0.053 was 0.04
times the map zoom of that moment. The on-screen transform is settled below.

**Map overlay transform, confirmed in game (2026-11-17, mode `mapcal`,
`data/mapcal_2026-11-17.txt`, screenshots `data/screens/mapcal_*_2026-11-17.jpg`).**
Fully automatic run on slot 4 (`-MenuLoad`). The mod placed a magenta "+"
in `MapNamePanel` for every catalogued check, using

    panel_x = 1472/2 + (world_x - centre_x) * 0.04 * CurrentZoom
    panel_y =  828/2 - (world_z - centre_z) * 0.04 * CurrentZoom

with the centre = the player's world position (the map opens centred on
the player). The markers landed on the drawn rooms of Rubiwood Desert. So:

- `MapNamePanel` is 1472 x 828 design pixels (`SizeBox_MapSize`) and its
  middle is the view centre. On a 2560 x 1440 screen that is 0.064 screen
  px per world unit at the default zoom 1.2 (0.04 x 1.2 x 1440/1080).
- Screen y grows **against** world Z.
- Children added to `MapNamePanel` draw above the map but under the legend.
- Zooming (`A` / `D` on the map): the zoomed screenshot's markers are off
  scale because they were placed at `CurrentZoom`, which lags; the map is
  drawn at `TargetZoom`. See "Map zoom: TargetZoom" below.
- Panning: see the live overlay below (`PreviewLoc` is the view centre).
- Markers in dark areas are checks in rooms this save has not uncovered.

**Live overlay (`map_overlay.lua`, 2026-11-17, mode `mapoverlay` on the
100% save, `data/overlay_2026-11-17.txt`, `data/screens/overlay_*.jpg`).**

- `Minimap_C.PlayerMinimapComp.PreviewLoc` is the view centre in map px,
  `(world_x, -world_z) * 0.04`, and follows panning: holding Right for
  1.5 s moved it +900 in X, Up for 1.2 s -720 in Y. It is 0,0 while the map
  is closed. `CacheLoc` did not change with the view.
- So the transform is, at any pan and zoom:

      panel = (736, 414) + ((world_x, -world_z) * 0.04 - PreviewLoc) * CurrentZoom

- The map's coordinates are those of the check positions in
  `data/positions.tsv` (sublevel-relative), not always the player actor's:
  in Sunken Sanctum (slot 1) the player stood at world 142669, -84211, i.e.
  map 5706.8, 3368.4, but the map opened centred on 3158.6, 5593.8, where
  the area's checks are drawn correctly. That area is streamed in with an
  offset. The player position is used only if `PreviewLoc` is 0.
- The overlay re-places its markers every 33 ms while the map is open
  whenever the centre or zoom changed. (This note first said the zoomed
  screenshots showed markers on their rooms; at the time it read
  `CurrentZoom`, which is wrong after a zoom step. See the next section.)
- The legend in the panel's top right draws under the markers, so markers
  are hidden there (x >= 1110, y <= 390 in panel px).
- Zoom runs from 0.2 to 3.0; A / D step `TargetZoom` by 0.25. Below the
  default 1.2 the game switches to an overview with area names and counts
  (seen at a logged 1.156, which was the lagging `CurrentZoom`; `TargetZoom`
  was 0.95 then), so the overlay hides every marker below zoom 1.18.
  The area labels' visibility and render opacity read the same at every
  zoom, so the game's switch itself is not detectable from them
  (`data/overlay_zoom_2026-11-17.txt`, `data/screens/overlay_zoomout_2026-11-17.jpg`).
- The game's per-area counts are not our locations; see "Map area counts".

**Map zoom: TargetZoom (2026-11-19, from the logs and screenshots above, no
new game run).** Bug report: when zooming on the map, the crosses moved a
different amount from the map. Cause: the overlay scaled by
`Minimap_C.CurrentZoom`, which is not the zoom the map is drawn at.

- `Minimap_C` zoom properties: `TargetZoom` (A / D add or subtract 0.25,
  clamped to `MinZoom` 0.2 .. `MaxZoom` 3.0), `CurrentZoom`, `ZoomingTime`
  2.0, `ScaleCurve` (`/Game/Assets/UMG/Data/MinimapScaleCurve`, a
  CurveFloat), `ZoomingEnabled` (false right after a step), `Slider_Zoom` (the
  zoom bar on the left), `CursorLastPosition`. `MinimapComponent.MinimapUIScale`
  stays 1.0. The pan is `MinimapComponent.PreviewLoc` (view centre in map px).
- `CurrentZoom` does not follow `TargetZoom` while the game is paused on the
  map: after one D press it read 1.2449 both 250 ms and 3.25 s later
  (`data/overlay_2026-11-17.txt`, `zoom_in_mid` / `zoom_in_end`), and in
  `data/mapcal_2026-11-17.txt` it read 1.2445 with `TargetZoom` 1.45. Every
  later step in `data/overlay_zoom_2026-11-17.txt` read about 0.045 past the
  previous target (1.4054, 1.1556, ... 0.7447), unchanged until the next
  press. (The 2026-11-16 `mapprobe` run, loaded with `ContinueGame()` and
  probably not paused, had it converged: 0.20004 for 0.2.) Probably an
  interpolation driven by the paused world's delta time; not confirmed.
- The drawn map follows `TargetZoom`. In `data/screens/mapcal_default` and
  `mapcal_zoomed` (zoom 1.2 -> target 1.45, view centre fixed on the player
  at screen 640, 362), the Confluence icon is (248, 216) px from the player
  at 1.2 and (300, 260) at the target, and the top right corner of the
  dashed area (400, -209) and (484, -251): a ratio of 1.21 both, which is
  1.45 / 1.2 = 1.208. `CurrentZoom` would give 1.037, and the markers placed
  with it moved by that much (the `marker` lines of that file): too little.
- The zoom is around the view centre (the player icon did not move), so the
  pivot is the panel's middle, as the transform assumes:

      panel = (736, 414) + ((world_x, -world_z) * 0.04 - PreviewLoc) * TargetZoom

- Fix: `map_overlay.lua` reads `TargetZoom` (falls back to `CurrentZoom` if
  it cannot be read). Its status line now shows both
  (`zoom=1.4500 (CurrentZoom 1.2449)`). Offline test: `tools/map_overlay_test.py`,
  "zoom step (TargetZoom)".
- **To verify in the game:**
  - whether the map visibly animates between steps. If it does, for that
    moment the markers already sit at the end zoom (they jump, the map
    glides). Fine if short; if not, model the animation from `ZoomingTime`
    and `ScaleCurve`.
  - zoom with the mouse wheel or the zoom bar too, if the game allows it:
    that may zoom around the cursor (`CursorLastPosition`). If so, the game
    must move `PreviewLoc` with it, which the overlay reads every tick; check
    that markers stay on their rooms then too.
  - whether the area-name overview still starts just below 1.2 (the
    overlay's `HIDE_BELOW_ZOOM` 1.18) now that the zoom read is `TargetZoom`.
  - Plan: mode `mapoverlay` (pans, zooms in, zooms out 6 times and back 3
    times, a screenshot and a status line after each, all by itself) on a
    save in a well-explored area, e.g.
    `powershell -ExecutionPolicy Bypass -File tools\run_experiment.ps1 -Mode mapoverlay -Slot 1 -TimeoutSeconds 600 -Tail 20`.
    In `AfterimageAP_overlay.txt`, `zoom=` must equal the target step
    (1.45, 1.2, 0.95, ...), and in the `ov_zoom_in_end` / `ov_zoom_out_1`
    screenshots the crosses must sit on the same rooms / box icons as in
    `ov_pan_up`. By hand: open the map, put a cross on a known box (the
    game's own icon or a room you know), zoom in and out (A / D, and the
    mouse wheel if it zooms) with the view at different places, pan, and
    check the cross stays on it.

**Map zoom: the panel is scaled (2026-11-19, in game; supersedes the fix
above).** Mode `mapoverlay` on slot 4 loaded from a copy of GameSave1 (Field
of Hydro), three runs, slot 4 restored `True` each time, GameSave1/2/3/5
unchanged. Log `data/overlay_zoom_2026-11-19.txt`, contact sheet
`data/screens/overlay_zoom_fix_2026-11-19.jpg` (left before, right after).

- **The TargetZoom fix still drifted, the other way.** With markers at
  `offset * TargetZoom`, a cross 283 px right of the player at 1.2 was at 412
  px at 1.45 and 602 px at 1.75: ratios 1.456 and 2.127, i.e. (1.45 / 1.2)^2
  and (1.75 / 1.2)^2, while the map's own features moved by 1.21 and 1.46.
  The crosses also grew (blob 69 -> 108 -> 147 px).
- **Cause:** the game scales the map widget, `MapNamePanel` included, by the
  zoom. `ScaleBox_ScrollingBox.UserSpecifiedScale` (the ScaleBox above
  `SizeBox_MapSize` / `Overlay`, which holds both `MinimapImg` and
  `MapNamePanel`) reads exactly `TargetZoom` (1.2, 1.45, 1.7, 1.15, ...), and
  reads 1 in the area-name overview. The markers are children of that panel,
  so they get the zoom from it; multiplying their offsets by the zoom again
  counted it twice. The 2026-11-17 "markers moved too little" came from the
  markers' panel coordinates, not from the screen.
- **Fix (`map_overlay.lua`):** inside the panel a marker sits at
  `(736, 414) + ((world_x, -world_z) * 0.04 - PreviewLoc) * 1.2`
  (`PANEL_ZOOM`; corrected to 1472 / 1280 = 1.15, `PANEL_PER_MAP`, and the
  panel's scale is the zoom itself, not zoom / 1.2: see "Seen in game" under
  "Map overlay: kinds and labels"), whatever the zoom; `TargetZoom` only decides what is in view
  (edge, legend, hiding). After the fix the same cross was at 283, 341, 400 px
  at 1.2, 1.45, 1.70: ratios 1.205 and 1.413 (map 1.208, 1.417). Panned to two
  other view centres and zoomed again (1.40, 1.65): crosses on the same rooms.
  The status line shows the scales (`scales=ScaleBox_ScrollingBox.user=1.4500`).
  Offline test: `tools/map_overlay_test.py`, "zoom step (panel scaled by the
  game)" (fails on the old code: the slot moved with the zoom).
- **Zoom keys:** A / D move `TargetZoom` by 0.05 per frame while held (an
  80 ms tap gave 0.25 or 0.30), so steps are not fixed; `CurrentZoom` moves only
  while a key is held and stays behind. The scale glides to the new zoom over
  roughly 0.3 s (burst screenshots 120 ms apart after a tap). Because the
  markers are scaled with the panel, they glide with the map: in the
  mid-glide shots they sit on their rooms (before the fix they ran ahead).
- **Hiding below 1.18:** at `TargetZoom` 1.15 the map was still the detailed
  room view (rooms drawn, ScaleBox 1.15) while the overlay hid every marker;
  at 0.95 it was the area-name overview (ScaleBox 1). The switch is somewhere
  in 0.95 .. 1.15; `HIDE_BELOW_ZOOM` is left at 1.18 (markers missing at 1.15
  is harmless; not tested between).
- Mouse wheel / zoom bar: not tried.

**Map area counts (2026-11-17, mode `countsweep` on the 100% save,
`data/countsweep_2026-11-17.txt`).** The map label is built in the map
widget's Blueprint as `S_levelname` + `</><Treasure1> (` or
`</><Treasure2> (` + `opened/total`. `Treasure2` (green) is used when the
area is complete, `Treasure1` otherwise.

- **opened** is the player's `prop_level_openedtreasurebox` (240) table
  entry for the area (`"Lv1"`, ...). On the 100% save every value equals its
  label (Lv1 55, Lv5 53, Lv7 48, Lv11 53, ...). The game's Lua adds to it
  through `add_level_openedtreasurebox_count`; a compensation flag
  (`prop_status_is_level_openedTB_refresh_compensation`) recounts it for
  old saves.
- **total** = treasure boxes (`BP_TreasureBox_High_C` / `_Great_C`) + placed
  pickups (`BP_DropActorAdv_C`) + coin rocks (`BP_MoneyStone_Small/Mid/Big`,
  `BP_MoneyStone_C`) in the area's sublevels. This matches every label with
  a count, including the five areas the 100% save has not finished:
  Resting Path 57, Field of Geo 66, Emerald Falls 56, Town of the Exiled 59,
  Albedo Tower 38. Resting Town (`Lv5-01`) has no count of its own; its
  objects are in Resting Path's.
- Areas without a count on the map: Resting Town, Misty Waters (no such
  objects), Nigredo Tower (Lv25, NG+; 29 objects, counter 23) and Lv27
  (13 objects, counter 10).

For the randomizer this means: a box opened or a placed pickup collected
raises the count, as does every coin rock (never a location). Boss drops
are not counted, pickups count even when `randomize_pickups` is off, and a
location checked from the server side (`!collect`, co-op) does not change
it. So the label can't serve as a "locations left" count.

In normal play `main.lua` starts the overlay. With the randomizer
connected it marks the locations listed in `AfterimageAP_missing.txt`. The
Python client writes that file (header `AP1 <seed> <slot>`, then one line per
unchecked location key, then `checked<TAB><key>` per checked one) whenever
the slot's missing or checked locations change, and deletes it on exit.
A client that is killed leaves the file behind, so the overlay uses it only
on a save played with its seed and slot: the bridge writes
`session_<seed>_<slot> = 1` into the save's `AfterimageAP` table in
`prop_dlg_save_data`, next to the delivered-item counter, and saves from
before that mark count when that counter is above 0. On any other save, a
normal one included, the overlay ignores the file and tracks the save itself
(status `list=tracker (list of another seed ignored)`). Experiments that
write a test list call `map_overlay.accept_session` instead of marking the
player's save.
Without that file, the overlay is a standalone tracker (below). Boss drops
have no position and are not marked. Checked locations are drawn grey (see
"Checked locations on the map" below).

### Standalone map tracker (2026-11-17)

The map overlay works without the randomizer. It reads which locations are
done straight from the loaded save, for every room, loaded or not:

- **By save id:** `SPropertyBlueprintLib:GetNumberValueBySaveID(save id, 11)`
  returns an actor's saved `prop_status_object_open` without its room being
  loaded. Mode `savetrack` (`savetrack_test.lua`) read all 868 locations
  with save ids (355 boxes, 206 pickups, 307 coin rocks) with no errors. On
  slot 4, which has only been in Lv1, it found 8/21 boxes, 14/14 pickups and
  8/20 coin rocks open in Lv1, and nothing elsewhere.
  `GetSaveDataIDSPropertyNumberValue` gives the same values.
- **Live state of loaded rooms:** the by-save-id value lags behind a box
  opened while playing: on 2026-11-18 a box opened in Lv11-4 (play log
  `BOX_OPEN` at 17:23:38) did not turn grey on the map. So the overlay also
  reads `prop_status_object_open` from the actors themselves (their
  `SPropComponent`) in loaded rooms, every second while the map is closed and
  at every re-read while it is open, and remembers "done" for the game run;
  the save id value still covers rooms not loaded. When the by-save-id
  value catches up (room unload, save point) was not measured. Loading an
  older save in the same game run keeps the remembered grey markers until
  their room is seen again.
- **Seen in game (2026-11-18 evening, mode `trackerlive`,
  `tracker_live_test.lua`, slot 4 menu-loaded, restored; logs
  `data/ingame_2026-11-18/trackerlive_run1.txt` / `_run2.txt`, screenshots
  `data/screens/trackerlive_*_2026-11-18.jpg`):**
  - A box opened live turns grey. Box `LD_Lv1_2_A:BP_TreasureBox_High_11314`
    opened from Lua (`OnPlayerHit`): live `prop_status_object_open` 0 -> 1
    within 3 s, by-save-id value still 0; the map then showed
    `markers=868 checked=25` (24 before) and the box `checked`.
  - **The by-save-id value does not catch up while playing**: still 0 after
    the map, after leaving the room and with the box's sublevel unloaded
    (about 60 s in all; the run never saves). So the live read is what
    makes the box grey.
  - It stays grey after leaving the room: teleported 24,000 away (Lv1_8),
    `LD_Lv1_2_A` unloaded within 1 s, map reopened: box still `checked`.
  - A leftover randomizer list of another seed (header
    `AP1<TAB>someseed<TAB>9`, 55 Lv1 keys unchecked) is ignored:
    `list=tracker (list of another seed ignored)`, `markers=868 checked=25`,
    the box still `checked`; after the file was removed, `list=tracker`.
  - **Side effect seen:** 3 placed pickups of rooms loaded later
    (`LD_Lv1_9_A:..._11331`, `LD_Lv1_8_A:..._11321`, `LD_Lv1_7_A:..._11312`)
    went from grey to "+" when their rooms loaded: open by save id (the drop
    appeared) but the drop still waits in the pickup's record. That is the
    designed rule (below; slot 4 has 6 drops lying uncollected), but the
    player sees a marker change from done to not done on entering a room.
- **Boxes and coin rocks:** open = done.
- **Placed pickups:** open only means the drop appeared (see "Placed
  pickups" above). In loaded rooms the tracker uses the exact rule (open,
  and the item no longer in the pickup's `prop_item_drop_record`), read live
  as above. In rooms it hasn't seen loaded, an appeared
  drop counts as collected, which is what normal play does. The drop
  record is a table, and there is no by-save-id call for tables.
- **Which locations:** `client/AfterimageAP/Scripts/data_locations.lua` (key
  -> save id, kind, area), generated by `tools/gen_lua_data.py` from
  `locations.json` and `data/rocks.tsv`, positions from `data_positions.lua`.
- **Display:** boxes magenta, pickups cyan, coin rocks yellow; done ones a
  grey "x". The save is re-read every 2 s while the map is open.
- **Options:** `AfterimageAP_tracker.flag` next to the game exe, optional.
  The word `off` turns the tracker off; `norocks` hides coin rocks;
  `nocollected` hides done locations (also with the randomizer).

Verified with mode `maptracker` on slot 4 (no randomizer, no missing
file): 844 markers placed, coloured by kind, on the undone Rubiwood Desert
locations (`data/screens/tracker_standalone_2026-11-17.jpg`). The mode steps
right first, because the map key does nothing while the player rests at
the save point after loading.

How the run is automated: the runner's `PRESS:` lines must not tap Alt when
the game is already in front (a lone Alt puts the window in menu mode), and
after a save is loaded the player rests at the save point with the map key
disabled until they move, so `mapcal` presses Right before M. This holds
with the key-press load too: without the step, M did nothing on slot 4.

### Checked locations on the map (2026-11-18, seen in game)

Checked locations no longer vanish from the map: they keep a marker, a grey
"x" (colour 0.6 grey, alpha 0.5, z-order 999, under the coloured "+" at 1000).

- **Standalone:** the done test is unchanged (open flag by save id, the
  pickup rule for loaded rooms). `tracker_text` now lists every location,
  done ones as `checked<TAB><key>`, the same shape as the randomizer file.
- **Randomizer:** the client adds `checked<TAB><key>` lines for
  `checked_locations` (a location in both sets counts as unchecked).
  Compatibility: a mod from before this treats every line as a key, finds
  no map position for `checked<TAB>...` and skips it (it shows the unchecked
  ones as before); this mod reading an older client's file shows only
  unchecked markers. The header stays `AP1`.
- **Live:** every 2 s while the map is open the list (and the flag) is
  re-read. A marker whose state changes is restyled in place (text, colour,
  z-order on the same widget); only markers whose key leaves the list are
  removed. Map closed: all removed, as before.
- **Hiding:** the flag word `nocollected` (launcher: untick "Show checked
  locations too") drops checked keys from the list, which is the old
  behaviour. Zoom (< 1.18), the panel edge and the legend hide grey markers
  like the others; it is the same loop.
- **Cost:** with grey markers the overlay makes up to 868 widgets (all
  locations with a position) every time the map opens; the standalone
  tracker already made 844 on slot 4. Per 33 ms tick nothing is called on
  the widgets while the view is still; when it moves, `SetPosition` only
  for the markers inside the panel (31 around the Lv1 start) and
  `SetVisibility` only on show/hide changes.
- **Offline tests:** `tools/map_overlay_test.py` (Lua 5.4 through `lupa`,
  fake UE4SS objects, the real location data; also runs the pre-change mod
  from git on a new file and the `maptracker` steps) and
  `tools/client_missing_test.py` (the client's file, Archipelago stubbed).

**To check in game:** mode `maptracker` on slot 4 (`-MenuLoad`), screenshots
`tracker_open` (grey x on what slot 4 has done in Lv1, coloured + on the
rest; log `markers=868 checked=24`, since the 2026-11-17 run placed 844
undone markers), `tracker_zoom_in`, `tracker_nocollected` (grey gone, same
view, `checked=0`) and `tracker_randomizer` (a test missing file: 55 Lv1
keys, every second one checked, `markers=55 checked=27`).

**Seen in game (2026-11-18, mode `maptracker`, slot 4, menu load):** all four
steps as expected:

```
tracker open: open=true markers=868 checked=24 visible=37 ... zoom=1.2000
tracker zoom_in: open=true markers=868 checked=24 visible=36 ... zoom=1.2660
tracker nocollected: open=true markers=844 checked=0 visible=14 ... zoom=1.4536
test missing file: 55 Lv1 keys, 27 checked
tracker randomizer: open=true markers=55 checked=27 visible=29 ... zoom=1.4536
tracker back to standalone: open=true markers=868 checked=24 visible=29 ... zoom=1.4536
```

Screenshots `data/screens/tracker_checked_open_2026-11-18.jpg`,
`..._nocollected_...` and `..._randomizer_...`: the grey "x" reads clearly
but is plainly subtler than the coloured "+", each sits in its room (on the
done Lv1 boxes, pickups and rocks), none under the legend; with
`nocollected` the same view shows only the "+". The look needed no change
(`CHECKED_TEXT` "x", `CHECKED_COLOR` 0.6 grey, alpha 0.5). Small things
seen: a marker near the left panel edge can show half-clipped, and one "x"
overlaps the "Rubiwood Desert" area label in the randomizer view.

**With a real client (2026-11-18, `tools/e2e_test.ps1 -Mode apmap`):** the
test opened closed box `LD_Lv1_2_A:BP_TreasureBox_High_11314` from Lua
(`OnPlayerHit`) after the client had connected. The bridge sent its `CHECK`,
the client's `AfterimageAP_missing.txt` had `checked<TAB>` for it within a
second, and the opened map showed `markers=355 checked=7` (the randomizer
list: boxes only in this seed), the box's marker in state `checked`, and all
348 unchecked boxes with a marker as "+"
(`data/screens/apmap_live_open_2026-11-18.jpg`, log
`data/e2e_2026-11-18/apmap.txt`). The first try opened no map: the box's
item came back from the server and its "acquired" screen ate the key
presses; the mode now presses Space before Right and M.

### Map overlay: kinds and labels (2026-11-19, seen in game; results at the end)

Request: replace the uniform crosses with icons, or at least tell what each
check is (assuming vanilla), as a tracker separate from the randomizer.

**Icons: what the game has (from the existing dumps, no new run).**

- The map's box / pickup / boss markers are not widgets. The map is one
  image of the render target `MinimapFinalRT` (1280 x 720), combined by
  `MinimapComponent` (C++) from `MinimapBaseRT`, `MinimapFogOfWarRT` and
  `MinimapSignRT` (`data/mapprobe_slot1_2026-11-16.txt`). The textures the
  component references are only its sign icons, all `Texture2D` under
  `/Game/Assets/UMG/TextureAtlases/Map/Sign/`: `Icon_Archive` (revive point),
  `Icon_Archive01` (teleport), `Icon_Shop`, `Icon_leader` (player),
  `Icon_Death` (dropped experience). `DropItemDT` points to the data table
  `/Game/Assets/Minimap/DropItemInfo` (61 rows; their fields were not
  dumped). On the screenshots (e.g. `data/screens/tracker_checked_open_2026-11-18.jpg`)
  the game draws no box or pickup icon in the room view at all; treasure
  appears only as the rich-text `<Treasure1>` / `<Treasure2>` count after
  each area name in the overview.
- The map widget's own icons (legend, zoom bar, NPC heads) are
  `VtaSlateTexture` atlas frames, `/Game/Assets/UMG/TextureAtlases/Map/Frames/ST_Map_Icon_*`
  (Star, Explore, Mark_01, Sign01..16, NPC portraits). Item icons are frames
  of another atlas, `/Game/Assets/UMG/TextureAtlases/ItemIcon/Frames/Icon_*`
  (one seen: `Icon_Quest_Poison01`).
- So there is no box / pickup / boss icon to reuse by path; the closest
  would be the item's own icon (vanilla mode) or a generic map frame. Using
  any of them needs a UMG `Image` (`StaticConstructObject` of
  `/Script/UMG.Image`) and `SetBrushFromTexture` (Texture2D) or
  `SetBrushResourceObject` (atlas frame), on an asset that is loaded
  (`StaticFindObject` finds only loaded objects; `LoadAsset` may hitch).
  None of this has been tried in the game, and a wrong brush call can crash
  it (UE4SS cannot catch an access violation), so the overlay does **not**
  use images. Experiment mode `mapicons` (`map_probe.icon_probe`) tests it on
  its own: it lists the loaded icon-like `Texture2D` / `VtaSlateTexture`
  objects to `AfterimageAP_mapicons.txt`, then puts one `Image` per
  candidate (Icon_Shop, Icon_Archive, Icon_Death, ST_Map_Icon_Star, the
  first loaded item icon frame) in a row left of the view centre, logging
  each call, screenshots `mapicons` and `mapicons_zoom`, and removes them.

**What the overlay does instead (`map_overlay.lua`):**

- **Kind markers:** TextBlock glyphs, ASCII only (the default font surely
  has them): `#` magenta treasure box, `o` cyan pickup, `$` yellow coin rock;
  ready but not drawn for lack of positions: `!` orange boss drop, `#` green
  Sea of Souls chest (kind `voyage`, level `Voyage`: on the voyage map, not
  in `data_positions.lua`), `?` white quest / script grant. Checked: the grey
  "x" as before (same colour, alpha, z-order 999).
- **Legend:** in the map window's bottom left, a title line with the mode
  (`Locations`, `Archipelago` or `Vanilla items`), one line per kind
  present on the map in its colour, and `x  Checked` if any. Screen-fixed:
  each line's slot is `(736, 414) + (W - (736, 414)) / zoom` and its render
  scale `0.72 / zoom` (W in window px; the panel's own scale is the zoom,
  see "Seen in game" below). Markers under it (and a line above it) are
  hidden. Hidden in the area overview (zoom < 1.18). Off by default since
  the markers are item icons: flag word `legend` (launcher checkbox "Show a
  legend of the marker kinds") turns it on; the old `nolegend` is accepted
  and changes nothing.
- **Labels:** a TextBlock per labelled marker, 9 panel px right of it
  (alignment and render pivot at its left middle), white, grey for a checked
  one, with a shadow, render scale `0.72 / zoom` (one size on screen). From
  `TargetZoom` 2.0 on, the visible markers get one (up to 40, nearest the
  view centre first), except where a label would overlap one already placed
  (estimated box: 11 window px per character, 22 high); below that, only the
  marker nearest the view centre, if it is within 70 window px: the player
  pans onto a marker to read it. The
  map's own cursor (`Minimap_C.CursorLastPosition`) was not used: what it
  holds is unknown, while `PreviewLoc` is verified. Label widgets are a
  pool, reused as the view moves; text and colour are set only when they
  change. Flag word `nolabels` turns them off.
- **What a label says (user request, 2026-11-19): what the item is, never
  an internal id**, in every mode. The item after a tab on the key's line of
  `AfterimageAP_missing.txt` when there is one (a scouted Archipelago item;
  not in the vanilla mode), else the vanilla item's English name
  (`data_locations.lua` `item`, from `locations.json` and
  `data/item_names_en.tsv`; `Coins_250` as `250 coins`; ` x3` for counts
  above 1), else the kind's name (`Treasure box`, `Pickup`, `Coin rock`).
  A text with an underscore and no space (`Item_...`, `Quest_...`, `Lv1_2`)
  counts as an id and is never shown; `gen_lua_data.py` writes `""` for an
  item without an English name (none of the 876 today). The Archipelago
  location name (`<room> - <Treasure Box | Pickup | Coin Rock> <save id>`,
  equal to `locations.json`'s for all 876, tested) is still built by
  `M.location_name` but no longer shown. The client does not scout
  (`LocationScouts`) and writes no item column; an older mod would look up
  `<key><TAB><item>` as a key and skip it.
- **Vanilla tracker mode:** flag word `vanilla` (launcher: Map tracker tab,
  "Vanilla tracker"). It never reads `AfterimageAP_missing.txt`, so it is
  the standalone save tracker whether or not a client is running, with
  vanilla item labels. Status `list=vanilla mode=vanilla`. Without it,
  nothing changes from before except glyphs, legend and location-name labels.
- **Failure handling:** labels and legend are placed in their own `pcall`
  after the markers. If a call fails in the game (e.g. `SetRenderScale`), the
  overlay logs `map overlay: labels / legend off: ...` once, hides them for
  the game run and keeps the markers working.
- **Status line:** now also `labels=<n>`, `mode=<tracker|randomizer|vanilla>`
  and `legend=<lines shown>`. `M.labels_shown()` / `M.legend_shown()` list
  them for experiment logs.
- **Data:** `data_locations.lua` gained `room` and `item` (85 KB to 126 KB).

**Offline tests (`tools/map_overlay_test.py`, 152 checks after the in-game
fixes below, all pass):** glyph and colour per kind; voyage kind; legend
lines, screen-fixed position and size at zoom 2.4, markers hidden under it,
off by default / `legend`, `norocks`, overview; focus label (centred marker, then at
54 .. 264 window px off: the label is on the nearest marker within 70 px, by
the test's own maths), labels at 2.4 with no two overlapping, one at 1.9,
none at 1.0, `nolabels`, label size; randomizer list (vanilla item names, an
item column wins), no label of the 876 locations is an id, an item without
a name (or an id) shows the kind; vanilla (every location from the save,
vanilla item names, the list ignored, done ones grey with a grey label,
opened live turns grey), back to randomizer and standalone; names equal to
`locations.json`; a failing `SetRenderScale` leaves markers working; the
`maplabels` experiment against the fakes. The earlier tests (checked
greying, flags, zoom, cost) pass unchanged except for the new glyphs.

**The in-game plan (as written before the runs; results below).** Two runs,
slot 4 (`-MenuLoad` default), the overlay as started by `main.lua`:

1. `powershell -ExecutionPolicy Bypass -File tools\run_experiment.ps1 -Mode maplabels -TimeoutSeconds 300 -Tail 40`
   (on slot 1, the 100% save, for a fuller map: `-Slot 1`). Screenshots
   `AfterimageAP_labels_*.png`, status and `label` / `legend` lines in the
   log. Compare:
   - `labels_default` (zoom 1.2): glyphs `#` / `o` / `$` in their colours on
     the rooms where the crosses were (`data/screens/tracker_checked_open_2026-11-18.jpg`,
     same view on slot 4); grey "x" unchanged; the legend in the bottom left,
     readable, not over the zoom bar or the button hints, nothing under it;
     at most one label, and if one, next to the marker nearest the middle.
     Glyph look: `o` and `$` vertically centred enough, `#` not too heavy.
   - `labels_pan`: the label moved with the view to another marker (or none).
   - `labels_vanilla`: legend title `Vanilla items`; the label an item name
     (check it against the log's `label <key> = <item>`); non-ASCII names
     (e.g. `Windwalker’s Anklet`) render, not as boxes.
   - `labels_vanilla_zoom` (log `zoom=` ~2.2 .. 2.4): every marker on screen
     labelled, labels the same text size as in `labels_vanilla`, legend the
     same size and place; how much they overlap (if too much: raise
     `LABEL_ALL_ZOOM`, lower `MAX_LABELS` or `LABEL_SCALE`).
   - `labels_default_zoom`: the same markers, labels now location names.
   - `labels_back` (~1.2): one label at most; `labels_overview`: no marker,
     label or legend (`visible=0 labels=0 legend=0`).
   - No `labels / legend off` line in `UE4SS.log`; if there is, it names the
     failing call (likely `SetRenderScale` / `SetRenderTransformPivot`).
2. `powershell -ExecutionPolicy Bypass -File tools\run_experiment.ps1 -Mode mapicons -TimeoutSeconds 200 -Tail 30`,
   only after run 1 and on its own (may crash). Compare `mapicons` /
   `mapicons_zoom`: which of the up to five images show (left of the
   centre, 40 px apart), at what size, whether they scale with the map;
   the log's `ok` / `failed` per call and `AfterimageAP_mapicons.txt`'s list
   of loaded item icon frames. If `SetBrushResourceObject` with an item icon
   frame works, the vanilla mode could show each location's item icon: that
   needs the item id -> icon frame mapping (the item data table's icon
   field) and a check that the frame is loaded with the map open.
3. Also worth a look by hand: the label's font size and shadow on a busy
   room, and whether the `LEGEND_*` / `FOCUS_RADIUS` constants need moving.

**Seen in game (2026-11-19 evening).** Four launches, all on slot 4 through
the menus, restored `True` each time, GameSave1..5 hashes unchanged, no
crash report, no `map overlay: labels / legend off` (nor any other overlay
error) in `UE4SS.log`. Logs in `data/overlay_labels_2026-11-19/`, contact
sheet `data/screens/overlay_labels_2026-11-19.jpg` (top row before the
fixes, the rest after), icons `data/screens/overlay_mapicons_2026-11-19.jpg`.

1. `maplabels` on a copy of GameSave1 (Field of Hydro, 843 of 868 done),
   the overlay as committed (`maplabels_run1_before.txt`):
   - Status lines carry `labels=`, `mode=`, `legend=`; modes, legend titles
     and label texts as designed (`Dim Balm`, `Twinborn Helmet`,
     `380 coins`, ...). Overview: `visible=0 labels=0 legend=0`. Labels one
     size at 1.2 and 2.25; the focus label sits next to the centred marker.
   - **Bug: the legend was outside the map window** (only the end of
     `# Treasure box` peeked out at the bottom-left clip edge).
   - **Bug: the markers were 4 % too far from the view centre.** A 250 map px
     pan moved the drawn rooms 460 screen px and the markers 480: up to
     ~33 screen px off at the window edge at 1.2, twice that at 2.4.
   - Zoomed in, labels overlapped each other (`Dim Balm380 coins`), the long
     location names worst.
   - Cause of both bugs: MapNamePanel is scaled by the **zoom itself**
     (`ScaleBox_ScrollingBox.UserSpecifiedScale` = `TargetZoom`, 1.2 at the
     default), not by zoom / 1.2, into a map window of 1472 x 828 window px
     (4/3 screen px each at 2560 x 1440; clip edges at screen x 299 / 2260,
     y 168 / 1272). And the 1280 px render target is stretched over 1472
     px: one map px is **1472 / 1280 = 1.15 panel px**, not 1.2. The old
     constant made markers right only near the centre; the legend's slot
     (meant as screen-fixed) landed 1.2 times too far out.
   - Fix (`map_overlay.lua`): `PANEL_PER_MAP = PANEL_W / 1280`; window px =
     `mid + (panel - mid) * zoom` for the in-view test, the game's legend
     area, the focus radius (now 70 window px) and our legend; labels and
     legend render at `0.72 / zoom` (the same size as before at 1.2).
     Zoomed in, a label overlapping a nearer one is dropped. Labels now say
     the item (user request above). A grey "x" just above the legend's title
     touched it, so markers up to a full line above the legend are hidden
     too (offline only, after the rerun).
2. `maplabels` again with the fixes, on slot 4's own save (Rubiwood Desert,
   glyphs on the undone ones; `maplabels_run2_after.txt`):
   - Glyphs `#` magenta, `o` cyan, `$` yellow on the rooms where the crosses
     of `tracker_checked_open_2026-11-18.jpg` were, about 4 % nearer the
     centre (the fix). `o` and `$` sit centred, `#` is fine; the grey `x` is
     unchanged. Zoomed in, the glyphs grow with the map as designed.
   - Legend: five lines in the map window's bottom left (screen x ~323,
     y ~1100 .. 1245), readable, clear of the zoom bar and the button hints;
     the same place and size at 2.2.
   - Focus label `Wooden Scythe` by the centred marker at 1.2; after the
     pan no marker within 70 px, so none. Zoom 2.2: 6 visible markers, 5
     labels (`Dim Balm`, `Talent Point`, `131 coins`, `131 coins`,
     `Talent Essence II`); the sixth, a coin rock whose label would have
     overlapped `Dim Balm`, has none. A label can still cover a neighbouring
     glyph (`Dim Balm` over a `$`). Default mode zoomed: the same item
     labels, title `Locations`.
   - `labels_back` landed at `TargetZoom` 1.10 (A steps are not fixed): the
     game still drew rooms (ScaleBox 1.1003) while the overlay hid
     everything (`HIDE_BELOW_ZOOM` 1.18), as noted before.
   - Not covered: a non-ASCII name (a curly apostrophe) on screen; none was
     in view.
3. `mapicons`, twice on a copy of GameSave1 (the first run's zoom shot came
   after the cleanup had removed the images; the probe now waits, and also
   pans): no crash. Log: `Texture2D loaded 1050, icon-like 138`,
   `VtaSlateTexture loaded 959, icon-like 672`, and **all five brush calls
   `ok`**: `Icon_Shop`, `Icon_Archive`, `Icon_Death` (Texture2D,
   `SetBrushFromTexture`), `ST_Map_Icon_Star` and the item frame
   `Icon_Quest_Poison01` (VtaSlateTexture, `SetBrushResourceObject`).
   - All five show, in a row left of the player, as the game draws them:
     shop bag, revive swirl, death ghost, a small ring (the star frame) and
     the item's potion picture. 32 x 32 panel px is ~51 screen px at 1.2.
   - They **scale with the map** on zoom (spacing 64 -> 78 screen px, 1.2 ->
     ~1.45), like the markers. They **do not follow a pan** by themselves
     (the panel is view-relative): an icon overlay must re-place them every
     tick, as it does the markers.
   - 630 item icon frames (`/Game/Assets/UMG/TextureAtlases/ItemIcon/Frames/...`)
     were loaded with the map open (`mapicons_loaded_textures.txt`).
4. **What a vanilla item-icon mode would take (built 2026-11-20: "Map
   overlay: item icons" below):** an item id ->
   icon frame table. Frame names are not the item ids (only 168 of the 319
   location item ids have a loaded `Icon_<id>` frame; e.g.
   `Icon_Weapon_DSword_002`), so read the item data table's icon field
   (dump it with a probe, generate a Lua table). A check that each frame is
   loaded when the map opens (`StaticFindObject`; glyph fallback when not,
   no `LoadAsset` hitch in the map). A pool of UMG Images in MapNamePanel
   placed by the same loop as the markers (re-placed on pan, scaled by the
   panel), ~24 panel px. Checked ones dimmed (`SetColorAndOpacity` / render
   opacity) or replaced by the grey `x`; coin rocks and unknown items kept
   as glyphs.

### Map overlay: item icons (2026-11-20, seen in game; balms and dews confirmed in run 4)

User decision: replace the kind symbols with each check's real item icon,
"if it wouldn't cause too much clutter"; then "just shrink the icons as you
zoom into them"; then: balms need their own icon, coin rocks the dew
(currency) icon, and coin labels say dews.

**Item id -> icon frame (`tools/item_icons.py` -> `data/item_icons.tsv`).**
Every item row of the game's .tab tables (`data/tab_rows_zh.tsv`) has its
inventory icon in the column `UI_icon_path` (also `drop_icon_path`, the same
value in all 707 rows that have it; `icon_path` / `ui_icon_path` are NPC map
heads and bestiary pictures). It names a `VtaSlateTexture` atlas frame, not
the item id: `Ability_DoubleJump` -> `Icon_Bg_Twojump`,
`Potion_EquipLevelUp_01` (Dim Balm) -> `Icon_Potion_bottle03`,
`Weapon_Sword_007` -> `Icon_Weapon_Sword_004_C01`. Frame names compare
without case (the table's `Icon_Accessories_002` is the asset
`icon_Accessories_002`).

- Coverage: 728 items with a frame; **all 319 location item ids** (boss
  drops included) have one: 298 from the table plus the 21 coin bundles
  (`Coins_<n>`, no item row), which get the dew icon. All 876 locations
  with a save id have an icon.
- Coin bundles / coin rocks: the HUD's dew counter icon,
  `/Game/Assets/UMG/TextureAtlases/HUD/Frames/ST_HUD1_Button_Gold` (a blue
  drop with a swirl; found by mode `mapitemicons`, which lists every loaded
  texture to `AfterimageAP_iconlist.txt` and showed the money-like ones in a
  numbered row: 1 `Knapsack/ST_Knapsack1_Button_Gold02`, a money bag; 2 the
  dew; 3 `Icon_Trade_Winebottle`). Not `Icon_Quest_Coin01`, which is Se's
  Coin, a key item (used before 2026-11-20). In `data_locations.lua` it is
  the short name `dew` (`map_overlay.lua` `NAMED_FRAMES`). Labels say
  `<n> dews` (the user: the currency is called dew; the game's own English
  word for it was not read).
- Loaded with the map open (list `data/overlay_icons_2026-11-20/loaded_textures_map_open.txt`):
  259 of the 268 location items' frames, 784 of 876 locations. Not loaded:
  the three balm bottles (`Icon_Potion_bottle`, `_bottle02`, `_bottle03`;
  Dim / Mysterious / Exotic Balm), `Icon_Item_Talent01_C01` and five weapon
  recolours `Icon_Weapon_*_C01`. All 12 exist in the game's files: UE4SS
  `LoadAsset` returned a valid object for each at the title screen. But
  loaded there, they were **garbage-collected by the save's level load**
  (gone 36 s later, `icon: ... not loaded` with the map open).
- `gen_lua_data.py` puts each location's frame in `data_locations.lua`
  (`icon = "..."`, 127 KB -> 147 KB) and English name -> frame for the
  item pool in `data_icons.lua` (522 names, 26 KB; scouted items).

**How the overlay draws them (`map_overlay.lua`).**

- An unchecked marker in view gets an `Image` (`/Script/UMG.Image`) in
  MapNamePanel with `SetBrushResourceObject(frame)`, centred on the
  marker's slot, z-order 1000; its glyph is hidden. Checked ones stay the
  grey `x` (no icon: an icon on each of 843 done locations would crowd the
  map, and the `x` reads as done).
- Which item: in randomizer mode the scouted item if the list names one (by
  English name, also without a trailing ` (<player>)`; `Coins_<n>`,
  `<n> dews` / `coins` -> the dew; another game's item -> no icon, the
  glyph), else the vanilla item.
- **Size:** `ICON_PX` = 34 window px at every zoom: slot 34 x 34 panel px,
  render scale `1 / zoom` (the panel is scaled by the zoom, like the
  labels), about 45 screen px at 2560 x 1440 with the art about 31 (the
  frames have a transparent margin). The first run used 28 (art about 25
  px: readable but small).
- **Pool:** Images are made only when more icons are on screen than ever
  before during this map opening, and reused as the view moves (a marker
  keeps its Image while in view; the Images of markers gone from view are
  freed first). The brush is set only when an Image gets another frame; a
  pan costs one `SetPosition` per icon, like a glyph. Offline: after 80
  pans 34 Images for a peak of 34 on screen.
- **Frames:** `StaticFindObject` in `/Game/Assets/Texture2D/ItemIcon/Frames/`
  (atlas `Icon64`), then `/Game/Assets/UMG/TextureAtlases/ItemIcon/Frames/`,
  once per map opening (cached). Not loaded: `LoadAsset` of that path when a
  marker needing it comes into view (map open; at most 4 per tick; each path
  once per map opening). Loading them while the map is closed does not
  work (garbage-collected, above); loaded just before use, the brush
  references the frame while it is drawn. A cached frame that is no longer
  valid is never handed to a brush (looked up again next tick). A recolour
  (`..._C01`) that cannot be had falls back to its base frame
  (`Icon_Weapon_Sword_004`, loaded). Flag word `noload`: no `LoadAsset`.
- **Labels** start right of the icon (`ICON_PX / 2 + 3` window px).
- **Legend:** a line after the title, `Icon  Vanilla item` (vanilla /
  standalone) or `Icon  Item, else vanilla` (randomizer), only when some
  unchecked marker has its icon loaded; the glyph lines stay (fallback).
- **Off:** flag word `noicons` (launcher checkbox "Show item icons", second
  on the Map tracker tab, default on): glyphs as before. Any failing icon
  call logs `map overlay: item icons off, glyphs instead: ...` once and
  turns icons off for the game run.
- Status line: `icons=<shown> pool=<Images made>`, `(icons off)` /
  `(icons failed)`. `M.icon_report()` (framed unchecked markers with the
  frame loaded, missing frames), `M.icons_shown()`, `M.perf()`.

**Offline tests (`tools/map_overlay_test.py`, 210 checks, all pass):**
icon per mode (vanilla, scouted name, scouted with a player suffix, another
game's item -> glyph, vanilla mode ignoring scouted items), coin rock ->
dew, constant on-screen size at 1.2 and 2.2, label right of the icon,
checked -> grey `x` without icon, legend line, a frame not loaded -> glyph,
none loaded -> glyphs only and no Image, lookups once per map opening,
loading on sight (never while closed, at most 4 per tick, no path asked
twice, recolour -> base, full object path), a collected frame never put in
a brush, pool reuse (no widget calls on a still view, one `SetPosition` per
icon on a pan, pool size = peak), checked live -> icon gone, map closed ->
Images removed, `noicons` and back (same Images), `noload`, a failing brush
call (logged once, glyphs for the game run), experiment `mapitemicons`.

**Seen in game (three launches, 2026-11-19 23:52 .. 2026-11-20 00:10, mode
`mapitemicons` = `map_probe.item_icons_test`, slot 4 loaded from a copy of
GameSave1 via `-SaveFrom`, menu-load; each run: `restored ... True`,
GameSave1..5 hashes unchanged, no crash report, no `map overlay:` error).
Logs `data/overlay_icons_2026-11-20/mapitemicons_run{1,2,3}.txt`, contact
sheet `data/screens/overlay_icons_2026-11-20.jpg`.**

- The save itself (843 of 868 done) shows only a few unchecked markers, so
  the run also writes a test list with every location unchecked (the
  densest the map gets: a new save) and pans to the densest stretches by
  `data_positions` (Silent Coast; Whispering Forest, 33 markers in view).
- Icons sit on the rooms where the glyphs were (each `icons` shot against
  its `glyphs` shot); they follow pans (re-placed each tick) and keep their
  size when zoomed to 2.15. In the densest view at 1.2 they do not crowd:
  no two touch; labels (focus label at 1.2, all from 2.0) are as before. A
  label can still cover a neighbouring icon when zoomed in.
- Default view, 1.2 (`icons_default`): icons for the 21 of 25 unchecked
  markers whose frames were loaded; the 4 balms drew `#`.
- **Performance:** `place_markers` max 1 ms per tick while panning (the
  first tick that makes 8 Images: 42 ms once); the world's delta seconds
  sampled every 100 ms during 3.8 s, 6.6 s and 0.8 s pans: average 16.7 ms,
  max 17.7 ms (60 fps, no stutter).
- **Screenshots after a long HOLD were stale** (run 2): the shot after a
  3.8 s / 6.6 s pan was pixel-identical to the next one, taken 3 s later
  with `noicons`, though the log showed the icons on. A short `PRESS: Up`
  after the pan (bringing the game to the front) fixed it in run 3. Runner
  screenshots right after a long HOLD should not be trusted.
- If a balm ever shows `#`, `M.icon_report()` names the frame; `noload`
  turns the loading off.

**Confirmed in game (run 4, 2026-11-20 00:20, same mode and save, one
launch, no code change; `restored ... True`, GameSave1..5 hashes unchanged,
no crash report, no `map overlay: item icons off` line in `UE4SS.log`).
Log `data/overlay_icons_2026-11-20/mapitemicons_run4.txt`, contact sheet
`data/screens/overlay_icons_after_2026-11-20.jpg`.**

- **On-sight loading works:** the default view logged `25 of 25 unchecked
  markers with a frame have it loaded` (run 3: 21 of 25, the balms
  missing). With every location unchecked, 865 of 868 at first (three
  `_C01` weapon recolours not yet in view), then 868 of 868 after the pans.
- **Balms:** Dim / Mysterious / Exotic Balm draw their bottles
  (`Icon_Potion_bottle03` / `_bottle02` / `Icon_Potion_bottle`), not `#`.
- **Coin rocks:** the dew (blue drop) with `<n> dews`, clearly unlike Se's
  Coin (gold coin) next to them.
- Pans smooth: world delta avg 16.7 / 16.6 / 16.3 ms, max 17.9 ms;
  `place_markers` max 1-3 ms. Pool 33 Images for a peak of 33.


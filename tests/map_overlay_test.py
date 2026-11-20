"""Offline test of the map overlay (map_overlay.lua), no game.

Runs AfterimageMapTracker/Scripts/map_overlay.lua in a real Lua 5.4 (the
`lupa` package) against fake UE4SS objects: an open Minimap_C whose
MapNamePanel records the TextBlocks the overlay adds, a by-save-id property
library for the standalone tracker, and optional loaded pickups. The game's
timer is driven by hand. Uses the real data_locations.lua / data_positions.lua.

    python -m venv .venv-test && .venv-test\\Scripts\\pip install lupa
    .venv-test\\Scripts\\python tests\\map_overlay_test.py

Checks: todo vs checked markers (glyph, colour, draw order), live restyling
while the map is open (same widget), the "nocollected" / "norocks" / "off"
flag words, the randomizer file with and without checked lines, the old mod
(tests/fixtures) reading a new file, hiding (zoom, edge, legend) for grey markers,
and how many widget calls a tick makes. Kinds and labels: the glyph and
colour per kind, the legend (screen-fixed, only kinds on the map,
"legend" opt-in, off by default), labels by zoom (one focus label at the default zoom, every
visible marker from 2.0, none zoomed out, "nolabels", constant size), the
vanilla tracker ("vanilla": vanilla item names, the randomizer's list
ignored) against the randomizer list (vanilla item names, or a scouted item
column), location names equal to locations.json's, a failing label call
leaving the markers working, and the "maplabels" experiment. How it looks
needs the game (see docs/game-internals.md, "Checked locations on the map"
and "Map overlay: kinds and labels"). Standalone mod: main.lua starts the
overlay with its own flag file, and draws nothing while the randomizer's
AfterimageAP mod is enabled (unless "both").
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

try:
    from lupa.lua54 import LuaRuntime
except ImportError:
    sys.exit("needs lupa: pip install lupa (into a venv)")

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "AfterimageMapTracker" / "Scripts"
DEV = ROOT / "dev"            # map_probe.lua (the randomizer repo's experiment modes)
OVERLAY = SCRIPTS / "map_overlay.lua"
OLD_OVERLAY_REV = "b0cc31c"   # map_overlay.lua before checked markers (randomizer repo commit)
OLD_OVERLAY = ROOT / "tests" / "fixtures" / f"map_overlay_{OLD_OVERLAY_REV}.lua"

FAKE_UE4SS = r"""
fake = { calls = {}, open = {}, waiting = {}, pickups = {}, sprops = {}, next = nil, constructed = {} }
local function count(name) fake.calls[name] = (fake.calls[name] or 0) + 1 end

local panel = { children = {} }
function panel:AddChildToCanvas(w)
    local slot = { widget = w }
    function slot:SetAutoSize() end
    function slot:SetAlignment() end
    function slot:SetZOrder(z) self.z = z end
    function slot:SetPosition(p) count("SetPosition"); self.x, self.y = p.X, p.Y end
    function slot:SetSize(s) self.w, self.h = s.X, s.Y end
    w.slot = slot
    self.children[w] = true
    return slot
end

local map = { CurrentZoom = 1.2, TargetZoom = 1.2, PlayerMinimapComp = { PreviewLoc = { X = 1, Y = 1 } }, MapNamePanel = panel }
function map:IsValid() return true end
function map:IsInViewport() return fake.map_open end
fake.map, fake.panel = map, panel

local lib = {}
function lib:IsValid() return true end
function lib:GetNumberValueBySaveID(id, prop) return fake.open[id] or 0 end

-- The loaded save: the player's prop_dlg_save_data entries under "AfterimageAP".
fake.save = {}
local player = {}
function player:IsValid() return true end
function player:GetFullName() return "PlayerCharacter /Game/Maps/World.World:PersistentLevel.PlayerCharacter" end
function player:GetAddress() return 1 end
local player_sprop = {}
function player_sprop:IsValid() return true end
function player_sprop:GetOuter() return player end
function player_sprop:GetOwner() return player end
function player_sprop:GetSPropTableNumberValue(id, path)
    if id == 29 and path[1] == "AfterimageAP" then return fake.save[path[2]] or 0 end
    return 0
end

function FText(s) return s end
function FindFirstOf(name)
    if name == "PlayerCharacter" then return player end
    return nil
end
function FindAllOf(name)
    if name == "Minimap_C" then return { map } end
    if name == "BP_DropActorAdv_C" then return fake.pickups end
    if name == "SPropComponent" then return { player_sprop, table.unpack(fake.sprops) } end
    return {}
end
-- Item icon frames: fake.frames nil = none loaded, true = all loaded (in the
-- first atlas directory), or a set of the loaded frame names.
function StaticFindObject(path)
    if path:find("SPropertyBlueprintLib", 1, true) then return lib end
    if path:find("/Game/", 1, true) == 1 then
        count("find_frame")
        local frame = path:match("/([^/.]+)%.[^/]+$")
        local loaded = (fake.frames == true and not path:find("/UMG/TextureAtlases/ItemIcon/", 1, true))
            or (type(fake.frames) == "table" and fake.frames[frame])
        if not loaded then return nil end
        -- fake.dead[frame]: garbage-collected since it was found.
        return { frame = frame, IsValid = function(self) return not (fake.dead and fake.dead[self.frame]) end }
    end
    return { name = path:match("%.([%w_]+)$"), IsValid = function() return true end }
end
function StaticConstructObject(class, outer)
    count("construct")
    if class and class.name == "Image" then count("construct_image") end
    local w = { vis = 0, class = class and class.name }
    function w:SetBrushResourceObject(obj)
        if fake.fail_brush then error("SetBrushResourceObject: access (test)") end
        count("SetBrush"); self.brush = obj.frame
    end
    function w:SetText(t) count("SetText"); self.text = t end
    function w:SetColorAndOpacity(c) count("SetColor"); self.color = c.SpecifiedColor end
    function w:SetVisibility(v) count("SetVisibility"); self.vis = v end
    function w:SetRenderScale(s)
        if fake.fail_render_scale then error("SetRenderScale: no such function (test)") end
        count("SetRenderScale"); self.scale = s.X
    end
    function w:SetRenderTransformPivot(p) self.pivot = p end
    function w:SetShadowOffset() end
    function w:SetShadowColorAndOpacity() end
    function w:RemoveFromParent() count("remove"); panel.children[self] = nil; self.removed = true end
    fake.constructed[#fake.constructed + 1] = w
    return w
end
-- Hooks (transition.lua's ClientRestart) and a wall clock for os.time.
fake.hooks, fake.wall = {}, 1000
function RegisterHook(path, fn) fake.hooks[path] = fn end
os.time = function() return fake.wall end
-- The game thread's timers, on a virtual clock.
fake.now, fake.timers = 0, {}
function ExecuteInGameThreadWithDelay(ms, fn)
    fake.timers[#fake.timers + 1] = { at = fake.now + ms, fn = fn, seq = #fake.timers }
end

-- Run the timers due in the next `ms` milliseconds, in order.
function fake.run(ms)
    local target = fake.now + ms
    while true do
        local best
        for i, t in ipairs(fake.timers) do
            if t.at <= target and (not best or t.at < fake.timers[best].at) then best = i end
        end
        if not best then break end
        local t = table.remove(fake.timers, best)
        fake.now = t.at
        t.fn()
    end
    fake.now = target
end

local positions = require("data_positions")

-- Geometry as measured in game (2026-11-19): the game scales MapNamePanel by
-- TargetZoom around its middle into the map window (1472 x 828 window px),
-- and one map px is 1472 / 1280 panel px.
fake.PPM = 1472 / 1280
-- The panel position (slot) of window px (wx, wy) at the drawn zoom.
function fake.panel_of(wx, wy)
    local z = map.TargetZoom
    return 736 + (wx - 736) / z, 414 + (wy - 414) / z
end
-- The shown marker drawn at window px (wx, wy), if any.
function fake.shown_at(wx, wy)
    local px, py = fake.panel_of(wx, wy)
    for w in pairs(panel.children) do
        if w.vis == 3 and w.class ~= "Image" and w.slot.x and math.abs(w.slot.x - px) < 0.01 and math.abs(w.slot.y - py) < 0.01 then
            return w
        end
    end
    return nil
end
-- The shown icon Image drawn at window px (wx, wy), if any.
function fake.icon_at(wx, wy)
    local px, py = fake.panel_of(wx, wy)
    for w in pairs(panel.children) do
        if w.vis == 3 and w.class == "Image" and math.abs(w.slot.x - px) < 0.01 and math.abs(w.slot.y - py) < 0.01 then
            return w
        end
    end
    return nil
end
-- Icon Images: made (in the panel), shown.
function fake.images()
    local n, shown = 0, 0
    for w in pairs(panel.children) do
        if w.class == "Image" then
            n = n + 1
            if w.vis == 3 then shown = shown + 1 end
        end
    end
    return n, shown
end
fake.printed = {}
print = function(s) fake.printed[#fake.printed + 1] = tostring(s) end
-- Markers (one-character glyphs; labels and legend lines are longer):
-- all, grey "x", coloured.
function fake.children()
    local n, grey, plus = 0, 0, 0
    for w in pairs(panel.children) do
        if type(w.text) == "string" and #w.text == 1 then
            n = n + 1
            if w.text == "x" then grey = grey + 1 else plus = plus + 1 end
        end
    end
    return n, grey, plus
end
-- The shown text widgets that are not markers (labels, legend lines).
function fake.texts()
    local out = {}
    for w in pairs(panel.children) do
        if type(w.text) == "string" and #w.text > 1 and w.vis == 3 then out[#out + 1] = w end
    end
    return out
end
function fake.centre_on(key, px, py)
    -- Put the location at window px (px, py) at the drawn zoom (TargetZoom).
    local pos = positions[key]
    local mx, my = pos[1] * 0.04, -pos[2] * 0.04
    local z = map.TargetZoom * fake.PPM
    map.PlayerMinimapComp.PreviewLoc = { X = mx - (px - 736) / z, Y = my - (py - 414) / z }
end
function fake.set_open(id, v) fake.open[id] = v end

-- A loaded placed pickup with its drop record.
function fake.add_pickup(key, item)
    local level, name = key:match("^(.-):(.+)$")
    local addr = #fake.pickups + 1000
    local actor = { item = item }
    function actor:IsValid() return true end
    function actor:GetFullName() return "BP_DropActorAdv_C /Game/Levels/" .. level .. "." .. level .. ":PersistentLevel." .. name end
    function actor:GetAddress() return addr end
    actor.ConstItemID = { ToString = function() return item end }
    local sprop = {}
    function sprop:IsValid() return true end
    function sprop:GetOwner() return actor end
    function sprop:GetSPropertyNumberValue(id) return fake.open[require("data_locations")[key].id] or 0 end
    function sprop:GetSPropTableNumberValue(id, path) return fake.waiting[path[1]] or 0 end
    fake.pickups[#fake.pickups + 1] = actor
    fake.sprops[#fake.sprops + 1] = sprop
end

-- A loaded box or coin rock whose live open flag is fake.live[key] (the
-- by-save-id value, fake.open, lags behind it as in the game).
fake.live = {}
function fake.add_actor(key, class)
    local level, name = key:match("^(.-):(.+)$")
    local actor = {}
    function actor:IsValid() return true end
    function actor:GetFullName() return class .. " /Game/Levels/" .. level .. "." .. level .. ":PersistentLevel." .. name end
    local sprop = { key = key }
    function sprop:IsValid() return true end
    function sprop:GetOwner() return actor end
    function sprop:GetSPropertyNumberValue(id) return fake.live[key] or 0 end
    fake.sprops[#fake.sprops + 1] = sprop
end
function fake.unload(key)
    for i, s in ipairs(fake.sprops) do
        if s.key == key then table.remove(fake.sprops, i); return end
    end
end
"""


class Overlay:
    def __init__(self, workdir: Path, source: Path | str = OVERLAY, show_all: bool = False):
        self.dir = workdir
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f"package.path = [[{SCRIPTS.as_posix()}/?.lua;{DEV.as_posix()}/?.lua;]] .. package.path")
        self.lua.execute(FAKE_UE4SS)
        self.fake = self.lua.globals().fake
        code = source.read_text(encoding="utf-8") if isinstance(source, Path) else source
        self.m = self.lua.execute(code)
        self.lua.globals().package.loaded["map_overlay"] = self.m   # require() gets this copy, as in the game
        self.m.start(self.lua.table_from({"show_all": show_all}))
        self.locations = self.lua.eval('require("data_locations")')
        self.positions = self.lua.eval('require("data_positions")')

    def run(self, ms: int) -> None:
        self.fake.run(ms)

    def open_map(self) -> None:
        self.fake.map_open = True
        self.run(400)

    def calls(self, name: str) -> int:
        return self.fake.calls[name] or 0

    def children(self) -> tuple[int, int, int]:
        return self.fake.children()

    def status(self) -> str:
        return self.m.status()

    def keys(self, kind: str | None = None, level: str | None = None) -> list[str]:
        out = []
        for key, d in self.locations.items():
            if self.positions[key] is not None and (kind is None or d.kind == kind) and (level is None or d.level == level):
                out.append(key)
        return sorted(out)

    def save_id(self, key: str) -> int:
        return int(self.locations[key].id)

    def widget(self, key: str):
        """The live widget for `key`: centre the view on it, then find it there."""
        self.fake.centre_on(key, 736, 414)
        self.run(40)
        return self.fake.shown_at(736, 414)

    def write(self, name: str, text: str) -> None:
        (self.dir / name).write_text(text, encoding="utf-8")


def check(condition: bool, what: str) -> None:
    print(("ok   " if condition else "FAIL ") + what)
    if not condition:
        check.failed = True


check.failed = False
GREY = (0.6, 0.6, 0.6, 0.5)


def colour(w) -> tuple:
    c = w.color
    return (round(c.R, 2), round(c.G, 2), round(c.B, 2), round(c.A, 2))


def run(name, test, **kw) -> None:
    print(f"--- {name}")
    with tempfile.TemporaryDirectory() as tmp:
        old = os.getcwd()
        os.chdir(tmp)
        try:
            test(Overlay(Path(tmp), **kw))
        finally:
            os.chdir(old)


def parse(o: Overlay) -> None:
    p = o.m.parse_list
    lst = p("AP1\tseed\t1\r\nA:x\r\nchecked\tB:y\r\nchecked\tA:x\r\n", False)
    check(lst["A:x"] == "todo" and lst["B:y"] == "checked", "todo and checked lines, CRLF, header skipped")
    lst = p("AP1\tseed\t1\nchecked\tA:x\nA:x\n", False)
    check(lst["A:x"] == "todo", "listed as missing wins over checked, in any order")
    lst = p("AP1\tseed\t1\nA:x\nchecked\tB:y\n", True)
    check(lst["A:x"] == "todo" and lst["B:y"] is None, "hide_checked drops checked lines")
    lst = p("AP1\tseed\t1\nA:x\nB:y\n", False)
    check(lst["A:x"] == "todo" and lst["B:y"] == "todo", "old-format file: every line is todo")
    check(len(list(p(None, False).keys())) == 0, "no text: nothing")


def standalone(o: Overlay) -> None:
    lv1 = o.keys(level="Lv1")
    box = [k for k in lv1 if o.locations[k].kind == "box"]
    rock = [k for k in lv1 if o.locations[k].kind == "rock"]
    done = [box[0], box[1], rock[0]]
    for k in done:
        o.fake.set_open(o.save_id(k), 1)
    o.open_map()
    total = len(o.keys())
    n, grey, plus = o.children()
    check(n == total, f"a marker for every location with a position: {n}/{total}")
    check(grey == 3 and plus == total - 3, f"3 grey, the rest coloured: grey {grey}, plus {plus}")
    check("checked=3" in o.status(), f"status counts checked: {o.status()}")
    w = o.widget(box[0])
    check(w.text == "x" and colour(w) == GREY and w.slot.z == 999, "checked box: grey x, under the others")
    w = o.widget(box[2])
    check(w.text == "#" and colour(w) == (1, 0.2, 1, 1) and w.slot.z == 1000, "undone box: magenta #")
    w = o.widget(rock[1])
    check(w.text == "$" and colour(w) == (1, 0.85, 0.2, 1), "undone rock: yellow $")

    # A box opened while the map is open: restyled within the 2 s recheck, same widget.
    w = o.widget(box[2])
    constructed = o.calls("construct")
    o.fake.set_open(o.save_id(box[2]), 1)
    o.run(2100)
    check(w.text == "x" and colour(w) == GREY and not w.removed, "turns grey live, the same widget")
    check(o.calls("construct") == constructed, "no widget created for a state change")
    check(o.children()[1] == 4, "4 grey now")


def pickup_rule(o: Overlay) -> None:
    key = o.keys(kind="pickup")[0]
    o.fake.set_open(o.save_id(key), 1)
    o.fake.add_pickup(key, "Potion_Test")
    o.fake.waiting["Potion_Test"] = 1          # appeared, not picked up
    o.open_map()
    check(o.widget(key).text == "o", "pickup whose drop still waits: still todo (cyan o)")
    o.fake.waiting["Potion_Test"] = 0          # picked up
    o.run(2100)
    check(o.widget(key).text == "x", "picked up: grey")
    other = o.keys(kind="pickup")[1]
    o.fake.set_open(o.save_id(other), 1)       # not loaded: open counts as collected
    o.run(2100)
    check(o.widget(other).text == "x", "pickup in an unloaded room, open: grey")


def live_open(o: Overlay) -> None:
    """A box opened while playing turns grey although the by-save-id value
    still says closed, also after its room unloads (map closed meanwhile)."""
    box = o.keys(kind="box", level="Lv1")[0]
    rock = o.keys(kind="rock", level="Lv1")[0]
    o.fake.add_actor(box, "BP_TreasureBox_High_C")
    o.fake.add_actor(rock, "BP_MoneyStone_C")
    o.run(1100)                                # map closed, both still closed
    o.fake.live[box] = 1                       # opened; the save db still says 0
    o.run(1100)
    o.fake.unload(box)                         # the player leaves the room
    o.open_map()
    check(o.widget(box).text == "x", "box opened live, room since unloaded: grey")
    check(o.widget(rock).text == "$", "rock still closed: todo")
    o.fake.live[rock] = 1                      # broken while the map is open (loaded room)
    o.run(2100)
    check(o.widget(rock).text == "x", "rock broken live with the map open: grey")
    o.fake.map_open = False
    o.run(300)
    o.fake.map_open = True
    o.run(400)
    check(o.widget(box).text == "x", "still grey after closing and reopening the map")


def pawn_switch(o: Overlay) -> None:
    """Getting on or off the flying fish (ClientRestart): the overlay forgets
    its map and widgets without touching them, sits out 3 s, then works again."""
    o.lua.execute('require("transition").start()')
    hook = o.fake.hooks["/Script/Engine.PlayerController:ClientRestart"]
    check(hook is not None, "transition hook registered on ClientRestart")
    o.fake.set_open(o.save_id(o.keys()[0]), 1)
    o.open_map()
    n = o.children()[0]
    before = {k: o.calls(k) for k in ("remove", "SetVisibility", "SetPosition", "construct")}
    hook()
    o.run(2000)
    same = all(o.calls(k) == before[k] for k in before)
    check(n > 0 and same, f"while it settles: no widget or map call at all ({before} -> "
                          f"{ {k: o.calls(k) for k in before} })")
    o.fake.wall += 4
    o.run(400)
    check(o.calls("construct") > before["construct"], "after 3 s: markers placed again on the (new) map")
    check(o.widget(o.keys()[0]).text == "x", "and still grey where done")


def flags(o: Overlay) -> None:
    lv1 = o.keys(level="Lv1")
    for k in lv1[:5]:
        o.fake.set_open(o.save_id(k), 1)
    o.open_map()
    total = len(o.keys())
    check(o.children() == (total, 5, total - 5), "5 grey before the flag")
    grey_widget = o.widget(lv1[0])
    o.write("AfterimageAP_tracker.flag", "nocollected\n")
    o.run(2100)
    check(o.children() == (total - 5, 0, total - 5), f"nocollected: grey markers removed live {o.children()}")
    check(grey_widget.removed, "the grey widget is removed from the panel")
    (o.dir / "AfterimageAP_tracker.flag").unlink()
    o.run(2100)
    check(o.children() == (total, 5, total - 5), "flag gone: grey markers back")
    o.write("AfterimageAP_tracker.flag", "norocks nocollected\n")
    o.run(2100)
    rocks = len(o.keys(kind="rock"))
    rocks_done = sum(1 for k in lv1[:5] if o.locations[k].kind == "rock")
    check(o.children()[0] == total - rocks - (5 - rocks_done), f"norocks + nocollected: {o.children()}")
    o.write("AfterimageAP_tracker.flag", "OFF")
    o.run(2100)
    check(o.children()[0] == 0, "off (any case): standalone tracker shows nothing")


def randomizer(o: Overlay) -> None:
    keys = o.keys(level="Lv1")
    lines = ["AP1\tseed\t3", keys[0], keys[1], f"checked\t{keys[2]}", f"checked\t{keys[3]}",
             "checked\tLD_Nowhere:BP_Unknown_1", "LD_Nowhere:BP_Unknown_2"]
    o.write("AfterimageAP_missing.txt", "\n".join(lines) + "\n")
    o.fake.save["session_seed_3"] = 1          # the bridge marked this save for the seed
    o.fake.set_open(o.save_id(keys[0]), 1)     # the save is ignored with a missing file
    o.open_map()
    check(o.children() == (4, 2, 2), f"2 todo + 2 checked, unknown keys skipped: {o.children()}")
    check(o.widget(keys[0]).text not in ("x", None) and o.widget(keys[2]).text == "x", "states from the file, not the save")
    # The server checks keys[1] (e.g. !collect) while the map is open.
    w = o.widget(keys[1])
    lines[2] = f"checked\t{keys[1]}"
    o.write("AfterimageAP_missing.txt", "\n".join(lines) + "\n")
    o.run(2100)
    check(w.text == "x" and not w.removed, "checked on the server: turns grey live")
    o.write("AfterimageAP_tracker.flag", "nocollected")
    o.run(2100)
    check(o.children() == (1, 0, 1), f"nocollected applies with the randomizer too: {o.children()}")
    # An old client: no checked lines at all.
    (o.dir / "AfterimageAP_tracker.flag").unlink()
    o.write("AfterimageAP_missing.txt", "\n".join(["AP1\tseed\t3", keys[0], keys[1]]) + "\n")
    o.run(2100)
    check(o.children() == (2, 0, 2), f"old client's file: only the missing ones, coloured: {o.children()}")


def leftover_list(o: Overlay) -> None:
    """A list left from another seed (client closed) does not replace a normal
    save's own tracker; a save of that seed, marked or with items, uses it."""
    keys = o.keys(level="Lv1")
    total = len(o.keys())
    o.write("AfterimageAP_missing.txt", "\n".join(["AP1\tother seed\t9", keys[0], keys[1]]) + "\n")
    o.fake.set_open(o.save_id(keys[2]), 1)
    o.open_map()
    check(o.children() == (total, 1, total - 1), f"unmarked save: its own tracker, list ignored: {o.children()}")
    check("list=tracker (list of another seed ignored)" in o.status(), o.status())
    o.fake.save["session_seed_3"] = 1           # marked for a different seed: still ignored
    o.run(2100)
    check(o.children() == (total, 1, total - 1), f"save of another seed: list ignored: {o.children()}")
    o.fake.save["items_other seed_9"] = 4       # a save of this seed from before the mark
    o.run(2100)
    check(o.children() == (2, 0, 2), f"save with this seed's item counter: the list: {o.children()}")
    o.fake.save["items_other seed_9"] = 0
    o.fake.save["session_other seed_9"] = 1     # marked by the bridge
    o.run(2100)
    check(o.children() == (2, 0, 2) and "list=randomizer" in o.status(), f"marked save: the list: {o.status()}")
    o.write("AfterimageAP_missing.txt", "garbage\n" + keys[0] + "\n")
    o.run(2100)
    check(o.children() == (total, 1, total - 1), f"list without a header: ignored: {o.children()}")


def old_mod(o: Overlay) -> None:
    keys = o.keys(level="Lv1")
    lines = ["AP1\tseed\t3", keys[0], f"checked\t{keys[1]}", f"checked\t{keys[2]}"]
    o.write("AfterimageAP_missing.txt", "\n".join(lines) + "\n")
    o.open_map()
    check(o.children() == (1, 0, 1), f"old mod + new client file: checked lines ignored, no error: {o.children()}")


def hiding(o: Overlay) -> None:
    key = o.keys(level="Lv1")[0]
    o.fake.set_open(o.save_id(key), 1)
    o.open_map()
    w = o.widget(key)
    check(w.text == "x" and w.vis == 3, "grey marker shown at the view centre")
    o.fake.map.CurrentZoom = o.fake.map.TargetZoom = 1.0
    o.fake.centre_on(key, 736, 414)
    o.run(40)
    check(w.vis == 1, "zoomed out below 1.18: grey marker hidden")
    check("visible=0" in o.status(), f"nothing visible zoomed out: {o.status()}")
    o.fake.map.CurrentZoom = o.fake.map.TargetZoom = 1.2
    o.fake.centre_on(key, 3, 414)
    o.run(40)
    check(w.vis == 1, "at the panel edge: hidden")
    o.fake.centre_on(key, 1200, 200)
    o.run(40)
    check(w.vis == 1, "under the legend: hidden")
    o.fake.centre_on(key, 1000, 600)
    o.run(40)
    check(w.vis == 3 and abs(w.slot.x - o.fake.panel_of(1000, 600)[0]) < 0.01, "back in view: shown where it belongs")


def zoom_step(o: Overlay) -> None:
    """A / D on the paused map. The game scales MapNamePanel (the markers'
    parent) with the map by the zoom (ScaleBox = TargetZoom), so a marker's
    slot position must not change with the zoom: placing it at offset * zoom
    drew it at offset * zoom^2 (2026-11-19 runs, docs/game-internals.md
    "Map zoom: the panel is scaled"). TargetZoom (not the lagging
    CurrentZoom, 1.2449 for a step to 1.45) decides what is in view."""
    key = o.keys(level="Lv1")[0]
    o.open_map()
    w = o.widget(key)
    o.fake.centre_on(key, 1000, 600)          # 264, 186 window px from the centre at 1.2
    o.run(40)
    sx, sy = o.fake.panel_of(1000, 600)
    check(w.vis == 3 and abs(w.slot.x - sx) < 0.01, f"before zooming: at window 1000, 600 (slot {sx:.1f})")
    o.fake.map.TargetZoom = 1.45
    o.fake.map.CurrentZoom = 1.2449
    o.run(40)
    check(abs(w.slot.x - sx) < 0.01 and abs(w.slot.y - sy) < 0.01,
          f"zoomed to 1.45: slot unchanged, the panel's scale moves it ({w.slot.x:.1f}, {w.slot.y:.1f})")
    # In the window (panel scale 1.45 around the middle) it is where the map
    # puts the location: 264 * 1.45 / 1.2 from the centre.
    screen_x = 736 + (w.slot.x - 736) * 1.45
    check(abs(screen_x - (736 + 264 * 1.45 / 1.2)) < 0.01, f"in the window with the map at 1.45: {screen_x:.1f}")
    check("zoom=1.4500 (CurrentZoom 1.2449)" in o.status(), f"status shows both zooms: {o.status()}")
    # In view at 1.2 but pushed past the window edge by zooming in: hidden.
    o.fake.map.CurrentZoom = o.fake.map.TargetZoom = 1.2
    o.fake.centre_on(key, 1300, 414)          # 564 right of the middle at 1.2
    o.run(40)
    check(w.vis == 3 and abs(w.slot.x - o.fake.panel_of(1300, 414)[0]) < 0.01, "near the right edge at 1.2: shown")
    o.fake.map.TargetZoom = 1.45               # 564 * 1.45 / 1.2 = 681.5 > 730
    o.run(40)
    check(w.vis == 3, "at 1.45 still inside (736 + 681.5)")
    o.fake.map.TargetZoom = 1.75               # 822.5 past the edge
    o.run(40)
    check(w.vis == 1, "at 1.75 past the window edge: hidden")
    # Pan at a zoom other than the default: the slot moves by the pan * 1472 / 1280.
    o.fake.map.TargetZoom = 1.45
    o.fake.centre_on(key, 1000, 600)
    o.run(40)
    before = w.slot.x
    p = o.fake.map.PlayerMinimapComp.PreviewLoc
    o.fake.map.PlayerMinimapComp.PreviewLoc = o.lua.table_from({"X": p.X + 50, "Y": p.Y})
    o.run(40)
    want = before - 50 * 1472 / 1280
    check(abs(w.slot.x - want) < 0.01, f"panned 50 map px at 1.45: slot moved by 57.5 ({w.slot.x:.1f}, want {want:.1f})")
    o.fake.map.TargetZoom = None
    o.fake.map.CurrentZoom = 1.0
    o.run(40)
    check(w.vis == 1, "no TargetZoom: falls back to CurrentZoom (1.0 hides)")


def cost(o: Overlay) -> None:
    for k in o.keys(level="Lv1")[:6]:
        o.fake.set_open(o.save_id(k), 1)
    o.open_map()
    o.fake.centre_on(o.keys(level="Lv1")[0], 736, 414)
    o.run(2100)
    before = {n: o.calls(n) for n in ("SetPosition", "SetVisibility", "SetText", "SetColor", "construct")}
    o.run(33 * 30)                             # a second of open map, view still
    same = all(o.calls(n) == before[n] for n in before)
    check(same, "view unchanged: no widget calls per tick (beyond the 2 s recheck, which changed nothing)")
    o.fake.map.PlayerMinimapComp.PreviewLoc.X += 5
    o.run(33)
    visible = int(o.status().split("visible=")[1].split()[0])
    labels = int(o.status().split("labels=")[1].split()[0])
    moved = o.calls("SetPosition") - before["SetPosition"]
    check(visible > 0 and labels <= 1 and moved == visible + labels,
          f"view moved: SetPosition only for the {visible} visible markers and {labels} focus label ({moved})")
    check(visible < len(o.keys()) / 4, f"visible is a small part of all {len(o.keys())} markers")
    grey_shown = sum(1 for w in o.fake.panel.children.keys() if w.vis == 3 and w.text == "x")
    check(grey_shown > 0, f"grey markers among the visible ones: {grey_shown}")
    check(o.calls("SetText") == before["SetText"], "no restyling on a pan")


def map_closes(o: Overlay) -> None:
    o.fake.set_open(o.save_id(o.keys()[0]), 1)
    o.open_map()
    n = o.children()[0]
    o.fake.map_open = False
    o.run(300)
    check(n > 0 and o.children()[0] == 0, "map closed: all markers removed")
    o.fake.map_open = True
    o.run(400)
    check(o.children()[0] == n and o.children()[1] == 1, "reopened: placed again, grey included")


def show_all(o: Overlay) -> None:
    o.fake.set_open(o.save_id(o.keys()[0]), 1)
    o.open_map()
    check(o.children() == (len(o.keys()), 0, len(o.keys())), "show_all (experiments): every marker coloured")


def experiment(o: Overlay, old_flag: str | None) -> None:
    """Experiment mode "maptracker" (map_probe.tracker_test) against the fakes."""
    if old_flag is not None:
        o.write("AfterimageAP_tracker.flag", old_flag)
    lv1 = o.keys(level="Lv1")
    for k in [k for k in lv1 if o.locations[k].kind == "box"][:7]:
        o.fake.set_open(o.save_id(k), 1)
    o.fake.map_open = True
    o.fake.centre_on(lv1[0], 736, 414)
    o.lua.execute("exp_log = {}; exp_done = false")
    o.lua.execute("""require("map_probe").tracker_test(function(line) exp_log[#exp_log + 1] = line end,
                                                       function() exp_done = true end)""")
    o.run(60000)
    log = list(o.lua.globals().exp_log.values())
    status = {line.split(":")[0]: line for line in log if line.startswith("tracker ") and "markers=" in line}
    shots = [line.split(": ")[1] for line in log if line.startswith("SCREENSHOT:")]
    check(o.lua.globals().exp_done and log[-1] == "PRESS: Escape", "ran to the end, map closed")
    check(shots == ["tracker_open", "tracker_zoom_in", "tracker_nocollected", "tracker_randomizer"], f"screenshots {shots}")
    check("checked=7" in status["tracker open"], f"open: 7 grey: {status['tracker open']}")
    check("checked=0" in status["tracker nocollected"], f"nocollected: none grey: {status['tracker nocollected']}")
    half = len(lv1) // 2
    check(f"markers={len(lv1)} checked={half}" in status["tracker randomizer"],
          f"test missing file, {len(lv1)} keys, {half} grey: {status['tracker randomizer']}")
    counts = {tag: line.split(": ", 1)[1].split(" visible")[0] for tag, line in status.items()}
    check(counts["tracker back to standalone"] == counts["tracker open"],
          f"back to the standalone tracker afterwards: {counts['tracker back to standalone']}")
    flag = o.dir / "AfterimageAP_tracker.flag"
    check((flag.read_text(encoding="utf-8") if flag.exists() else None) == old_flag, f"tracker flag restored ({old_flag!r})")
    check(not (o.dir / "AfterimageAP_missing.txt").exists(), "test missing file removed")


MID = (736, 414)
PANEL_H = 828
PPM = 1472 / 1280
WHITE = (1, 1, 1, 1)
LABEL_GREY = (0.75, 0.75, 0.75, 0.75)


def label_widget(o: Overlay, key: str):
    """The shown label widget next to `key`'s marker (marker slot + 9 px), or None."""
    m = o.fake.shown_at(MID[0], MID[1])
    for w in o.fake.texts().values():
        if m and abs(w.slot.x - (m.slot.x + 9)) < 0.01 and abs(w.slot.y - m.slot.y) < 0.01:
            return w
    return None


def labels(o: Overlay) -> list[str]:
    return list(o.m.labels_shown().values())


def legend(o: Overlay) -> list[str]:
    return list(o.m.legend_shown().values())


def kinds_and_legend(o: Overlay) -> None:
    """Per-kind glyph and colour, the legend (screen-fixed, kinds on the map),
    markers hidden under it, off by default, and the legend / nolegend / norocks words."""
    box, pickup, rock = o.keys(kind="box")[0], o.keys(kind="pickup")[0], o.keys(kind="rock")[0]
    o.fake.set_open(o.save_id(o.keys(kind="box")[1]), 1)
    o.open_map()
    for key, glyph, col, what in [(box, "#", (1, 0.2, 1, 1), "box: magenta #"),
                                  (pickup, "o", (0.2, 0.9, 1, 1), "pickup: cyan o"),
                                  (rock, "$", (1, 0.85, 0.2, 1), "coin rock: yellow $")]:
        w = o.widget(key)
        check(w.text == glyph and colour(w) == col, f"{what} ({w.text} {colour(w)})")
    voyage = [k for k, d in o.locations.items() if d.kind == "voyage"]
    style = o.m.kind_of(voyage[0])
    check(len(voyage) == 8 and style.glyph == "#" and (style.color.G, style.color.B) == (1, 0.55),
          f"Sea of Souls chests: kind voyage, green # ({len(voyage)})")
    check(all(o.positions[k] is None for k in voyage), "Sea of Souls chests have no area-map position (not drawn)")
    check(o.m.kind_of("DROP:208:Quest_RestPotion").glyph == "#", "a key without data: box style")
    check(legend(o) == [] and "legend=0" in o.status(), f"no flag: no legend (off by default) {legend(o)}")
    o.write("AfterimageAP_tracker.flag", "legend")
    o.run(2100)
    check(legend(o) == ["Locations", "#  Treasure box", "o  Pickup", "$  Coin rock", "x  Checked"], f"legend {legend(o)}")
    lines = sorted((w for w in o.fake.texts().values() if w.text in legend(o)), key=lambda w: w.slot.y)
    check(len(lines) == 5 and all(abs(w.scale - 0.6) < 1e-9 for w in lines), "legend lines at scale 0.6 at zoom 1.2")
    lx, ly = o.fake.panel_of(18, PANEL_H - 22)
    check(abs(lines[-1].slot.x - lx) < 0.01 and abs(lines[-1].slot.y - ly) < 0.01,
          f"legend in the window's bottom left ({lines[-1].slot.x:.1f}, {lines[-1].slot.y:.1f} in the panel)")
    # Zoomed in: the panel is scaled by k = 2.4; the legend is not.
    o.fake.map.TargetZoom = 2.4
    o.run(40)
    k = 2.4
    sx = MID[0] + (lines[-1].slot.x - MID[0]) * k
    sy = MID[1] + (lines[-1].slot.y - MID[1]) * k
    check(abs(sx - 18) < 0.01 and abs(sy - (PANEL_H - 22)) < 0.01 and abs(lines[-1].scale - 0.3) < 1e-9,
          f"zoom 2.4: the legend stays put on screen, same size ({sx:.1f}, {sy:.1f}, scale {lines[-1].scale})")
    o.fake.map.TargetZoom = 1.2
    # A marker under the legend is hidden; without "legend" ("nolegend", the old word, too) it shows.
    o.fake.centre_on(box, 60, PANEL_H - 40)
    o.run(40)
    w = None
    mx, my = o.fake.panel_of(60, PANEL_H - 40)
    for c in o.fake.constructed.values():
        if c.text == "#" and c.slot.x is not None and abs(c.slot.x - mx) < 0.01 and abs(c.slot.y - my) < 0.01:
            w = c
    check(w is None or w.vis == 1, "marker under our legend: hidden")
    o.write("AfterimageAP_tracker.flag", "nolegend")
    o.run(2100)
    o.fake.centre_on(box, 60, PANEL_H - 40)
    o.run(40)
    check(legend(o) == [] and o.fake.shown_at(60, PANEL_H - 40) is not None, "nolegend: no legend, marker shown there")
    o.write("AfterimageAP_tracker.flag", "legend norocks")
    o.run(2100)
    check("$  Coin rock" not in legend(o) and len(legend(o)) == 4, f"norocks: no coin rock line {legend(o)}")
    o.fake.map.TargetZoom = 1.0
    o.run(40)
    check(legend(o) == [], "zoomed out to the overview: legend hidden")


def expected_focus(o: Overlay, zoom: float) -> str | None:
    """The marker nearest the view centre within 70 window px, by the test's own maths."""
    p = o.fake.map.PlayerMinimapComp.PreviewLoc
    lines = int(o.status().split("legend=")[1].split()[0])
    legend_top = (PANEL_H - 22) - (lines - 1) * 24 - 24
    best = None
    for key in o.keys():
        x, z = o.positions[key][1], o.positions[key][2]
        px = MID[0] + (x * 0.04 - p.X) * PPM * zoom
        py = MID[1] + (-z * 0.04 - p.Y) * PPM * zoom
        under_ours = lines > 0 and px <= 18 + 240 and py >= legend_top
        if 6 <= px <= 1472 - 6 and 6 <= py <= 828 - 6 and not (px >= 1110 and py <= 390) and not under_ours:
            d2 = (px - MID[0]) ** 2 + (py - MID[1]) ** 2
            if d2 <= 70 ** 2 and (best is None or (d2, key) < best):
                best = (d2, key)
    return best and best[1]


def labels_by_zoom(o: Overlay) -> None:
    """Default zoom: one label, the marker nearest the view centre; zoomed in
    (>= 2.0): every visible marker; zoomed out: none. Constant size on screen."""
    keys = o.keys(level="Lv1")
    key = keys[0]
    done = keys[1]
    o.fake.set_open(o.save_id(done), 1)
    o.open_map()
    o.widget(key)
    check(labels(o) == [f"{key} = {o.locations[key].item}"], f"zoom 1.2, centred on a marker: its item {labels(o)}")
    lw = label_widget(o, key)
    check(lw is not None and abs(lw.scale - 0.6) < 1e-9 and colour(lw) == WHITE and lw.pivot.X == 0,
          "label right of the marker, scale 0.6, white, scaled from its left edge")
    o.widget(done)
    check(labels(o) == [f"{done} = {o.locations[done].item}"] and colour(label_widget(o, done)) == LABEL_GREY,
          "checked marker: its label grey")
    for px in (800, 836, 900, 1000, 790, 810):
        o.fake.centre_on(key, px, 414)
        o.run(40)
        want = expected_focus(o, 1.2)
        got = [line.split(" = ")[0] for line in labels(o)]
        check(got == ([want] if want else []), f"marker {px - 736} px off the centre: label on {want}, got {got}")
    o.fake.map.TargetZoom = 2.4
    o.fake.centre_on(key, 736, 414)
    o.run(40)
    visible = int(o.status().split("visible=")[1].split()[0])
    shown = labels(o)
    check(visible > 1 and 1 < len(shown) <= min(visible, 40), f"zoom 2.4: visible markers labelled ({len(shown)}/{visible})")
    check(shown[0] == f"{key} = {o.locations[key].item}", "nearest the centre first")
    # No two labels overlap (boxes in window px: 11 px a character, 22 high).
    boxes = []
    for w in o.fake.texts().values():
        if w.text in legend(o) or w.slot.x is None:
            continue
        wx, wy = MID[0] + (w.slot.x - MID[0]) * 2.4, MID[1] + (w.slot.y - MID[1]) * 2.4
        boxes.append((wx, wx + len(w.text) * 11, wy - 11, wy + 11))
    clash = [(a, b) for i, a in enumerate(boxes) for b in boxes[i + 1:]
             if a[0] < b[1] and b[0] < a[1] and a[2] < b[3] and b[2] < a[3]]
    check(len(boxes) == len(shown) and not clash, f"zoom 2.4: no overlapping labels ({len(boxes)} labels, {len(clash)} clashes)")
    # Two markers close together: only the nearer one keeps its label.
    near = [k for k in keys if k != key and o.positions[k] is not None]
    kx, kz = o.positions[key][1], o.positions[key][2]
    closest = min(near, key=lambda k: (o.positions[k][1] - kx) ** 2 + (o.positions[k][2] - kz) ** 2)
    d = ((o.positions[closest][1] - kx) ** 2 + (o.positions[closest][2] - kz) ** 2) ** 0.5 * 0.04 * PPM * 2.4
    if d < 20:
        check(not any(line.startswith(closest + " ") for line in shown), f"a marker {d:.0f} px from the centred one: no label")
    lw = label_widget(o, key)
    check(abs(lw.scale - 0.3) < 1e-9, f"zoom 2.4: label scale 0.6 / 2 = 0.3, same size on screen ({lw.scale})")
    o.fake.map.TargetZoom = 1.9
    o.run(40)
    check(len(labels(o)) == 1, "zoom 1.9 (below 2.0): back to the one focus label")
    o.fake.map.TargetZoom = 1.0
    o.run(40)
    check(labels(o) == [] and all(w.vis != 3 for w in o.fake.texts().values()), "zoomed out: no label, nothing shown")
    o.fake.map.TargetZoom = 2.4
    o.write("AfterimageAP_tracker.flag", "nolabels")
    o.run(2100)
    check(labels(o) == [] and "labels=0" in o.status(), "nolabels: no label even zoomed in")
    (o.dir / "AfterimageAP_tracker.flag").unlink()
    o.run(2100)
    check(len(labels(o)) > 1, "flag removed: labels back")


def modes(o: Overlay) -> None:
    """Vanilla tracker vs randomizer: what the labels say and which list is used."""
    keys = o.keys(level="Lv1")
    total = len(o.keys())
    lines = ["AP1\tseed\t3", keys[0], f"{keys[1]}\tRainbow Egg (Alice)", f"checked\t{keys[2]}", f"checked\t{keys[3]}\tFire Feather"]
    o.write("AfterimageAP_missing.txt", "\n".join(lines) + "\n")
    o.fake.save["session_seed_3"] = 1
    o.fake.set_open(o.save_id(keys[4]), 1)
    o.write("AfterimageAP_tracker.flag", "legend")   # the legend is opt-in
    o.open_map()
    check("list=randomizer" in o.status() and "mode=randomizer" in o.status() and o.children() == (4, 2, 2),
          f"randomizer list: {o.status()}")
    o.widget(keys[0])
    check(labels(o) == [f"{keys[0]} = {o.locations[keys[0]].item}"], f"randomizer: the vanilla item, no id {labels(o)}")
    o.widget(keys[1])
    check(labels(o) == [f"{keys[1]} = Rainbow Egg (Alice)"], f"randomizer, scouted item in the list: it {labels(o)}")
    o.widget(keys[3])
    check(labels(o) == [f"{keys[3]} = Fire Feather"] and o.widget(keys[3]).text == "x", "checked line with an item: grey, item label")
    check(legend(o)[0] == "Archipelago", f"legend title {legend(o)}")
    # Vanilla tracker: the list is ignored, the save is tracked, labels name vanilla items.
    o.write("AfterimageAP_tracker.flag", "vanilla legend")
    o.run(2100)
    check("list=vanilla" in o.status() and "mode=vanilla" in o.status(), o.status())
    check(o.children() == (total, 1, total - 1), f"vanilla: every location, the save's state: {o.children()}")
    for key in (keys[0], keys[1]):
        o.widget(key)
        check(labels(o) == [f"{key} = {o.locations[key].item}"], f"vanilla: the vanilla item {labels(o)}")
    w = o.widget(keys[4])
    check(w.text == "x" and colour(w) == GREY and colour(label_widget(o, keys[4])) == LABEL_GREY,
          "vanilla: done location grey x, grey label (greying unchanged)")
    o.fake.set_open(o.save_id(keys[0]), 1)
    o.run(2100)
    check(o.widget(keys[0]).text == "x", "vanilla: opened live, grey")
    check(legend(o)[0] == "Vanilla items", f"legend title {legend(o)}")
    o.write("AfterimageAP_tracker.flag", "vanilla nocollected norocks legend")
    o.run(2100)
    check(o.children()[1] == 0 and "$  Coin rock" not in legend(o), "vanilla with nocollected / norocks")
    (o.dir / "AfterimageAP_tracker.flag").unlink()
    o.run(2100)
    check("mode=randomizer" in o.status() and o.children() == (4, 2, 2), "flag removed: the randomizer list again")
    (o.dir / "AfterimageAP_missing.txt").unlink()
    o.run(2100)
    check("mode=tracker" in o.status(), o.status())
    o.widget(keys[1])
    check(labels(o) == [f"{keys[1]} = {o.locations[keys[1]].item}"],
          "standalone tracker without vanilla: vanilla items too")
    # Never an internal id: an item without an English name, or a scouted id,
    # falls back to the kind's name.
    d = o.locations[keys[1]]
    old_item = d.item
    for bad in ("", "Item_Unknown01", "Quest_RestPotion"):
        d.item = bad
        check(o.m.label_text(keys[1]) == o.m.kind_of(keys[1]).legend, f"item {bad!r}: the kind instead ({o.m.label_text(keys[1])})")
    d.item = old_item
    every = list(o.locations.keys())
    ids = [k for k in every if "_" in o.m.label_text(k) and " " not in o.m.label_text(k)]
    check(len(every) == 876 and not ids, f"no label of the {len(every)} locations is an id ({ids[:3]})")


def names(o: Overlay) -> None:
    """Location names built in Lua match the apworld's; vanilla item texts."""
    import json
    data = json.loads((ROOT / "data" / "locations.json").read_text(encoding="utf-8"))
    by_key = {e["key"]: e for e in data}
    keys = [k for k in o.locations.keys()]
    wrong = [k for k in keys if k in by_key and o.m.location_name(k) != by_key[k]["name"]]
    check(not wrong and len(keys) == 876, f"all {len(keys)} location names as in locations.json ({wrong[:3]})")
    rock = next(k for k in keys if by_key.get(k, {}).get("item") == "Coins_250")
    check(o.locations[rock].item == "250 dews", "coin rock: '250 dews' (the currency)")
    many = next(k for k in keys if by_key.get(k, {}).get("count") == 3)
    check(o.locations[many].item.endswith(" x3"), f"count 3: '{o.locations[many].item}'")
    egg = "LD_Voyage:BP_TreasureBox_Voyage_50302"
    check(o.locations[egg].item == "Rainbow Egg" or "Egg" in o.locations[egg].item, f"Sea of Souls chest item: {o.locations[egg].item}")
    raw = [k for k in keys if o.locations[k].item == by_key.get(k, {}).get("item")]
    check(not raw, f"every item has an English name ({raw[:3]})")


def extras_fail(o: Overlay) -> None:
    """A label / legend widget call failing in the game turns those off, not the markers."""
    o.fake.fail_render_scale = True
    o.write("AfterimageAP_tracker.flag", "legend")   # the legend is opt-in
    key = o.keys(level="Lv1")[0]
    o.open_map()
    w = o.widget(key)
    check(w is not None and w.vis == 3 and o.children()[0] == len(o.keys()), "markers placed and shown")
    check(labels(o) == [] and legend(o) == [] and "labels=0" in o.status(), f"labels and legend off: {o.status()}")
    o.fake.centre_on(key, 1000, 600)
    o.run(40)
    sx, sy = o.fake.panel_of(1000, 600)
    check(w.vis == 3 and abs(w.slot.x - sx) < 0.01 and abs(w.slot.y - sy) < 0.01, "markers still follow the view")


def parse_items(o: Overlay) -> None:
    items = o.lua.table()
    lst = o.m.parse_list("AP1\ts\t1\nA:x\tSword (Bob)\nchecked\tB:y\tShield\nC:z\n", False, items)
    check(lst["A:x"] == "todo" and lst["B:y"] == "checked" and lst["C:z"] == "todo", "lines with an item column")
    check(items["A:x"] == "Sword (Bob)" and items["B:y"] == "Shield" and items["C:z"] is None, "items read")


def experiment_labels(o: Overlay) -> None:
    """Experiment mode "maplabels" (map_probe.labels_test) against the fakes; D / A move TargetZoom."""
    lv1 = o.keys(level="Lv1")
    o.fake.map_open = True
    o.fake.centre_on(lv1[0], 736, 414)
    o.lua.execute("""exp_log = {}; exp_done = false
        exp_logf = function(line)
            exp_log[#exp_log + 1] = line
            if line == "PRESS: D" then fake.map.TargetZoom = fake.map.TargetZoom + 0.3 end
            if line == "PRESS: A" then fake.map.TargetZoom = fake.map.TargetZoom - 0.3 end
            if line == "HOLD: Right 400" then fake.map.PlayerMinimapComp.PreviewLoc.X = fake.map.PlayerMinimapComp.PreviewLoc.X + 100 end
        end""")
    o.lua.execute('require("map_probe").labels_test(exp_logf, function() exp_done = true end)')
    o.run(90000)
    log = list(o.lua.globals().exp_log.values())
    status = {line.split(":")[0]: line for line in log if line.startswith("labels ") and "markers=" in line}
    shots = [line.split(": ")[1] for line in log if line.startswith("SCREENSHOT:")]
    check(o.lua.globals().exp_done and log[-1] == "PRESS: Escape", "ran to the end, map closed")
    check(shots == ["labels_default", "labels_pan", "labels_vanilla", "labels_vanilla_zoom", "labels_default_zoom",
                    "labels_back", "labels_overview"], f"screenshots {shots}")
    check("mode=vanilla" in status["labels vanilla_zoom"] and "zoom=2.4000" in status["labels vanilla_zoom"],
          status["labels vanilla_zoom"])
    n_zoom = int(status["labels vanilla_zoom"].split("labels=")[1].split()[0])
    check(n_zoom > 1, f"zoomed in: many labels ({n_zoom})")
    check("mode=tracker" in status["labels default_zoom"], status["labels default_zoom"])
    check("labels=0" in status["labels overview"] and "legend=0" in status["labels overview"]
          and "visible=0" in status["labels overview"], status["labels overview"])
    check(int(status["labels back"].split("labels=")[1].split()[0]) <= 1 and "zoom=1.2000" in status["labels back"],
          f"back at 1.2: one focus label at most: {status['labels back']}")
    check(any(line.startswith("  label ") for line in log) and "  legend " in log
          and not any(line.startswith("  legend V") for line in log),
          "label lines logged; legend lines empty (the legend is off by default)")
    check(not (o.dir / "AfterimageAP_tracker.flag").exists(), "tracker flag restored (none)")


ICON_PX = 34


def icon_names(o: Overlay) -> dict:
    return o.lua.eval('require("data_icons")')


def icons_vanilla(o: Overlay) -> None:
    """Vanilla mode: each unchecked marker shows its vanilla item's icon, the
    same size on screen at every zoom; checked ones the grey x; labels past
    the icon; the legend says so."""
    o.fake.frames = True
    o.write("AfterimageAP_tracker.flag", "vanilla legend")
    keys = o.keys(level="Lv1")
    box = next(k for k in keys if o.locations[k].kind == "box")
    pickup = next(k for k in keys if o.locations[k].kind == "pickup")
    rock = next(k for k in keys if o.locations[k].kind == "rock")
    done = next(k for k in keys if o.locations[k].kind == "box" and k != box)
    o.fake.set_open(o.save_id(done), 1)
    o.open_map()
    for key in (box, pickup, rock):
        o.fake.centre_on(key, 736, 414)
        o.run(40)
        img = o.fake.icon_at(736, 414)
        glyph = o.fake.shown_at(736, 414)
        want = {"dew": "ST_HUD1_Button_Gold"}.get(o.locations[key].icon, o.locations[key].icon)
        check(img is not None and img.brush == want and glyph is None,
              f"{o.locations[key].kind}: icon {want} instead of the glyph ({img and img.brush}, glyph {glyph and glyph.text})")
    check(o.locations[rock].icon == "dew", "coin rock: the dew (currency) icon")
    o.fake.centre_on(box, 736, 414)
    o.run(40)
    img = o.fake.icon_at(736, 414)
    check(img.slot.w == ICON_PX and abs(img.scale - 1 / 1.2) < 1e-9,
          f"icon {ICON_PX} panel px, render scale 1 / 1.2: {ICON_PX} window px ({img.slot.w}, {img.scale:.4f})")
    lw = next((w for w in o.fake.texts().values() if w.text == o.locations[box].item), None)
    want_x = img.slot.x + (ICON_PX / 2 + 3) / 1.2
    check(lw is not None and abs(lw.slot.x - want_x) < 0.01, f"label right of the icon ({lw and lw.slot.x:.1f}, want {want_x:.1f})")
    o.fake.map.TargetZoom = 2.2
    o.run(40)
    img = o.fake.icon_at(736, 414)
    check(img is not None and abs(img.scale - 1 / 2.2) < 1e-9 and abs(img.slot.w * img.scale * 2.2 - ICON_PX) < 1e-9,
          f"zoom 2.2: render scale 1 / 2.2, still {ICON_PX} window px on screen")
    o.fake.map.TargetZoom = 1.2
    o.fake.centre_on(done, 736, 414)
    o.run(40)
    glyph = o.fake.shown_at(736, 414)
    check(o.fake.icon_at(736, 414) is None and glyph is not None and glyph.text == "x" and colour(glyph) == GREY,
          "checked: the grey x, no icon")
    check(legend(o)[:2] == ["Vanilla items", "Icon  Vanilla item"], f"legend: icon line {legend(o)}")
    st = o.status()
    n_icons = int(st.split("icons=")[1].split()[0])
    visible = int(st.split("visible=")[1].split()[0])
    check(0 < n_icons < visible and o.fake.images()[1] == n_icons, f"status icons={n_icons} of visible={visible} (grey x without)")


def icons_randomizer(o: Overlay) -> None:
    """Randomizer: the scouted item's icon if the list names one (also with a
    player suffix), no icon (the glyph) for another game's item, else the
    vanilla item's icon."""
    o.fake.frames = True
    names = icon_names(o)
    keys = o.keys(level="Lv1")
    some_name = sorted(names.keys())[0]
    lines = ["AP1\tseed\t3", keys[0], f"{keys[1]}\t{some_name}", f"{keys[2]}\tFire Feather (Bob)",
             f"{keys[3]}\t{some_name} (Alice)"]
    o.write("AfterimageAP_missing.txt", "\n".join(lines) + "\n")
    o.fake.save["session_seed_3"] = 1
    o.write("AfterimageAP_tracker.flag", "legend")
    o.open_map()
    check(o.m.icon_frame(keys[0]) == o.locations[keys[0]].icon, "not scouted: the vanilla item's icon")
    check(o.m.icon_frame(keys[1]) == names[some_name], f"scouted {some_name!r}: its icon {names[some_name]}")
    check(o.m.icon_frame(keys[2]) is None, "scouted item of another game: no icon")
    check(o.m.icon_frame(keys[3]) == names[some_name], "scouted with a player suffix: the item's icon")
    for key, has in ((keys[1], True), (keys[2], False)):
        o.fake.centre_on(key, 736, 414)
        o.run(40)
        img, glyph = o.fake.icon_at(736, 414), o.fake.shown_at(736, 414)
        check((img is not None) == has and (glyph is None) == has,
              f"{'icon' if has else 'glyph'} drawn for {key} ({img and img.brush}, {glyph and glyph.text})")
    check(legend(o)[1] == "Icon  Item, else vanilla", f"legend {legend(o)}")
    # The vanilla tracker ignores the scouted items.
    o.write("AfterimageAP_tracker.flag", "vanilla")
    o.run(2100)
    check(o.m.icon_frame(keys[1]) == o.locations[keys[1]].icon, "vanilla mode: the vanilla icon even if scouted")


def icons_missing(o: Overlay) -> None:
    """A frame not loaded: the glyph; nothing loaded at all: glyphs, no icon line."""
    keys = o.keys(level="Lv1")
    box = next(k for k in keys if o.locations[k].kind == "box")
    frames = {d.icon for d in o.locations.values() if d.icon}
    loaded = o.lua.table_from({f: True for f in frames if f != o.locations[box].icon})
    o.fake.frames = loaded
    o.open_map()
    o.fake.centre_on(box, 736, 414)
    o.run(40)
    glyph = o.fake.shown_at(736, 414)
    check(o.fake.icon_at(736, 414) is None and glyph is not None and glyph.text == "#",
          f"frame {o.locations[box].icon} not loaded: the # glyph")
    other = next(k for k in keys if o.locations[k].icon and o.locations[k].icon != o.locations[box].icon
                 and o.locations[k].kind == "pickup")
    o.fake.centre_on(other, 736, 414)
    o.run(40)
    check(o.fake.icon_at(736, 414) is not None, "the other frames: icons")
    finds = o.calls("find_frame")
    for dx in range(10):
        o.fake.centre_on(other, 736 + dx * 3, 414)
        o.run(40)
    check(o.calls("find_frame") == finds, f"frames looked up once per map opening ({finds} lookups, none on a pan)")
    rep = o.m.icon_report()
    check(o.locations[box].icon in rep, f"icon_report names the missing frame: {rep}")


LOADER = """fake.loads = {}
    function LoadAsset(path)
        fake.loads[#fake.loads + 1] = path
        local frame = path:match("/([^/.]+)%.[^/]+$")
        if fake.unloadable and fake.unloadable[frame] then return nil end   -- not in the game's files
        if path:find("/Texture2D/", 1, true) or not path:find("/ItemIcon/", 1, true) then fake.frames[frame] = true end
        return StaticFindObject(path)
    end"""


def icons_loading(o: Overlay) -> None:
    """Frames not loaded: LoadAsset when a marker needing one comes into view
    (the map open: loaded while closed, they were garbage-collected by the
    next level load), each path once per map opening, at most 4 per tick; a
    recolour not to be had falls back to its base frame; a full object path
    is used as is."""
    frames = sorted({d.icon for d in o.locations.values() if d.icon and d.icon != "dew"})
    recolour = next(f for f in frames if f.endswith("_C01"))
    missing = [f for f in frames if f != recolour][:12]
    loaded = {f: True for f in frames if f not in missing and f != recolour}
    loaded[recolour[:-4]] = True                     # only the base of the recolour
    loaded["ST_HUD1_Button_Gold"] = True
    o.fake.frames = o.lua.table_from(loaded)
    o.fake.unloadable = o.lua.table_from({recolour: True})
    o.lua.execute(LOADER)
    o.run(600)
    check(len(list(o.fake.loads.values())) == 0, "map closed: nothing loaded")
    o.open_map()
    key = next(k for k, d in o.locations.items() if d.icon == missing[0] and o.positions[k] is not None)
    o.fake.centre_on(key, 736, 414)
    o.run(40)
    img = o.fake.icon_at(736, 414)
    check(img is not None and img.brush == missing[0], f"{missing[0]} not loaded: loaded on sight and drawn ({img and img.brush})")
    o.lua.execute("fake.loads = {}")
    o.m.icon_report()                                # looks up every framed marker at once
    burst = len(list(o.fake.loads.values()))
    check(burst <= 4, f"at most 4 LoadAsset in one tick ({burst})")
    for _ in range(10):
        o.run(40)
        o.m.icon_report()
    rep = o.m.icon_report()
    check(rep.startswith(f"icons: {len(o.keys())} of {len(o.keys())} "), f"after a few ticks every framed marker has its frame: {rep[:70]}")
    asked = list(o.fake.loads.values())
    check(len(asked) == len(set(asked)), "no path asked twice in one map opening")
    rkey = next(k for k, d in o.locations.items() if d.icon == recolour and o.positions[k] is not None)
    o.fake.centre_on(rkey, 736, 414)
    o.run(40)
    img = o.fake.icon_at(736, 414)
    check(img is not None and img.brush == recolour[:-4], f"recolour {recolour} not to be had: its base frame ({img and img.brush})")
    # A frame given as a full object path is used as is.
    o.locations[rkey].icon = "/Game/Assets/UMG/TextureAtlases/HUD/Frames/ST_Test.ST_Test"
    o.fake.frames["ST_Test"] = True
    o.fake.map_open = False
    o.run(300)
    o.open_map()
    o.fake.centre_on(rkey, 736, 414)
    o.run(40)
    img = o.fake.icon_at(736, 414)
    check(img is not None and img.brush == "ST_Test", "full object path as the frame: drawn")


def icons_gc(o: Overlay) -> None:
    """A frame looked up (cached) but in no brush yet, garbage-collected
    before its marker comes into view: never handed to a brush (the glyph
    this tick), looked up and loaded again next tick. (A frame in a brush
    cannot be collected: the brush references it.)"""
    frames = {d.icon for d in o.locations.values() if d.icon and d.icon != "dew"}
    o.fake.frames = o.lua.table_from({f: True for f in frames} | {"ST_HUD1_Button_Gold": True})
    o.lua.execute(LOADER)
    lv9 = o.keys(level="Lv9")
    key = next(k for k in lv9 if o.locations[k].kind == "box")
    frame = o.locations[key].icon
    o.open_map()
    o.fake.centre_on(o.keys(level="Lv1")[0], 736, 414)
    o.run(40)
    o.m.icon_report()                                # every frame looked up and cached
    o.lua.execute(f'fake.dead = {{ ["{frame}"] = true }}; fake.frames["{frame}"] = nil')
    brushes = o.calls("SetBrush")
    o.fake.centre_on(key, 736, 414)
    o.run(40)
    img = o.fake.icon_at(736, 414)
    check(img is None or img.brush != frame, f"dead frame {frame}: not put in a brush")
    o.lua.execute("fake.dead = {}")
    o.run(40)
    o.fake.centre_on(key, 736, 415)
    o.run(40)
    img = o.fake.icon_at(736, 415)
    loads = [p for p in o.fake.loads.values() if frame in p]
    check(img is not None and img.brush == frame and len(loads) == 1, f"then loaded again and drawn ({len(loads)} LoadAsset)")
    check(o.calls("SetBrush") > brushes, "brushes set")


def icons_noload(o: Overlay) -> None:
    o.write("AfterimageAP_tracker.flag", "noload")
    o.lua.execute(LOADER)
    o.fake.frames = o.lua.table_from({})
    o.open_map()                                     # the flag is read before the first placement
    for k in o.keys(level="Lv1")[:5]:
        o.fake.centre_on(k, 736, 414)
        o.run(40)
    check(len(list(o.fake.loads.values())) == 0 and o.fake.images()[1] == 0, "noload: no LoadAsset, glyphs")


def icons_none_loaded(o: Overlay) -> None:
    o.write("AfterimageAP_tracker.flag", "legend")
    o.open_map()
    check(o.fake.images() == (0, 0) and legend(o) and "Icon  Vanilla item" not in legend(o) and o.children()[2] > 0,
          f"no frame loaded: glyphs only, no Image made, no icon line ({legend(o)})")


def icons_pool(o: Overlay) -> None:
    """A pool of Images: none made on a still view or a pan within the area,
    brushes set only when an Image changes frame, one SetPosition per icon."""
    o.fake.frames = True
    o.write("AfterimageAP_tracker.flag", "vanilla")
    key = o.keys(level="Lv1")[0]
    o.open_map()
    o.fake.centre_on(key, 736, 414)
    o.run(2100)
    made = o.calls("construct_image")
    n_icons = int(o.status().split("icons=")[1].split()[0])
    check(made == n_icons and n_icons > 0, f"Images made = icons on screen ({made}, {n_icons})")
    before = {n: o.calls(n) for n in ("construct", "SetBrush", "SetPosition", "SetVisibility", "SetRenderScale")}
    o.run(33 * 30)
    check(all(o.calls(n) == before[n] for n in before), "view still: no widget calls per tick")
    o.fake.map.PlayerMinimapComp.PreviewLoc.X += 3
    o.run(33)
    st = o.status()
    visible, labels_n = int(st.split("visible=")[1].split()[0]), int(st.split("labels=")[1].split()[0])
    moved = o.calls("SetPosition") - before["SetPosition"]
    check(moved == visible + labels_n and o.calls("SetBrush") == before["SetBrush"]
          and o.calls("construct") == before["construct"],
          f"small pan: one SetPosition per visible marker or icon ({moved} = {visible} + {labels_n}), no brush, no widget made")
    # Pan around Lv1 and back: the pool grows to the most icons ever on screen, no more.
    peak = made
    p = o.fake.map.PlayerMinimapComp.PreviewLoc
    x0 = p.X
    for step in range(40):
        p.X = x0 + step * 25
        o.run(33)
        peak = max(peak, int(o.status().split("icons=")[1].split()[0]))
    for step in range(40):
        p.X = x0 + (39 - step) * 25
        o.run(33)
    pool = int(o.status().split("pool=")[1].split()[0])
    check(o.calls("construct_image") == pool and pool <= peak,
          f"after 80 pans: {pool} Images made, the peak on screen was {peak}")
    shown = o.fake.images()[1]
    check(shown == int(o.status().split("icons=")[1].split()[0]), f"only the icons in view are shown ({shown})")
    # Opened live: the icon goes back to the pool, the grey x shows.
    o.fake.centre_on(key, 736, 414)
    o.run(40)
    o.fake.set_open(o.save_id(key), 1)
    o.run(2100)
    glyph = o.fake.shown_at(736, 414)
    check(o.fake.icon_at(736, 414) is None and glyph is not None and glyph.text == "x", "checked while open: icon gone, grey x")
    o.fake.map_open = False
    o.run(300)
    check(o.fake.images() == (0, 0), "map closed: Images removed")


def icons_toggle(o: Overlay) -> None:
    """noicons: glyphs; removed: icons again from the same pool."""
    o.fake.frames = True
    key = o.keys(level="Lv1")[0]
    o.open_map()
    o.fake.centre_on(key, 736, 414)
    o.run(40)
    made = o.calls("construct_image")
    check(o.fake.icon_at(736, 414) is not None, "icons on by default")
    o.write("AfterimageAP_tracker.flag", "noicons legend")
    o.run(2100)
    glyph = o.fake.shown_at(736, 414)
    check(o.fake.images()[1] == 0 and glyph is not None and glyph.text in "#o$",
          f"noicons: no icon shown, the glyph ({glyph and glyph.text})")
    check(legend(o) and "Icon  Vanilla item" not in legend(o) and "(icons off)" in o.status(), f"noicons: legend {legend(o)}")
    (o.dir / "AfterimageAP_tracker.flag").unlink()
    o.run(2100)
    check(o.fake.icon_at(736, 414) is not None and o.calls("construct_image") == made,
          "flag removed: icons back, no new Images")


def icons_fail(o: Overlay) -> None:
    """A failing brush call: logged once, glyphs for the game run."""
    o.fake.frames = True
    o.fake.fail_brush = True
    o.write("AfterimageAP_tracker.flag", "legend")
    key = o.keys(level="Lv1")[0]
    o.open_map()
    o.fake.centre_on(key, 736, 414)
    o.run(40)
    for dx in range(5):
        o.fake.centre_on(key, 736 + dx * 30, 414)
        o.run(40)
    o.fake.centre_on(key, 736, 414)
    o.run(2100)
    printed = [s for s in o.fake.printed.values() if "item icons off" in s]
    glyph = o.fake.shown_at(736, 414)
    check(len(printed) == 1, f"logged once: {printed}")
    check(glyph is not None and o.fake.images()[1] == 0 and "(icons failed)" in o.status(),
          f"glyphs shown, no icon: {o.status()[:80]}")
    check(legend(o) and "Icon  Vanilla item" not in legend(o), "legend without the icon line")
    o.fake.fail_brush = False
    o.fake.map_open = False
    o.run(300)
    o.open_map()
    o.fake.centre_on(key, 736, 414)
    o.run(40)
    check(o.fake.images()[1] == 0, "still glyphs after reopening the map (off for the game run)")


def experiment_icons(o: Overlay) -> None:
    """Experiment mode "mapitemicons" (map_probe.item_icons_test) against the fakes."""
    o.fake.frames = True
    lv1 = o.keys(level="Lv1")
    for k in lv1[:40]:
        o.fake.set_open(o.save_id(k), 1)
    o.fake.map_open = True
    o.fake.centre_on(lv1[0], 736, 414)
    o.lua.execute("""exp_log = {}; exp_done = false
        exp_logf = function(line)
            exp_log[#exp_log + 1] = line
            if line == "PRESS: D" then fake.map.TargetZoom = fake.map.TargetZoom + 0.25 end
            if line == "PRESS: A" then fake.map.TargetZoom = fake.map.TargetZoom - 0.25 end
            if line:find("^HOLD: Right") then fake.map.PlayerMinimapComp.PreviewLoc.X = fake.map.PlayerMinimapComp.PreviewLoc.X + 100 end
            if line:find("^HOLD: Left") then fake.map.PlayerMinimapComp.PreviewLoc.X = fake.map.PlayerMinimapComp.PreviewLoc.X - 150 end
        end""")
    o.lua.execute('require("map_probe").item_icons_test(exp_logf, function() exp_done = true end)')
    o.run(120000)
    log = list(o.lua.globals().exp_log.values())
    status = {line.split(":")[0]: line for line in log if line.startswith("icons ") and "markers=" in line}
    shots = [line.split(": ")[1] for line in log if line.startswith("SCREENSHOT:")]
    check(o.lua.globals().exp_done and log[-1] == "PRESS: Escape", "ran to the end, map closed")
    check(shots == ["icons_default", "icons_candidates", "icons_dense", "icons_dense_a", "icons_dense_a_glyphs", "icons_dense_b",
                    "icons_dense_b_glyphs", "icons_dense_b_zoom", "icons_dense_b_zoom_glyphs", "icons_zoom_pan",
                    "icons_back"], f"screenshots {shots}")
    n = lambda tag, field: int(status["icons " + tag].split(field + "=")[1].split()[0])
    check(n("dense", "icons") > n("default", "icons") and n("dense", "checked") == 0, "dense list: every location, more icons")
    check(n("dense_a_glyphs", "icons") == 0 and "(icons off)" in status["icons dense_a_glyphs"], "noicons step: glyphs")
    check(n("dense_b", "icons") > 0 and "(icons off)" not in status["icons dense_b"], "icons back on after the glyph shot")
    check(n("dense_b_zoom", "icons") > 0 and "zoom=2.2000" in status["icons dense_b_zoom"], status["icons dense_b_zoom"])
    check(any(line.startswith("  world delta during the pan") for line in log) and any("perf ticks=" in l for l in log),
          "timing lines logged")
    check(not (o.dir / "AfterimageAP_tracker.flag").exists() and not (o.dir / "AfterimageAP_missing.txt").exists(),
          "flag and list restored (none)")
    check(not [l for l in log if " step " in l and "failed" in l], "no step failed")


def old_source() -> str | None:
    return OLD_OVERLAY.read_text(encoding="utf-8") if OLD_OVERLAY.exists() else None


def standalone_main(mods_txt: str | None, enabled_txt: bool, flag: str | None, expect_drawn: bool, what: str) -> None:
    """AfterimageMapTracker/Scripts/main.lua in a game folder: the overlay
    reads AfterimageMapTracker.flag, and stays off while the randomizer's
    AfterimageAP mod is enabled (unless the word "both")."""
    print(f"--- standalone main.lua: {what}")
    with tempfile.TemporaryDirectory() as tmp:
        old = os.getcwd()
        os.chdir(tmp)
        try:
            mods = Path(tmp) / "ue4ss" / "Mods"
            (mods / "AfterimageAP").mkdir(parents=True)
            if mods_txt is not None:
                (mods / "mods.txt").write_text(mods_txt, encoding="utf-8")
            if enabled_txt:
                (mods / "AfterimageAP" / "enabled.txt").write_text("", encoding="utf-8")
            if flag is not None:
                Path(tmp, "AfterimageMapTracker.flag").write_text(flag, encoding="utf-8")
            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.execute(f"package.path = [[{SCRIPTS.as_posix()}/?.lua;]] .. package.path")
            lua.execute(FAKE_UE4SS)
            fake = lua.globals().fake
            lua.execute((SCRIPTS / "main.lua").read_text(encoding="utf-8"))
            printed = "".join(fake.printed.values())
            hooked = fake.hooks["/Script/Engine.PlayerController:ClientRestart"] is not None
            fake.map_open = True
            fake.run(400)
            n = fake.children()[0]
            if expect_drawn:
                m = lua.eval('package.loaded["map_overlay"]')
                locations = lua.eval('require("data_locations")')
                positions = lua.eval('require("data_positions")')
                total = sum(1 for k in locations.keys() if positions[k] is not None)
                rocks = sum(1 for k, d in locations.items() if d.kind == "rock" and positions[k] is not None)
                check(hooked and "[AfterimageMapTracker] loaded." in printed, f"started, transition hook set: {printed!r}")
                check(n > 0 and "mode=tracker" in m.status(), f"markers drawn ({n}), standalone tracker: {m.status()}")
                if flag and "norocks" in flag:
                    check(rocks > 0 and n == total - rocks,
                          f"AfterimageMapTracker.flag read: norocks hides the {rocks} coin rocks ({n} of {total})")
                else:
                    check(n == total, f"every location with a position drawn ({n} of {total})")
            else:
                check(n == 0 and not hooked and "not drawing a second one" in printed,
                      f"randomizer mod enabled: nothing drawn, said why: {printed!r}")
        finally:
            os.chdir(old)


for name, test in [("parse_list", parse), ("standalone tracker", standalone), ("pickup rule", pickup_rule),
                   ("opened while playing", live_open), ("pawn switch (flying fish)", pawn_switch),
                   ("flag words", flags), ("randomizer file", randomizer),
                   ("leftover list of another seed", leftover_list), ("hiding", hiding),
                   ("zoom step (panel scaled by the game)", zoom_step), ("widget calls per tick", cost), ("map closes", map_closes),
                   ("kind markers and legend", kinds_and_legend), ("labels by zoom", labels_by_zoom),
                   ("vanilla tracker vs randomizer", modes), ("location names and vanilla items", names),
                   ("parse_list with items", parse_items), ("labels / legend failing in the game", extras_fail),
                   ("experiment maplabels", experiment_labels),
                   ("item icons, vanilla", icons_vanilla), ("item icons, randomizer", icons_randomizer),
                   ("item icons, a frame not loaded", icons_missing), ("item icons, none loaded", icons_none_loaded),
                   ("item icons, loading missing frames", icons_loading), ("item icons, noload", icons_noload), ("item icons, frame collected", icons_gc),
                   ("item icons, pool reuse", icons_pool), ("item icons, noicons", icons_toggle),
                   ("item icons failing in the game", icons_fail), ("experiment mapitemicons", experiment_icons)]:
    run(name, test)
run("show_all", show_all, show_all=True)
run("experiment maptracker, no flag", lambda o: experiment(o, None))
run("experiment maptracker, flag norocks", lambda o: experiment(o, "norocks\n"))
standalone_main(None, False, None, True, "no randomizer mod")
standalone_main(None, False, "norocks\n", True, "flag file AfterimageMapTracker.flag")
standalone_main("AfterimageAP : 0\nBPModLoaderMod : 1\n", False, None, True, "randomizer mod listed but disabled")
standalone_main("AfterimageAP : 1\n", False, None, False, "randomizer mod enabled in mods.txt")
standalone_main(None, True, None, False, "randomizer mod enabled by enabled.txt")
standalone_main("AfterimageAP : 1\n", False, "both\nnorocks\n", True, "randomizer mod enabled, word both")
old = old_source()
if old:
    run(f"old mod ({OLD_OVERLAY_REV}) reading a new file", old_mod, source=old)
else:
    print(f"--- old mod: skipped ({OLD_OVERLAY} missing)")

print("FAILED" if check.failed else "all passed")
sys.exit(1 if check.failed else 0)

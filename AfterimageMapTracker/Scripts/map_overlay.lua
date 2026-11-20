-- In-game map overlay: a marker on every location, its shape and colour
-- telling the kind while it is still to check, a dim grey "x" once it is
-- checked; a small legend, and labels saying what each location is.
--
-- Markers (TextBlock glyphs; the game's map draws no box / pickup icons we
-- could reuse, see docs/game-internals.md "Map overlay: kinds and labels"):
--   # magenta  treasure box          o cyan    pickup on the ground
--   $ yellow   coin rock             ! orange  boss drop (no position yet)
--   # green    Sea of Souls chest (not on the area map)
--   ? white    quest / script grant (no position yet)
-- Labels: at the default zoom, only the marker nearest the view centre (pan
-- onto a marker to read it); from LABEL_ALL_ZOOM on, every visible one.
-- A label says what the item is, never an internal id: the item placed
-- there if the randomizer's list carries it (a scouted item,
-- "<key><TAB><item>"; the client does not write that yet), else the item the
-- location holds in the unrandomized game, by its English name ("Dim Balm",
-- "250 coins"), else the kind ("Treasure box"). The vanilla tracker (flag
-- word "vanilla") never reads the randomizer's list: it tracks the save,
-- connected or not, and labels vanilla items.
--
-- Which locations:
--   * Randomizer: AfterimageAP_missing.txt, written by the Python client
--     (apworld/afterimage/client.py) while connected: line 1
--     "AP1 <seed> <slot>", then one line per location: "<key>" still to
--     check, "checked<TAB><key>" checked. (Older clients write only the
--     first kind; older mods find no position for the second and skip it.)
--     The list is used only on a save played with its seed and slot (the
--     bridge marks the save, bridge.lua mark_save; older saves of that seed
--     have its delivered-item counter): a list left over from an earlier
--     seed does not hide a normal save's own tracker.
--   * Otherwise, standalone tracker: every box, placed pickup and coin rock,
--     done or not as the save says, read by save id (works for rooms that
--     are not loaded; docs/game-internals.md, "Standalone map tracker").
-- AfterimageAP_tracker.flag next to the game exe (optional), words:
--   "off" turns the standalone tracker off, "norocks" hides its coin rocks,
--   "nocollected" hides checked locations (both modes; the old behaviour),
--   "vanilla" the vanilla tracker mode (above), "nolabels" no labels,
--   "legend" shows the legend (off by default; "nolegend" is accepted and
--   changes nothing), "noicons" glyphs instead of item icons (ICON_PX
--   below), "plaincollected" a checked location shows only the grey "x"
--   (no dimmed icon under it). The launcher's Map tracker tab writes it. M.start's
--   opts.flag_files names other flag files (the first one that exists is
--   read; the standalone AfterimageMapTracker mod reads its own first).
-- Item icons (default): each unchecked marker shows its item's inventory
-- icon (the vanilla item; in randomizer mode the scouted one if the list
-- names it), the glyph only where no icon is loaded. A checked marker keeps
-- its icon, dimmed and grey (CHECKED_ICON_COLOR), under the grey "x".
-- Locations without a known world position (boss drops) are not shown.
--
-- Transform (docs/game-internals.md, "Map overlay transform"): the map is a
-- MAP_SCALE copy of the world, screen y against world Z. The map component's
-- PreviewLoc is the view centre in map px, (world_x, -world_z) * MAP_SCALE,
-- and MapNamePanel (PANEL_W x PANEL_H) shows it in its middle. The map is
-- drawn at TargetZoom (map_zoom below: not CurrentZoom, which lags), and the
-- game scales MapNamePanel with it (PANEL_ZOOM), so markers are placed at
-- the default zoom inside the panel; TargetZoom decides what is in view.
-- Markers are TextBlocks in MapNamePanel, so they draw over the map.

local MAP_SCALE = 0.04
local PANEL_W, PANEL_H = 1472, 828
local EDGE = 6                 -- hide markers this close to the panel edge
-- The legend (Confluence ... Completion) is drawn under the markers, in the
-- panel's top right: hide markers there (panel px, from screenshots).
local LEGEND_X, LEGEND_Y = 1110, 390
-- Zoomed out further than this, markers crowd together: hide them all. The
-- game switches to its area-name overview just below the default zoom 1.2
-- (names shown at 1.156, not at 1.2), so markers show only at the default
-- zoom and closer. The labels' visibility / opacity do not change with it,
-- so the switch cannot be read from them.
local HIDE_BELOW_ZOOM = 1.18
-- MapNamePanel (where the markers live) is scaled by the game together with
-- the map, around the panel's middle, gliding over ~0.3 s after a zoom key.
-- So inside the panel a marker sits at a fixed offset from the middle,
-- (map px - view centre) * PANEL_PER_MAP, whatever the zoom; the panel's
-- scale does the rest and markers glide with the map. Placing them at
-- offset * zoom scaled them twice (docs/game-internals.md "Map zoom: the
-- panel is scaled").
-- Measured in game on 2026-11-19 (mode maplabels, docs "Map overlay: kinds
-- and labels"): the scale is not zoom / 1.2 but the zoom itself
-- (ScaleBox_ScrollingBox.UserSpecifiedScale = TargetZoom, 1.2 at the default
-- zoom), around the panel's middle, into the map window (PANEL_W x PANEL_H
-- design px, 4/3 screen px each at 2560 x 1440). And the map's render target
-- (1280 px wide) is stretched over PANEL_W: one map px is PANEL_W / 1280
-- (1.15) panel px, not 1.2 (markers 4 % off, 33 screen px at the window
-- edge, before). So, with W = window px (what is on screen):
--   panel = mid + (map - centre) * PANEL_PER_MAP
--   W     = mid + (panel - mid) * zoom
local PANEL_PER_MAP = PANEL_W / 1280
local MISSING_FILE = "AfterimageAP_missing.txt"
local CLOSED_POLL_MS = 250
local OPEN_TICK_MS = 33
local FILE_RECHECK_MS = 2000
local VISIBLE = 3              -- ESlateVisibility.HitTestInvisible
local COLLAPSED = 1
-- Per kind: the marker glyph and colour, the word in the Archipelago
-- location name ("<room> - <word> <save id>") and the legend text. ASCII
-- glyphs only: the TextBlock's default font has them for sure.
local KIND = {
    box = { glyph = "#", color = { R = 1, G = 0.2, B = 1, A = 1 }, word = "Treasure Box", legend = "Treasure box" },
    pickup = { glyph = "o", color = { R = 0.2, G = 0.9, B = 1, A = 1 }, word = "Pickup", legend = "Pickup" },
    rock = { glyph = "$", color = { R = 1, G = 0.85, B = 0.2, A = 1 }, word = "Coin Rock", legend = "Coin rock" },
    boss = { glyph = "!", color = { R = 1, G = 0.45, B = 0.15, A = 1 }, word = "Drop", legend = "Boss drop" },
    voyage = { glyph = "#", color = { R = 0.3, G = 1, B = 0.55, A = 1 }, word = "Treasure Box", legend = "Sea of Souls chest" },
    quest = { glyph = "?", color = { R = 1, G = 1, B = 1, A = 1 }, word = "Quest", legend = "Quest reward" },
}
local KIND_ORDER = { "box", "pickup", "rock", "boss", "voyage", "quest" }
local UNKNOWN_KIND = "box"     -- a listed key without kind data
-- Checked locations: dim and grey, drawn under the coloured ones.
local CHECKED_TEXT = "x"
local CHECKED_COLOR = { R = 0.6, G = 0.6, B = 0.6, A = 0.5 }
local TODO_Z, CHECKED_Z = 1000, 999
-- Labels (TextBlocks next to a marker). Zoomed in to LABEL_ALL_ZOOM or more,
-- every visible marker has one (the nearest MAX_LABELS to the view centre);
-- below it, only the marker nearest the view centre, if within FOCUS_RADIUS
-- (window px). The panel's zoom scale is undone on labels and the legend
-- (render scale / zoom), so their text stays one size on screen; markers
-- grow with the map as before. Zoomed in, a label that would overlap one
-- nearer the view centre is left out (its size estimated from LABEL_CHAR_W
-- and LABEL_LINE_H, window px, measured on the 2026-11-19 screenshots).
local LABEL_ALL_ZOOM = 2.0
local FOCUS_RADIUS = 70
local MAX_LABELS = 40
local LABEL_DX = 9             -- label's left edge right of the marker (panel px)
local LABEL_SCALE = 0.72       -- render scale at zoom 1 (0.6 at the default 1.2)
local LABEL_CHAR_W, LABEL_LINE_H = 11, 22
local LABEL_COLOR = { R = 1, G = 1, B = 1, A = 1 }
local LABEL_CHECKED_COLOR = { R = 0.75, G = 0.75, B = 0.75, A = 0.75 }
local LABEL_Z = 1001
-- The legend: one line per kind on the map (glyph + name, in its colour),
-- a line for checked ones and a title line saying the mode, in the panel's
-- bottom left (screen-fixed: window px). Markers are hidden under it, like
-- under the game's own legend.
local LEGEND_SX, LEGEND_BOTTOM, LEGEND_DY = 18, PANEL_H - 22, 24
local LEGEND_W = 270
local LEGEND_SCALE = 0.72
local LEGEND_TITLE_COLOR = { R = 0.9, G = 0.9, B = 0.9, A = 0.9 }
local MODE_TITLE = { vanilla = "Vanilla items", randomizer = "Archipelago", tracker = "Locations" }
-- Item icons (default on; flag word "noicons" turns them off): an unchecked
-- marker shows the inventory icon of its item instead of the glyph: the
-- vanilla item (data_locations.lua `icon`, from the item table's
-- UI_icon_path: data/item_icons.tsv), in randomizer mode the scouted item
-- when the list names it (data_icons.lua: English name -> frame; another
-- game's item has none and keeps the glyph). A checked one keeps its icon,
-- tinted grey and mostly transparent (CHECKED_ICON_COLOR; full colour icons
-- on every done location crowded the map), drawn under its grey "x" and
-- under the unchecked markers; "plaincollected" drops it (the grey "x" only). The icons are UMG Images
-- with an atlas frame brush (SetBrushResourceObject, tried in game with
-- mapicons, 2026-11-19), a pool reused as the view moves: an Image is made
-- only when more are on screen than ever before during this map opening.
-- Their render scale undoes the panel's zoom (like the labels), so they keep
-- ICON_PX window px at every zoom (user's choice: icons do not grow when
-- zooming in). A frame not loaded (StaticFindObject finds only loaded
-- objects; nothing is loaded here) keeps the glyph. Any failing call turns
-- icons off for the game run (logged once), glyphs again.
-- 28 (the first in-game run) drew the art ~25 screen px (the frames have a
-- transparent margin): readable but small; 34 draws it ~31.
local ICON_PX = 34             -- window px (45 screen px at 2560 x 1440)
local ICON_Z = 1000
local CHECKED_ICON_Z = 998     -- under the checked "x" (CHECKED_Z) and every unchecked marker
local ICON_COLOR = { R = 1, G = 1, B = 1, A = 1 }
local CHECKED_ICON_COLOR = { R = 0.55, G = 0.55, B = 0.55, A = 0.4 }
local tint_failed = false      -- an Image tint call failed: checked markers go back to the "x" only
local ICON_LABEL_GAP = 3       -- window px between an icon's right edge and its label
local ICON_DIRS = { "/Game/Assets/Texture2D/ItemIcon/Frames/", "/Game/Assets/UMG/TextureAtlases/ItemIcon/Frames/" }
-- Frames outside the item icon atlases, by the short name data_locations.lua
-- uses: "dew", the currency (the HUD's dew counter icon, a blue drop; coin
-- rocks and coin bundles), found with mode mapitemicons on 2026-11-20.
local NAMED_FRAMES = { dew = "/Game/Assets/UMG/TextureAtlases/HUD/Frames/ST_HUD1_Button_Gold.ST_HUD1_Button_Gold" }
local ICON_LEGEND = { vanilla = "Icon  Vanilla item", tracker = "Icon  Vanilla item",
    randomizer = "Icon  Item, else vanilla" }
local ICON_LEGEND_COLOR = { R = 1, G = 1, B = 1, A = 0.9 }
local CHECKED_PREFIX = "checked\t"   -- a checked line in the missing file
local TRACKER_FLAG = "AfterimageAP_tracker.flag"
local flag_files = { TRACKER_FLAG }   -- read in order, the first that exists (M.start opts.flag_files)
local LOG = "[AfterimageAP] "         -- printed before every log line (M.start opts.log_prefix)
local PROP_OPEN = 11            -- prop_status_object_open
local PROP_DROP_RECORD = 102    -- prop_item_drop_record (table: item id -> 1 while the drop waits)
local PROP_DLG_SAVE_DATA = 29   -- player: dialog id -> { variable -> number } (bridge.lua)
local COUNTER_TABLE = "AfterimageAP"

local transition = require("transition")
local positions = require("data_positions")
local locations = require("data_locations")   -- key -> { id = save id, kind, level, room, item, icon }
local icon_names = (function()
    -- English item name -> icon frame (written this way so build_release.py sees the require)
    local ok, t = pcall(function() return require("data_icons") end)
    return ok and type(t) == "table" and t or {}
end)()

local M = {}

local show_all = false
local running = false
local map = nil                -- open Minimap_C
local panel = nil              -- its MapNamePanel
local markers = {}             -- key -> { widget, slot, mx, my, state, shown, label } (mx, my: map px)
local labels = {}              -- pool of label widgets: { widget, slot, key, text, checked, scale, shown }
local legend = {}              -- legend lines: { widget, slot, text, scale, shown }
local wanted = nil             -- key -> "todo" / "checked", the locations to show
local scouted = {}             -- key -> item name, when the randomizer's list carries it
local wanted_text = nil        -- what wanted was built from (list text + flag words)
local options = { mode = "tracker", labels = true, legend = false, icons = true, checked_icons = true }
local free_icons = {}          -- pool of icon Images not in use: { widget, slot, frame, scale, shown }
local iconed = {}              -- marker -> true, the markers showing an icon (m.img)
local icon_pool = 0            -- Images made during this map opening
local frame_cache = {}         -- frame name -> loaded object, or false (looked up once per map opening)
local icons_failed = false     -- an icon call failed: glyphs for the rest of the game run
local last_view = nil
local last_file_check = 0
local elapsed = 0
local stats = { placed = 0, checked = 0, visible = 0, labels = 0, icons = 0, cx = 0, cy = 0, zoom = 0, source = "-", list = "-" }
local accepted = {}            -- sessions shown without a save check (M.accept_session, experiments)

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then
        return value
    end
    return nil
end

local function find_open_map()
    for _, w in ipairs(FindAllOf("Minimap_C") or {}) do
        if safe(function() return w:IsValid() and w:IsInViewport() end) then
            return w
        end
    end
    return nil
end

---------------------------------------------------------------- standalone tracker

local lib = nil
-- key -> true (done) / false, read from the actor itself in a loaded room.
-- The by-save-id value lags behind a box opened live (it did not turn grey
-- while playing, 2026-11-18), so the live state is read every LIVE_MS, also
-- while the map is closed, and "done" is remembered for the game run (until
-- the room is seen again). Pickups: done = open and the item no longer
-- waiting in the drop record (the bridge's "collected" rule).
local seen = {}
local LIVE_MS = 1000
local last_live = nil

local function refresh_loaded()
    for _, c in ipairs(FindAllOf("SPropComponent") or {}) do
        pcall(function()
            if not c:IsValid() then
                return
            end
            local owner = c:GetOwner()
            local level, name = owner:GetFullName():match("([%w_%-]+):PersistentLevel%.(.+)$")
            local key = level and (level .. ":" .. name)
            local d = key and locations[key]
            if not d then
                return
            end
            local open = c:GetSPropertyNumberValue(PROP_OPEN) == 1
            if d.kind == "pickup" then
                local item = owner.ConstItemID:ToString()
                local waiting = item ~= "" and c:GetSPropTableNumberValue(PROP_DROP_RECORD, { item }) or 0
                seen[key] = open and waiting == 0
            else
                seen[key] = open
            end
        end)
    end
end

-- The words in the tracker flag file, as a set.
local function read_flag()
    local f = nil
    for _, name in ipairs(flag_files) do
        f = io.open(name, "r")
        if f then
            break
        end
    end
    local text = f and f:read("a") or ""
    if f then f:close() end
    local words = {}
    for word in text:gmatch("%S+") do
        words[word:lower()] = true
    end
    return words
end

-- Every location, in the missing file's shape (checked ones with the
-- "checked" prefix), or nil when the tracker is off.
local function tracker_text(words)
    if words.off then
        return nil
    end
    local no_rocks = words.norocks
    lib = lib or StaticFindObject("/Script/SPropertySystem.Default__SPropertyBlueprintLib")
    if not lib or not lib:IsValid() then
        return nil
    end
    refresh_loaded()
    last_live = elapsed
    local keys = {}
    for key, d in pairs(locations) do
        if positions[key] and not (no_rocks and d.kind == "rock") then
            local open = safe(function() return lib:GetNumberValueBySaveID(d.id, PROP_OPEN) end)
            local done = open == 1
            if seen[key] then
                done = true                   -- seen done in a loaded room (live)
            elseif seen[key] == false and d.kind == "pickup" then
                done = false                  -- its drop is still waiting
            end
            keys[#keys + 1] = done and (CHECKED_PREFIX .. key) or key
        end
    end
    table.sort(keys)
    return "TRACKER\n" .. table.concat(keys, "\n")
end

-- key -> "todo" / "checked" from a list in the missing file's shape (line 1
-- a header). Checked lines are left out with hide_checked. A line may carry
-- the item placed there after a tab ("<key><TAB><item>", "checked<TAB><key>
-- <TAB><item>"; scouted by the client): it goes into items (key -> item),
-- when given.
local function parse_list(text, hide_checked, items)
    local list = {}
    local first = true
    for line in (text or ""):gmatch("[^\r\n]+") do
        if first then
            first = false  -- header
        else
            local checked = line:sub(1, #CHECKED_PREFIX) == CHECKED_PREFIX
            if checked then
                line = line:sub(#CHECKED_PREFIX + 1)
            end
            local key, item = line:match("^([^\t]*)\t(.+)$")
            key = key or line
            if item and items and item ~= "" then
                items[key] = item
            end
            if not checked then
                list[key] = "todo"   -- listed as missing wins over checked
            elseif not hide_checked and list[key] == nil then
                list[key] = "checked"
            end
        end
    end
    return list
end
M.parse_list = parse_list

-- "seed\tslot" from a list's header line ("AP1<TAB>seed<TAB>slot"), or nil.
local function list_session(text)
    local seed, slot = text:match("^AP1\t([^\t\r\n]*)\t([^\t\r\n]*)")
    return seed and (seed .. "\t" .. slot) or nil
end

-- The loaded save's properties: the PlayerCharacter's SPropComponent.
local function player_sprop()
    local player = FindFirstOf("PlayerCharacter")
    local name = player and safe(function() return player:IsValid() and player:GetFullName() end)
    if not name then
        return nil
    end
    for _, c in ipairs(FindAllOf("SPropComponent") or {}) do
        if safe(function() return c:IsValid() and c:GetOuter():GetFullName() == name end) then
            return c
        end
    end
    return nil
end

-- Whether the loaded save was played with this session: the bridge's mark,
-- or (saves from before the mark) its delivered-item counter.
local function save_has_session(session)
    if accepted[session] then
        return true
    end
    local sprop = player_sprop()
    if not sprop then
        return false
    end
    local id = (session:gsub("\t", "_"))
    for _, name in ipairs({ "session_" .. id, "items_" .. id }) do
        local value = safe(function()
            return sprop:GetSPropTableNumberValue(PROP_DLG_SAVE_DATA, { COUNTER_TABLE, name })
        end)
        if type(value) == "number" and value > 0 then
            return true
        end
    end
    return false
end

local function read_wanted()
    if show_all then
        if not wanted then
            wanted = {}
            for key in pairs(positions) do
                wanted[key] = "todo"
            end
        end
        return
    end
    local words = read_flag()
    local vanilla = words.vanilla or false
    local text = nil
    if not vanilla then
        -- The vanilla tracker never looks at the randomizer's list.
        local file = io.open(MISSING_FILE, "r")
        text = file and file:read("a") or nil
        if file then
            file:close()
        end
    end
    stats.list = vanilla and "vanilla" or (text and "randomizer" or "tracker")
    if text then
        local session = list_session(text)
        if not (session and save_has_session(session)) then
            text = nil                -- another seed's list, or a save never played with it
            stats.list = "tracker (list of another seed ignored)"
        end
    end
    local mode = vanilla and "vanilla" or (text and "randomizer" or "tracker")
    if not text then
        text = tracker_text(words)   -- no randomizer: what the save says
    end
    local hide_checked = words.nocollected or false
    options.labels = not words.nolabels
    options.legend = words.legend or false   -- opt-in ("nolegend", the old word, is the default)
    options.icons = not words.noicons
    options.checked_icons = not words.plaincollected
    options.noload = words.noload or false
    local signature = table.concat({ tostring(text), mode, tostring(hide_checked), tostring(options.labels),
        tostring(options.legend), tostring(options.icons), tostring(options.checked_icons) }, "\n#")
    if signature == wanted_text then
        return
    end
    wanted_text = signature
    options.mode = mode
    scouted = {}
    wanted = parse_list(text, hide_checked, mode == "randomizer" and scouted or nil)
end

-- The Archipelago location name of a key ("LV9-1 - Treasure Box 19301"), as
-- in apworld/afterimage/data/locations.json.
local function location_name(key)
    local d = locations[key]
    if not d then
        return key
    end
    local kind = KIND[d.kind] or KIND[UNKNOWN_KIND]
    return string.format("%s - %s %d", d.room or d.level or "?", kind.word, d.id)
end
M.location_name = location_name

-- A name fit for a label: not empty and not an internal id ("Item_...",
-- "Quest_...", "Lv1_2", anything with an underscore and no space).
local function readable(text)
    if type(text) ~= "string" or not text:find("%S") then
        return nil
    end
    if not text:find(" ", 1, true) and text:find("_", 1, true) then
        return nil
    end
    return text
end

-- What a marker's label says (see the header): what the item is, never an
-- internal id. The scouted item if the randomizer's list carries it, else
-- the vanilla item's English name, else the kind ("Treasure box").
local function label_text(key)
    local d = locations[key]
    local kind = KIND[d and d.kind or UNKNOWN_KIND] or KIND[UNKNOWN_KIND]
    return (options.mode ~= "vanilla" and readable(scouted[key])) or readable(d and d.item) or kind.legend
end
M.label_text = label_text

-- A key's kind style (KIND entry).
local function kind_of(key)
    local d = locations[key]
    return KIND[d and d.kind or UNKNOWN_KIND] or KIND[UNKNOWN_KIND]
end
M.kind_of = function(key) return kind_of(key) end

-- The icon frame a marker shows (see ICON_PX above), or nil: in randomizer
-- mode the scouted item's when the list names one (by its English name, also
-- without a trailing " (<player>)"; nil for another game's item), else the
-- vanilla item's.
local function icon_frame(key)
    local d = locations[key]
    local item = options.mode == "randomizer" and scouted[key] or nil
    if item then
        local name = item:gsub("%s*%b()$", "")
        if name:match("^Coins_%d+$") or name:match("^%d+ [Dd]ews?$") or name:match("^%d+ [Cc]oins?$") then
            return "dew"                        -- a coin bundle: the currency icon
        end
        return icon_names[item] or icon_names[name]
    end
    return d and d.icon ~= "" and d.icon or nil
end
M.icon_frame = icon_frame

local frame_alias = {}         -- frame name -> object path to use instead (M.alias_frame, experiments)

-- A frame is a name in the item icon atlases (ICON_DIRS), or a full object
-- path (the currency icon, outside them).
local function frame_paths(frame)
    local paths = {}
    if frame_alias[frame] then
        paths[1] = frame_alias[frame]
    end
    if NAMED_FRAMES[frame] or frame:find("/", 1, true) then
        paths[#paths + 1] = NAMED_FRAMES[frame] or frame
        return paths
    end
    for _, dir in ipairs(ICON_DIRS) do
        paths[#paths + 1] = dir .. frame .. "." .. frame
    end
    return paths
end

-- The frame's object if it is loaded (StaticFindObject finds only loaded
-- objects: this never loads anything), else nil.
local function find_frame(frame)
    for _, path in ipairs(frame_paths(frame)) do
        local found = StaticFindObject(path)
        if found and safe(function() return found:IsValid() end) then
            return found
        end
    end
    return nil
end

-- Frames not loaded with the map (the balms' bottles, some recolours) are
-- loaded with UE4SS's LoadAsset when a marker needing one comes into view:
-- each path at most once per map opening, at most LOAD_PER_TICK per tick (a
-- small atlas frame each, a few ms at worst). Loading them while the map is
-- closed does not work: the 2026-11-20 run loaded all 12 at the title
-- screen and they were garbage-collected by the save's level load. Loaded
-- just before use, the Image's brush holds the frame while it is drawn; the
-- validity check in place_icons covers one collected meanwhile. Flag word
-- "noload" turns it off; a failing LoadAsset only leaves the glyph.
local LOAD_PER_TICK = 4
local load_tried = {}          -- path -> true, asked during this map opening
local loads_this_tick = 0
local load_stats = { asked = 0, loaded = 0 }

local function load_frame(frame)
    if options.noload or type(LoadAsset) ~= "function" then
        return nil
    end
    for _, path in ipairs(frame_paths(frame)) do
        if not load_tried[path] then
            if loads_this_tick >= LOAD_PER_TICK then
                return nil, true                -- try again next tick
            end
            load_tried[path] = true
            loads_this_tick = loads_this_tick + 1
            load_stats.asked = load_stats.asked + 1
            local ok, obj = pcall(LoadAsset, path)
            if ok and obj and safe(function() return obj:IsValid() end) then
                load_stats.loaded = load_stats.loaded + 1
                return obj
            end
        end
    end
    return nil
end

-- The loaded atlas frame object for a frame name, or nil; looked up once per
-- map opening. Not loaded: LoadAsset (above). Not to be had: a recolour
-- frame ("..._C01") falls back to its base frame (the same picture in the
-- base colour), which usually is loaded.
local function frame_object(frame)
    local obj = frame_cache[frame]
    if obj == nil then
        local later
        obj = find_frame(frame)
        if not obj then
            obj, later = load_frame(frame)
        end
        if not obj and not later then
            local base = frame:match("^(.-)_[Cc]%d+$")
            obj = base and find_frame(base) or nil
        end
        if later and not obj then
            return nil                          -- not cached: asked again next tick
        end
        frame_cache[frame] = obj or false
    end
    return obj or nil
end

-- Give a marker's icon Image back to the pool, hidden.
local function release_icon(m)
    local img = m.img
    if img then
        m.img = nil
        iconed[m] = nil
        free_icons[#free_icons + 1] = img
        if img.shown then
            img.shown = false
            pcall(function() img.widget:SetVisibility(COLLAPSED) end)
        end
    end
end

local function clear_markers()
    for _, m in pairs(markers) do
        pcall(function() m.widget:RemoveFromParent() end)
        if m.img then
            pcall(function() m.img.widget:RemoveFromParent() end)
        end
    end
    for _, list in ipairs({ labels, legend, free_icons }) do
        for _, l in ipairs(list) do
            pcall(function() l.widget:RemoveFromParent() end)
        end
    end
    markers, labels, legend, free_icons, iconed = {}, {}, {}, {}, {}
    icon_pool, frame_cache, load_tried = 0, {}, {}
    stats.placed, stats.checked, stats.labels, stats.icons = 0, 0, 0, 0
end

-- Glyph, colour and draw order for a marker's state.
local function style(key, m, state)
    if state == "checked" then
        m.slot:SetZOrder(CHECKED_Z)
        m.widget:SetText(FText(CHECKED_TEXT))
        m.widget:SetColorAndOpacity({ SpecifiedColor = CHECKED_COLOR, ColorUseRule = 0 })
    else
        local kind = kind_of(key)
        m.slot:SetZOrder(TODO_Z)
        m.widget:SetText(FText(kind.glyph))
        m.widget:SetColorAndOpacity({ SpecifiedColor = kind.color, ColorUseRule = 0 })
    end
    m.state = state
end

-- A text widget in the panel for labels and the legend: left-middle aligned
-- and scaled around that point, with a shadow, hidden until placed.
local function new_text(z)
    local widget = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), panel)
    local slot = panel:AddChildToCanvas(widget)
    slot:SetAutoSize(true)
    slot:SetAlignment({ X = 0, Y = 0.5 })
    slot:SetZOrder(z)
    pcall(function() widget:SetRenderTransformPivot({ X = 0, Y = 0.5 }) end)
    pcall(function() widget:SetShadowOffset({ X = 1, Y = 1 }) end)
    pcall(function() widget:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 }) end)
    widget:SetVisibility(COLLAPSED)
    return { widget = widget, slot = slot }
end

-- Set a label / legend widget's text and colour, only when they changed.
local function set_text(l, text, color)
    if l.text ~= text then
        l.widget:SetText(FText(text))
        l.text = text
    end
    if l.color ~= color then
        l.widget:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
        l.color = color
    end
end

local function set_shown(l, shown)
    if l.shown ~= shown then
        l.widget:SetVisibility(shown and VISIBLE or COLLAPSED)
        l.shown = shown
    end
end

-- Undo the panel's zoom scale (k) on a label or legend line, so its text is
-- the same size on screen at every zoom.
local function set_scale(l, scale)
    if l.scale ~= scale then
        l.widget:SetRenderScale({ X = scale, Y = scale })
        l.scale = scale
    end
end

-- The legend's lines: the mode, each kind on the map, and "checked".
local function legend_lines()
    local lines = {}
    if not options.legend then
        return lines
    end
    local kinds, any_checked = {}, false
    for key, state in pairs(wanted or {}) do
        if positions[key] then
            if state == "checked" then
                any_checked = true
            else
                local d = locations[key]
                kinds[d and d.kind or UNKNOWN_KIND] = true
            end
        end
    end
    if not any_checked and next(kinds) == nil then
        return lines                             -- nothing on the map
    end
    lines[1] = { text = MODE_TITLE[options.mode] or options.mode, color = LEGEND_TITLE_COLOR }
    if options.icons and not icons_failed and next(kinds) ~= nil then
        -- Only if some unchecked marker has its icon loaded. The glyph lines
        -- below stay: a location whose icon is not loaded (or another game's
        -- item) keeps its glyph.
        for _, m in pairs(markers) do
            if m.state == "todo" and m.frame and frame_object(m.frame) then
                lines[2] = { text = ICON_LEGEND[options.mode] or ICON_LEGEND.tracker, color = ICON_LEGEND_COLOR }
                break
            end
        end
    end
    for _, kind in ipairs(KIND_ORDER) do
        if kinds[kind] then
            lines[#lines + 1] = { text = KIND[kind].glyph .. "  " .. KIND[kind].legend, color = KIND[kind].color }
        end
    end
    if any_checked then
        lines[#lines + 1] = { text = CHECKED_TEXT .. "  Checked", color = CHECKED_COLOR }
    end
    return lines
end

local function sync_legend()
    local lines = legend_lines()
    for i, line in ipairs(lines) do
        local l = legend[i]
        if not l then
            l = new_text(LABEL_Z)
            legend[i] = l
        end
        set_text(l, line.text, line.color)
        l.k = nil   -- re-place: the line count may have changed
    end
    for i = #legend, #lines + 1, -1 do
        pcall(function() legend[i].widget:RemoveFromParent() end)
        legend[i] = nil
    end
end

-- Create markers for wanted keys, restyle those whose state changed (same
-- widget), remove markers for keys no longer wanted.
local function sync_markers()
    for key, m in pairs(markers) do
        local state = wanted[key]
        if not state then
            release_icon(m)
            pcall(function() m.widget:RemoveFromParent() end)
            markers[key] = nil
        elseif state ~= m.state then
            pcall(style, key, m, state)
        end
    end
    local text_class = StaticFindObject("/Script/UMG.TextBlock")
    for key, state in pairs(wanted) do
        local pos = positions[key]
        if pos and not markers[key] then
            local ok, m = pcall(function()
                local widget = StaticConstructObject(text_class, panel)
                local slot = panel:AddChildToCanvas(widget)
                slot:SetAutoSize(true)
                slot:SetAlignment({ X = 0.5, Y = 0.5 })
                widget:SetVisibility(COLLAPSED)
                local m = { key = key, widget = widget, slot = slot, mx = pos[1] * MAP_SCALE, my = -pos[2] * MAP_SCALE }
                style(key, m, state)
                return m
            end)
            if ok then
                markers[key] = m
            end
        end
    end
    local placed, checked = 0, 0
    for key, m in pairs(markers) do
        placed = placed + 1
        if m.state == "checked" then
            checked = checked + 1
        end
        m.label = label_text(key)   -- the mode or the scouted item may have changed
        m.frame = icon_frame(key)
    end
    stats.placed, stats.checked = placed, checked
    pcall(sync_legend)
    last_view = nil  -- force a re-place
end

-- The zoom the map is drawn at. Minimap_C.TargetZoom, not CurrentZoom:
-- with the game paused on the map, CurrentZoom moves only part of the way
-- after A / D (1.2 -> 1.2449 for a step to 1.45, unchanged 3 s later), while
-- the drawn map goes all the way to TargetZoom (docs/game-internals.md, "Map
-- zoom: TargetZoom"). Used for what is in view and for hiding when zoomed
-- out; the markers' own offsets do not scale with it (PANEL_ZOOM).
local function map_zoom()
    local zoom = safe(function() return map.TargetZoom end)
    if type(zoom) ~= "number" or zoom <= 0 then
        zoom = map.CurrentZoom
    end
    return zoom
end

-- The view centre in map px and the zoom.
local function view()
    local zoom = map_zoom()
    local p = safe(function() return map.PlayerMinimapComp.PreviewLoc end)
    local cx, cy = p and p.X or 0, p and p.Y or 0
    stats.source = "PreviewLoc"
    if cx == 0 and cy == 0 then
        -- Not set (yet): the map opens centred on the player.
        local player = FindFirstOf("PlayerCharacter")
        local at = player and safe(function() return player:K2_GetActorLocation() end)
        if at then
            cx, cy = at.X * MAP_SCALE, -at.Z * MAP_SCALE
            stats.source = "player"
        end
    end
    return cx, cy, zoom
end

local place_extras             -- below
local extras_failed = false

-- A new icon Image in the panel: ICON_PX square at zoom 1, centred on its
-- slot (render scale pivot: the middle, the default), hidden until placed.
local function new_image()
    local widget = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), panel)
    local slot = panel:AddChildToCanvas(widget)
    slot:SetAutoSize(false)
    slot:SetSize({ X = ICON_PX, Y = ICON_PX })
    slot:SetAlignment({ X = 0.5, Y = 0.5 })
    slot:SetZOrder(ICON_Z)
    widget:SetVisibility(COLLAPSED)
    icon_pool = icon_pool + 1
    return { widget = widget, slot = slot }
end

-- Icons for the visible markers whose frame is loaded (unchecked ones, and
-- checked ones dimmed unless "plaincollected"); the others
-- (and those gone from view) give theirs back to the pool. Brushes are set
-- only when an Image gets another frame; on a pan each icon costs one
-- SetPosition, like a glyph.
local function place_icons(inview, zoom)
    local keep, objs = {}, {}
    local scale = 1 / zoom         -- undo the panel's zoom: ICON_PX window px at every zoom
    for _, m in ipairs(inview) do
        local frame = (m.state == "todo" or (options.checked_icons and not tint_failed)) and m.frame or nil
        local obj = frame and frame_object(frame)
        if obj and m.img and m.img.frame == frame then
            keep[m] = true          -- unchanged: its brush holds the frame (no lookup)
            objs[#objs + 1] = { m, frame, obj }
        elseif obj and not obj:IsValid() then
            -- Garbage-collected since it was looked up (a frame LoadAsset
            -- loaded): never hand a dead object to a brush; look again
            -- next time, the glyph meanwhile.
            frame_cache[frame] = nil
        elseif obj then
            keep[m], objs[#objs + 1] = true, { m, frame, obj }
        end
    end
    -- Free the Images of markers gone first, so the pool never grows past
    -- the most icons on screen at once.
    for m in pairs(iconed) do
        if not keep[m] then
            release_icon(m)
        end
    end
    iconed = keep
    for _, e in ipairs(objs) do
        local m, frame, obj = e[1], e[2], e[3]
        local img = m.img
        if not img then
            img = table.remove(free_icons) or new_image()
            m.img = img
        end
        if img.frame ~= frame then
            img.frame = nil         -- unknown if the call fails
            img.widget:SetBrushResourceObject(obj)
            img.frame = frame
        end
        if img.state ~= m.state and not (tint_failed and m.state == "todo") then
            -- Checked: grey, faint and under the "x"; unchecked: as drawn.
            -- Its own pcall: a failing tint drops only the checked icons
            -- (logged once), never the unchecked ones.
            img.state = nil         -- unknown if a call fails
            local checked = m.state == "checked"
            local ok, err = pcall(function()
                img.widget:SetColorAndOpacity(checked and CHECKED_ICON_COLOR or ICON_COLOR)
                img.slot:SetZOrder(checked and CHECKED_ICON_Z or ICON_Z)
            end)
            if ok then
                img.state = m.state
            else
                if not tint_failed then
                    tint_failed = true
                    print(LOG .. "map overlay: dimmed icons for checked locations off: " .. tostring(err) .. "\n")
                end
                if checked then
                    release_icon(m)     -- the grey "x" only, this tick already
                end
            end
        end
        if m.img then
            img.slot:SetPosition({ X = m.x, Y = m.y })
            set_scale(img, scale)
            set_shown(img, true)
        end
    end
end

local function icons_off(err)
    icons_failed = true
    print(LOG .. "map overlay: item icons off, glyphs instead: " .. tostring(err) .. "\n")
    for m in pairs(iconed) do
        release_icon(m)
    end
    for _, m in pairs(markers) do
        m.img = nil
    end
    for _, img in ipairs(free_icons) do
        pcall(function() img.widget:SetVisibility(COLLAPSED) end)
        img.shown = false
    end
    iconed = {}
    pcall(sync_legend)             -- without the icon line
end

local function place_markers()
    local cx, cy, zoom = view()
    local key = string.format("%.2f %.2f %.4f", cx, cy, zoom)
    if key == last_view then
        return
    end
    last_view = key
    stats.cx, stats.cy, stats.zoom = cx, cy, zoom
    local visible = 0
    local zoomed_out = zoom < HIDE_BELOW_ZOOM
    local mid_x, mid_y = PANEL_W / 2, PANEL_H / 2
    -- A full line of margin above the title: a grey "x" just above it touched
    -- the title in game (2026-11-19).
    local legend_top = LEGEND_BOTTOM - (#legend - 1) * LEGEND_DY - LEGEND_DY
    local shown = {}                             -- visible markers: { m, d2 (distance to the centre, squared) }
    local inview = {}
    for _, m in pairs(markers) do
        -- Where the marker shows in the map window (window px): decides
        -- whether it is in view.
        local px = mid_x + (m.mx - cx) * PANEL_PER_MAP * zoom
        local py = mid_y + (m.my - cy) * PANEL_PER_MAP * zoom
        local under_legend = (px >= LEGEND_X and py <= LEGEND_Y)
            or (#legend > 0 and not extras_failed and px <= LEGEND_SX + LEGEND_W and py >= legend_top)
        if not zoomed_out and px >= EDGE and px <= PANEL_W - EDGE and py >= EDGE and py <= PANEL_H - EDGE
            and not under_legend then
            -- Its position inside MapNamePanel, which the game itself scales
            -- (with the map) by the zoom around the panel's middle.
            m.x, m.y = mid_x + (m.mx - cx) * PANEL_PER_MAP, mid_y + (m.my - cy) * PANEL_PER_MAP
            m.wx, m.wy = px, py
            m.inview = true
            inview[#inview + 1] = m
            visible = visible + 1
            shown[#shown + 1] = { m = m, d2 = (px - mid_x) ^ 2 + (py - mid_y) ^ 2 }
        else
            m.inview = false
        end
    end
    -- Icons first (they decide which glyphs show), in their own pcall: a
    -- failing call turns icons off and the glyphs work as before.
    if options.icons and not icons_failed then
        local ok, err = pcall(place_icons, inview, zoom)
        if not ok then
            icons_off(err)
        end
    elseif next(iconed) ~= nil then
        for m in pairs(iconed) do
            release_icon(m)        -- turned off with "noicons"
        end
        iconed = {}
    end
    local n_icons = 0
    for _, m in pairs(markers) do
        -- A checked marker's grey "x" shows over its dimmed icon.
        local glyph = m.inview and (not m.img or m.state == "checked")
        if m.img then
            n_icons = n_icons + 1
        end
        if glyph then
            m.slot:SetPosition({ X = m.x, Y = m.y })
        end
        if glyph ~= (m.shown or false) then
            m.widget:SetVisibility(glyph and VISIBLE or COLLAPSED)
            m.shown = glyph
        end
    end
    stats.visible, stats.icons = visible, n_icons
    -- Labels and legend are extras: if a widget call fails in the game, the
    -- markers keep working (logged once, labels and legend off for the run).
    if not extras_failed then
        local ok, err = pcall(place_extras, shown, zoom, zoomed_out)
        if not ok then
            extras_failed = true
            print(LOG .. "map overlay: labels / legend off: " .. tostring(err) .. "\n")
            for _, list in ipairs({ labels, legend }) do
                for _, l in ipairs(list) do
                    pcall(function() l.widget:SetVisibility(COLLAPSED) end)
                end
            end
        end
    end
end

-- A label's left edge right of its marker, panel px: past the icon's right
-- edge when the marker shows one (ICON_PX window px wide at every zoom k).
local function label_dx(m, k)
    return m.img and (ICON_PX / 2 + ICON_LABEL_GAP) / k or LABEL_DX
end

-- Place the labels (every visible marker zoomed in, else the one nearest the
-- view centre) and the legend, for markers already placed.
place_extras = function(shown, zoom, zoomed_out)
    local k = zoom                 -- panel px -> window px
    local mid_x, mid_y = PANEL_W / 2, PANEL_H / 2
    local chosen = {}
    if options.labels and not zoomed_out and #shown > 0 then
        table.sort(shown, function(a, b)
            if a.d2 ~= b.d2 then return a.d2 < b.d2 end
            return a.m.key < b.m.key
        end)
        if zoom >= LABEL_ALL_ZOOM then
            -- Nearest the centre first; a label overlapping one already
            -- chosen is left out (boxes in window px).
            local boxes = {}
            for _, s in ipairs(shown) do
                if #chosen >= MAX_LABELS then
                    break
                end
                local m = s.m
                local x0 = m.wx + label_dx(m, k) * k
                local x1 = x0 + #(m.label or label_text(m.key)) * LABEL_CHAR_W
                local y0, y1 = m.wy - LABEL_LINE_H / 2, m.wy + LABEL_LINE_H / 2
                local free = true
                for _, b in ipairs(boxes) do
                    if x0 < b[2] and b[1] < x1 and y0 < b[4] and b[3] < y1 then
                        free = false
                        break
                    end
                end
                if free then
                    boxes[#boxes + 1] = { x0, x1, y0, y1 }
                    chosen[#chosen + 1] = m
                end
            end
        elseif shown[1].d2 <= FOCUS_RADIUS ^ 2 then
            chosen[1] = shown[1].m
        end
    end
    local scale = LABEL_SCALE / k
    for i, m in ipairs(chosen) do
        local l = labels[i]
        if not l then
            l = new_text(LABEL_Z)
            labels[i] = l
        end
        l.key = m.key
        set_text(l, m.label or label_text(m.key), m.state == "checked" and LABEL_CHECKED_COLOR or LABEL_COLOR)
        set_scale(l, scale)
        l.slot:SetPosition({ X = m.x + label_dx(m, k), Y = m.y })
        set_shown(l, true)
    end
    for i = #chosen + 1, #labels do
        labels[i].key = nil
        set_shown(labels[i], false)
    end
    stats.labels = #chosen

    -- The legend: fixed on screen, so placed against the panel's scale.
    for i, l in ipairs(legend) do
        if zoomed_out then
            set_shown(l, false)
        else
            local sy = LEGEND_BOTTOM - (#legend - i) * LEGEND_DY
            set_scale(l, LEGEND_SCALE / k)
            if l.k ~= k then
                l.slot:SetPosition({ X = mid_x + (LEGEND_SX - mid_x) / k, Y = mid_y + (sy - mid_y) / k })
                l.k = k
            end
            set_shown(l, true)
        end
    end
end

local seen_generation = transition.generation()
-- Cost of place_markers per open-map tick (os.clock: wall time with MSVC),
-- for experiment logs (M.perf).
local perf = { n = 0, total = 0, max = 0 }

local function tick()
    if transition.generation() ~= seen_generation then
        -- Pawn switch (transition.lua): forget the map and its widgets
        -- without touching them; they are rebuilt when the map opens again.
        seen_generation = transition.generation()
        markers, labels, legend, map, panel = {}, {}, {}, nil, nil
        free_icons, iconed, icon_pool, frame_cache, load_tried = {}, {}, 0, {}, {}
        stats.placed, stats.checked, stats.labels, stats.icons = 0, 0, 0, 0
    end
    if transition.quiet() then
        return CLOSED_POLL_MS
    end
    if map and not safe(function() return map:IsValid() and map:IsInViewport() end) then
        clear_markers()  -- map closed; its widgets may be reused or destroyed
        map, panel = nil, nil
    end
    loads_this_tick = 0
    if not map then
        map = find_open_map()
        if not map then
            -- Standalone tracker: keep up with boxes opened while the map is
            -- closed, before their room unloads.
            if not show_all and stats.list ~= "randomizer"
                and (last_live == nil or elapsed - last_live >= LIVE_MS) then
                last_live = elapsed
                refresh_loaded()
            end
            return CLOSED_POLL_MS
        end
        panel = map.MapNamePanel
        last_file_check = -FILE_RECHECK_MS
    end
    if elapsed - last_file_check >= FILE_RECHECK_MS then
        last_file_check = elapsed
        local before = wanted_text
        read_wanted()
        if wanted and (stats.placed == 0 or wanted_text ~= before) then
            sync_markers()
        end
    end
    local t0 = os.clock()
    place_markers()
    local ms = (os.clock() - t0) * 1000
    perf.n, perf.total, perf.max = perf.n + 1, perf.total + ms, math.max(perf.max, ms)
    return OPEN_TICK_MS
end

local function loop()
    local ok, delay = pcall(tick)
    if not ok then
        print(LOG .. "map overlay: " .. tostring(delay) .. "\n")
        clear_markers()
        map, panel = nil, nil
        delay = 1000
    end
    elapsed = elapsed + delay
    ExecuteInGameThreadWithDelay(delay, loop)
end

-- opts.show_all: mark every location with a known position (experiments).
-- opts.flag_files: the flag files to read, first existing wins (default
-- { "AfterimageAP_tracker.flag" }); opts.log_prefix: the log lines' prefix.
function M.start(opts)
    show_all = opts and opts.show_all or false
    if opts and opts.flag_files then
        flag_files = {}
        for i, name in ipairs(opts.flag_files) do
            flag_files[i] = name
        end
    end
    if opts and opts.log_prefix then
        LOG = opts.log_prefix
    end
    wanted, wanted_text = nil, nil  -- re-read with the new mode
    if running then
        return
    end
    running = true
    ExecuteInGameThreadWithDelay(CLOSED_POLL_MS, loop)
end

-- For experiment logs: a location's marker state ("todo" / "checked"), or nil
-- if it has no marker (not on the list, or the map is closed).
function M.marker_state(key)
    local m = markers[key]
    return m and m.state or nil
end

-- Show the list of this session ("seed\tslot") on any save (experiments
-- writing a test list, which must not mark the player's save).
function M.accept_session(session)
    accepted[session] = true
end

-- For experiment logs.
-- For experiment logs: the render scale of MapNamePanel and each widget
-- above it that is not 1 ("name=sx" ...), or "-".
local function panel_scales()
    local parts = {}
    local w, guard = panel, 0
    while w and guard < 20 do
        local s = safe(function() return w.RenderTransform.Scale end)
        local name = safe(function() return w:GetFName():ToString() end) or "?"
        if s and (math.abs(s.X - 1) > 1e-4 or math.abs(s.Y - 1) > 1e-4) then
            parts[#parts + 1] = string.format("%s=%.4f,%.4f", name, s.X, s.Y)
        end
        local user = safe(function() return w.UserSpecifiedScale end)
        if type(user) == "number" and math.abs(user - 1) > 1e-4 then
            parts[#parts + 1] = string.format("%s.user=%.4f", name, user)
        end
        w = safe(function() local p = w:GetParent(); return p:IsValid() and p or nil end)
        guard = guard + 1
    end
    return #parts > 0 and table.concat(parts, " ") or "-"
end

function M.status()
    local current = map and safe(function() return map.CurrentZoom end)
    return string.format("open=%s markers=%d checked=%d visible=%d labels=%d icons=%d pool=%d%s centre=%.1f,%.1f (%s) zoom=%.4f (CurrentZoom %s) list=%s mode=%s legend=%d scales=%s",
        tostring(map ~= nil), stats.placed, stats.checked, stats.visible, stats.labels, stats.icons, icon_pool,
        icons_failed and " (icons failed)" or (options.icons and "" or " (icons off)"), stats.cx, stats.cy, stats.source,
        stats.zoom, type(current) == "number" and string.format("%.4f", current) or "-", stats.list,
        options.mode, #M.legend_shown(), map and panel and panel_scales() or "-")
end

-- For experiment logs and tests: the labels shown now, "<key> = <text>",
-- nearest the view centre first; and the legend's lines.
function M.labels_shown()
    local out = {}
    for _, l in ipairs(labels) do
        if l.shown and l.key then
            out[#out + 1] = l.key .. " = " .. tostring(l.text)
        end
    end
    return out
end

-- For experiment logs and tests: the icons shown now, "<key> = <frame>";
-- and, over the unchecked markers with a frame, how many frames are loaded
-- (plus the first few missing frames).
function M.icons_shown()
    local out = {}
    for m in pairs(iconed) do
        out[#out + 1] = m.key .. " = " .. tostring(m.img and m.img.frame)
    end
    table.sort(out)
    return out
end

-- Experiments: draw `frame` from the object at `path` (nil: back to the
-- frame itself); forget the looked-up frames and re-place.
function M.alias_frame(frame, path)
    frame_alias[frame] = path
    frame_cache = {}
    last_view = nil
end

function M.load_report()
    return string.format("icon frames loaded by LoadAsset: %d of %d asked%s", load_stats.loaded, load_stats.asked,
        type(LoadAsset) == "function" and "" or " (no LoadAsset)")
end

-- place_markers' cost since the last call ("ticks avg max" in ms), reset.
function M.perf()
    local text = string.format("ticks=%d avg=%.2fms max=%.2fms", perf.n, perf.n > 0 and perf.total / perf.n or 0, perf.max)
    perf.n, perf.total, perf.max = 0, 0, 0
    return text
end

function M.icon_report()
    local todo, with_frame, loaded, missing, seen_missing = 0, 0, 0, {}, {}
    for _, m in pairs(markers) do
        if m.state == "todo" then
            todo = todo + 1
            if m.frame then
                with_frame = with_frame + 1
                if frame_object(m.frame) then
                    loaded = loaded + 1
                elseif not seen_missing[m.frame] then
                    seen_missing[m.frame] = true
                    missing[#missing + 1] = m.frame
                end
            end
        end
    end
    table.sort(missing)
    return string.format("icons: %d of %d unchecked markers with a frame have it loaded (%d unchecked); not loaded: %s",
        loaded, with_frame, todo, #missing > 0 and table.concat(missing, " ", 1, math.min(#missing, 12)) or "-")
end

function M.legend_shown()
    local out = {}
    for _, l in ipairs(legend) do
        if l.shown then
            out[#out + 1] = tostring(l.text)
        end
    end
    return out
end

return M

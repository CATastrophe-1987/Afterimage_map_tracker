-- In-game map overlay: a marker on every location still to check.
--
-- Which locations:
--   * Randomizer: the keys in AfterimageAP_missing.txt, written by the
--     Python client (apworld/afterimage/client.py) while connected:
--     line 1 "AP1 <seed> <slot>", then one location key per line.
--   * Otherwise, standalone tracker: every box, placed pickup and coin rock
--     the save says is not done yet, read by save id (works for rooms that
--     are not loaded; docs/game-internals.md, "Standalone map tracker").
--     AfterimageAP_tracker.flag next to the game exe (optional): the word
--     "off" turns it off, "norocks" hides coin rocks.
-- Locations without a known world position (boss drops) are not shown.
-- Colours: boxes magenta, pickups cyan, coin rocks yellow.
--
-- Transform (docs/game-internals.md, "Map overlay transform"): the map is a
-- MAP_SCALE copy of the world, screen y against world Z. The map component's
-- PreviewLoc is the view centre in map px, (world_x, -world_z) * MAP_SCALE,
-- and MapNamePanel (PANEL_W x PANEL_H) shows it in its middle at CurrentZoom.
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
local MISSING_FILE = "AfterimageAP_missing.txt"
local CLOSED_POLL_MS = 250
local OPEN_TICK_MS = 33
local FILE_RECHECK_MS = 2000
local VISIBLE = 3              -- ESlateVisibility.HitTestInvisible
local COLLAPSED = 1
local MARKER_TEXT = "+"
local MARKER_COLOR = { R = 1, G = 0.2, B = 1, A = 1 }
local KIND_COLOR = {
    box = MARKER_COLOR,
    pickup = { R = 0.2, G = 0.9, B = 1, A = 1 },
    rock = { R = 1, G = 0.85, B = 0.2, A = 1 },
}
local TRACKER_FLAG = "AfterimageAP_tracker.flag"
local PROP_OPEN = 11            -- prop_status_object_open
local PROP_DROP_RECORD = 102    -- prop_item_drop_record (table: item id -> 1 while the drop waits)

local positions = require("data_positions")
local locations = require("data_locations")   -- key -> { id = save id, kind, level }

local M = {}

local show_all = false
local running = false
local map = nil                -- open Minimap_C
local panel = nil              -- its MapNamePanel
local markers = {}             -- key -> { widget, slot, mx, my } (mx, my: map px)
local wanted = nil             -- key -> true, the locations to show
local wanted_text = nil
local last_view = nil
local last_file_check = 0
local elapsed = 0
local stats = { placed = 0, visible = 0, cx = 0, cy = 0, zoom = 0, source = "-" }

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
local pickup_seen = {}      -- key -> true (collected) / false (drop still waiting), from loaded rooms

-- Pickups in loaded rooms: the exact rule. Collected = open and its item
-- no longer waiting in the drop record. Remembered for the session.
local function refresh_loaded_pickups()
    local pickups = FindAllOf("BP_DropActorAdv_C") or {}
    if #pickups == 0 then
        return
    end
    local sprop_of = {}     -- owner address -> its SPropComponent
    for _, c in ipairs(FindAllOf("SPropComponent") or {}) do
        pcall(function()
            if c:IsValid() then
                sprop_of[c:GetOwner():GetAddress()] = c
            end
        end)
    end
    for _, a in ipairs(pickups) do
        pcall(function()
            if not a:IsValid() then
                return
            end
            local level, name = a:GetFullName():match("([%w_%-]+):PersistentLevel%.(.+)$")
            local key = level and (level .. ":" .. name)
            if not key or not locations[key] then
                return
            end
            local sprop = sprop_of[a:GetAddress()]
            if not sprop then
                return
            end
            local open = sprop:GetSPropertyNumberValue(PROP_OPEN)
            local item = a.ConstItemID:ToString()
            local waiting = item ~= "" and sprop:GetSPropTableNumberValue(PROP_DROP_RECORD, { item }) or 0
            pickup_seen[key] = open == 1 and waiting == 0
        end)
    end
end

-- One line per location still to do (same shape as the missing file), or nil
-- when the tracker is off.
local function tracker_text()
    local f = io.open(TRACKER_FLAG, "r")
    local words = f and f:read("a") or ""
    if f then f:close() end
    if words:find("off", 1, true) then
        return nil
    end
    local no_rocks = words:find("norocks", 1, true) ~= nil
    lib = lib or StaticFindObject("/Script/SPropertySystem.Default__SPropertyBlueprintLib")
    if not lib or not lib:IsValid() then
        return nil
    end
    refresh_loaded_pickups()
    local keys = {}
    for key, d in pairs(locations) do
        if positions[key] and not (no_rocks and d.kind == "rock") then
            local open = safe(function() return lib:GetNumberValueBySaveID(d.id, PROP_OPEN) end)
            local done = open == 1
            if d.kind == "pickup" and done and pickup_seen[key] ~= nil then
                done = pickup_seen[key]       -- seen in a loaded room this session
            end
            if not done then
                keys[#keys + 1] = key
            end
        end
    end
    table.sort(keys)
    return "TRACKER\n" .. table.concat(keys, "\n")
end

local function read_wanted()
    if show_all then
        if not wanted then
            wanted = {}
            for key in pairs(positions) do
                wanted[key] = true
            end
        end
        return
    end
    local file = io.open(MISSING_FILE, "r")
    local text = file and file:read("a") or nil
    if file then
        file:close()
    end
    if not text then
        text = tracker_text()   -- no randomizer: what the save says is left
    end
    if text == wanted_text then
        return
    end
    wanted_text = text
    wanted = {}
    if text then
        local first = true
        for line in text:gmatch("[^\r\n]+") do
            if first then
                first = false  -- header
            else
                wanted[line] = true
            end
        end
    end
end

local function clear_markers()
    for _, m in pairs(markers) do
        pcall(function() m.widget:RemoveFromParent() end)
    end
    markers = {}
    stats.placed = 0
end

-- Create markers for wanted keys, remove markers for keys no longer wanted.
local function sync_markers()
    for key, m in pairs(markers) do
        if not wanted[key] then
            pcall(function() m.widget:RemoveFromParent() end)
            markers[key] = nil
            stats.placed = stats.placed - 1
        end
    end
    local text_class = StaticFindObject("/Script/UMG.TextBlock")
    for key in pairs(wanted) do
        local pos = positions[key]
        if pos and not markers[key] then
            local ok, m = pcall(function()
                local widget = StaticConstructObject(text_class, panel)
                local slot = panel:AddChildToCanvas(widget)
                slot:SetAutoSize(true)
                slot:SetAlignment({ X = 0.5, Y = 0.5 })
                slot:SetZOrder(1000)
                widget:SetText(FText(MARKER_TEXT))
                local kind = locations[key] and locations[key].kind
                widget:SetColorAndOpacity({ SpecifiedColor = KIND_COLOR[kind] or MARKER_COLOR, ColorUseRule = 0 })
                widget:SetVisibility(COLLAPSED)
                return { widget = widget, slot = slot, mx = pos[1] * MAP_SCALE, my = -pos[2] * MAP_SCALE }
            end)
            if ok then
                markers[key] = m
                stats.placed = stats.placed + 1
            end
        end
    end
    last_view = nil  -- force a re-place
end

-- The view centre in map px and the zoom.
local function view()
    local zoom = map.CurrentZoom
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
    for _, m in pairs(markers) do
        local px = PANEL_W / 2 + (m.mx - cx) * zoom
        local py = PANEL_H / 2 + (m.my - cy) * zoom
        local under_legend = px >= LEGEND_X and py <= LEGEND_Y
        if not zoomed_out and px >= EDGE and px <= PANEL_W - EDGE and py >= EDGE and py <= PANEL_H - EDGE
            and not under_legend then
            m.slot:SetPosition({ X = px, Y = py })
            if not m.shown then
                m.widget:SetVisibility(VISIBLE)
                m.shown = true
            end
            visible = visible + 1
        elseif m.shown then
            m.widget:SetVisibility(COLLAPSED)
            m.shown = false
        end
    end
    stats.visible = visible
end

local function tick()
    if map and not safe(function() return map:IsValid() and map:IsInViewport() end) then
        clear_markers()  -- map closed; its widgets may be reused or destroyed
        map, panel = nil, nil
    end
    if not map then
        map = find_open_map()
        if not map then
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
    place_markers()
    return OPEN_TICK_MS
end

local function loop()
    local ok, delay = pcall(tick)
    if not ok then
        print("[AfterimageAP] map overlay: " .. tostring(delay) .. "\n")
        clear_markers()
        map, panel = nil, nil
        delay = 1000
    end
    elapsed = elapsed + delay
    ExecuteInGameThreadWithDelay(delay, loop)
end

-- opts.show_all: mark every location with a known position (experiments).
function M.start(opts)
    show_all = opts and opts.show_all or false
    wanted, wanted_text = nil, nil  -- re-read with the new mode
    if running then
        return
    end
    running = true
    ExecuteInGameThreadWithDelay(CLOSED_POLL_MS, loop)
end

-- For experiment logs.
function M.status()
    return string.format("open=%s markers=%d visible=%d centre=%.1f,%.1f (%s) zoom=%.4f",
        tostring(map ~= nil), stats.placed, stats.visible, stats.cx, stats.cy, stats.source, stats.zoom)
end

return M

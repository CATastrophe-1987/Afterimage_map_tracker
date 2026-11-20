-- Copied from the Afterimage randomizer repo (client/AfterimageAP/Scripts/
-- map_probe.lua). Its modes are run in game by that repo's experiment.lua
-- (tools/run_experiment.ps1), which is not part of this mod; here the
-- offline tests (tests/map_overlay_test.py) run the tracker-related modes
-- (maptracker, maplabels, mapitemicons) against fake UE4SS objects. Not
-- loaded by the mod (it is outside AfterimageMapTracker/).

-- Experiment: find the in-game map's widgets and try drawing on them.
--
-- 1. Snapshot which top-level UMG widgets are on screen.
-- 2. Ask the player (through an "ACTION:" log line, which
--    tools/run_experiment.ps1 prints and beeps for) to open the map.
-- 3. Widgets that appear and stay are the map: dump their whole tree
--    (class, name, canvas slot position/size, render transform, image texture,
--    text) and their numeric properties, with the player's world position.
-- 4. Add a magenta "AP TEST" TextBlock to the busiest canvas panel, the step
--    most likely to fail, so it runs after the dump is on disk.
--
-- Output: AfterimageAP_mapprobe.txt. Never saves or changes game state other
-- than the added label.

local OUT_FILE = "AfterimageAP_mapprobe.txt"
local POLL_MS = 1000
local WAIT_FOR_MAP_S = 240
local STABLE_POLLS = 3
local MAX_LINES = 8000
local MARKER_SHOW_MS = 20000

local M = {}

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then
        return value
    end
    return nil
end

local function num(n)
    return type(n) == "number" and string.format("%.1f", n) or tostring(n)
end

local function vec2(v)
    if not v then
        return "-"
    end
    return num(safe(function() return v.X end)) .. "," .. num(safe(function() return v.Y end))
end

local function visible_top_widgets()
    local found = {}
    for _, w in ipairs(FindAllOf("UserWidget") or {}) do
        if w:IsValid() and safe(function() return w:IsInViewport() end) and safe(function() return w:IsVisible() end) then
            found[w:GetFullName()] = w
        end
    end
    return found
end

local function children_of(w)
    local list = {}
    local count = safe(function() return w:GetChildrenCount() end)
    if type(count) == "number" then
        for i = 0, count - 1 do
            local child = safe(function() return w:GetChildAt(i) end)
            if child and child:IsValid() then
                list[#list + 1] = child
            end
        end
    end
    local root = safe(function() return w.WidgetTree.RootWidget end)
    if root and safe(function() return root:IsValid() end) then
        list[#list + 1] = root
    end
    return list
end

local function describe(w)
    local class_name = safe(function() return w:GetClass():GetFName():ToString() end) or "?"
    local parts = { class_name, safe(function() return w:GetFName():ToString() end) or "?" }
    local slot = safe(function() return w.Slot end)
    if slot and safe(function() return slot:IsValid() end) then
        local slot_class = safe(function() return slot:GetClass():GetFName():ToString() end) or "?"
        if slot_class == "CanvasPanelSlot" then
            parts[#parts + 1] = "pos=" .. vec2(safe(function() return slot:GetPosition() end))
            parts[#parts + 1] = "size=" .. vec2(safe(function() return slot:GetSize() end))
            parts[#parts + 1] = "align=" .. vec2(safe(function() return slot:GetAlignment() end))
        else
            parts[#parts + 1] = "slot=" .. slot_class
        end
    end
    local t = safe(function() return w.RenderTransform end)
    if t then
        local tr, sc = safe(function() return t.Translation end), safe(function() return t.Scale end)
        local translation, scale = vec2(tr), vec2(sc)
        if translation ~= "0.0,0.0" or scale ~= "1.0,1.0" then
            parts[#parts + 1] = "render=" .. translation .. " scale=" .. scale
        end
    end
    local visibility = safe(function() return w:GetVisibility() end)
    if visibility ~= nil then
        parts[#parts + 1] = "vis=" .. tostring(visibility)
    end
    local texture = safe(function() return w.Brush.ResourceObject:GetFullName() end)
    if texture then
        parts[#parts + 1] = "image=" .. texture
    end
    local text = safe(function() return w:GetText():ToString() end)
    if text and text ~= "" then
        parts[#parts + 1] = "text=" .. text:gsub("[\r\n\t]", " ")
    end
    return table.concat(parts, "\t"), class_name
end

-- Numeric and vector properties of a user widget: zoom, offsets, scales live here.
local function dump_properties(out, w)
    local ok = pcall(function()
        w:GetClass():ForEachProperty(function(prop)
            local kind = prop:GetClass():GetFName():ToString()
            local name = prop:GetFName():ToString()
            if kind == "FloatProperty" or kind == "IntProperty" or kind == "BoolProperty" or kind == "DoubleProperty" then
                out:write("    prop ", name, " = ", tostring(safe(function() return w[name] end)), "\n")
            elseif kind == "StructProperty" then
                local v = safe(function() return w[name] end)
                local x = v and safe(function() return v.X end)
                if x ~= nil then
                    out:write("    prop ", name, " = ", vec2(v), "\n")
                end
            elseif kind == "ObjectProperty" then
                local v = safe(function() return w[name] end)
                local full = v and safe(function() return v:GetFullName() end)
                if full then
                    out:write("    prop ", name, " -> ", full, "\n")
                end
            end
        end)
    end)
    if not ok then
        out:write("    (properties not readable)\n")
    end
end

-- Generic, defensive property printer: numbers, strings, names, nested
-- structs (2 levels), arrays (first 24 elements), object references.
local function value_text(v)
    if v == nil then
        return "nil"
    end
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then
        return tostring(v)
    end
    local s = safe(function() return v:ToString() end)
    if type(s) == "string" then
        return '"' .. s .. '"'
    end
    local full = safe(function() return v:GetFullName() end)
    if type(full) == "string" then
        return "-> " .. full
    end
    local x = safe(function() return v.X end)
    if x ~= nil then
        local parts = { "X=" .. num(x) }
        for _, f in ipairs({ "Y", "Z", "W" }) do
            local c = safe(function() return v[f] end)
            if type(c) == "number" then
                parts[#parts + 1] = f .. "=" .. num(c)
            end
        end
        return "(" .. table.concat(parts, " ") .. ")"
    end
    return "<" .. t .. ">"
end

local function each_property(class, fn)
    local current, guard = class, 0
    while current and guard < 12 do
        pcall(function() current:ForEachProperty(fn) end)
        current = safe(function() local super = current:GetSuperStruct(); return super:IsValid() and super or nil end)
        guard = guard + 1
    end
end

-- How deep the dumper goes. The map probe keeps it shallow; the map data
-- dump (M.dump_data) follows nested structs, arrays and minimap assets.
local limits = { depth = 2, elements = 24, follow = nil }
local visited = {}

local dump_value

local function dump_fields(out, indent, struct, v, depth)
    each_property(struct, function(p)
        local n = p:GetFName():ToString()
        dump_value(out, indent, n, p:GetClass():GetFName():ToString(), p, safe(function() return v[n] end), depth)
    end)
end

dump_value = function(out, indent, name, kind, prop, v, depth)
    if kind == "StructProperty" and depth < limits.depth then
        local inner = safe(function() return prop:GetStruct() end)
        local shown = value_text(v)
        if shown:sub(1, 1) == "(" or not inner then
            out:write(indent, name, " = ", shown, "\n")
            return
        end
        out:write(indent, name, " {\n")
        dump_fields(out, indent .. "  ", inner, v, depth + 1)
        out:write(indent, "}\n")
    elseif kind == "ArrayProperty" then
        local count = safe(function() return v:GetArrayNum() end)
        out:write(indent, name, " [", tostring(count), "]\n")
        local inner = safe(function() return prop:GetInner() end)
        local inner_kind = inner and safe(function() return inner:GetClass():GetFName():ToString() end)
        pcall(function()
            v:ForEach(function(i, element)
                if i <= limits.elements then
                    local value = safe(function() return element:get() end)
                    if inner_kind == "StructProperty" or inner_kind == "ObjectProperty" then
                        dump_value(out, indent .. "  ", "[" .. i .. "]", inner_kind, inner, value, depth + 1)
                    else
                        out:write(indent, "  [", i, "] ", value_text(value), "\n")
                    end
                end
            end)
        end)
    elseif kind == "MapProperty" and limits.follow then
        -- Only in the deep dump (M.dump_data): key -> value, values expanded.
        local key_prop = safe(function() return prop:GetKeyProp() end)
        local value_prop = safe(function() return prop:GetValueProp() end)
        local value_kind = value_prop and safe(function() return value_prop:GetClass():GetFName():ToString() end)
        out:write(indent, name, " {map}\n")
        local entries = 0
        local ok, err = pcall(function()
            v:ForEach(function(key, value)
                entries = entries + 1
                if entries <= limits.elements then
                    local key_text = value_text(safe(function() return key:get() end))
                    local value_object = safe(function() return value:get() end)
                    -- UE4SS may not give the value property; a struct value then
                    -- names its type ("ScriptStruct /Script/Minimap.MinimapInfo"),
                    -- which is enough to find its fields.
                    local struct_path = not value_kind and value_text(value_object):match("^%-> ScriptStruct (%S+)")
                    local struct = struct_path and safe(function() return StaticFindObject(struct_path) end)
                    if value_kind then
                        dump_value(out, indent .. "  ", "[" .. key_text .. "]", value_kind, value_prop, value_object, depth + 1)
                    elseif struct and safe(function() return struct:IsValid() end) then
                        out:write(indent, "  [", key_text, "] {\n")
                        dump_fields(out, indent .. "    ", struct, value_object, depth + 1)
                        out:write(indent, "  }\n")
                    else
                        out:write(indent, "  [", key_text, "] = ", value_text(value_object), "\n")
                    end
                end
            end)
        end)
        out:write(indent, "  (", entries, " entries", ok and "" or (", read failed: " .. tostring(err):sub(1, 160)),
            key_prop and "" or ", key type unknown", ")\n")
    elseif kind == "MapProperty" or kind == "SetProperty" then
        out:write(indent, name, " <", kind, ", not read>\n")
    elseif kind == "ObjectProperty" and limits.follow and depth < limits.depth then
        local full = safe(function() return v:GetFullName() end)
        local address = safe(function() return v:GetAddress() end)
        if full and full:find(limits.follow, 1, true) and address and not visited[address] then
            visited[address] = true
            out:write(indent, name, " -> ", full, " {\n")
            dump_fields(out, indent .. "  ", v:GetClass(), v, depth + 1)
            out:write(indent, "}\n")
        else
            out:write(indent, name, " = ", value_text(v), "\n")
        end
    else
        out:write(indent, name, " = ", value_text(v), "\n")
    end
end

local function dump_object(out, label, object)
    if not object or not safe(function() return object:IsValid() end) then
        out:write("# ", label, ": not found\n")
        return
    end
    out:write("# ", label, ": ", object:GetFullName(), "\n")
    out:write("#   class ", safe(function() return object:GetClass():GetFullName() end) or "?", "\n")
    pcall(function() visited[object:GetAddress()] = true end)
    dump_fields(out, "    ", object:GetClass(), object, 0)
    out:flush()
end

-- What the game uses to turn world positions into map pixels.
local function dump_config(out, map_widget)
    out:write("\n# ===== CONFIG =====\n")
    dump_object(out, "player minimap component", safe(function() return map_widget.PlayerMinimapComp end))

    local config = StaticFindObject("/Script/Afterimage.MinimapConfig")
    out:write("# struct MinimapConfig fields:\n")
    if config and safe(function() return config:IsValid() end) then
        each_property(config, function(p)
            out:write("    ", p:GetFName():ToString(), " : ", p:GetClass():GetFName():ToString(), "\n")
        end)
    end

    local rt = StaticFindObject("/Game/Assets/Minimap/Render/MinimapFinalRT.MinimapFinalRT")
    out:write("# MinimapFinalRT size: ", tostring(safe(function() return rt.SizeX end)), " x ",
        tostring(safe(function() return rt.SizeY end)), "\n")

    for _, field in ipairs({ "DT_MapConfig", "DropItemInfo" }) do
        local dt = safe(function() return map_widget[field] end)
        out:write("# data table ", field, ": ", tostring(dt and safe(function() return dt:GetFullName() end)), "\n")
        if dt then
            local rows = 0
            local ok, err = pcall(function()
                dt:ForEachRow(function(row_name, row)
                    rows = rows + 1
                    if rows <= 200 then
                        out:write("  row ", tostring(safe(function() return row_name:ToString() end) or row_name), "\n")
                        if config and field == "DT_MapConfig" then
                            each_property(config, function(p)
                                local n = p:GetFName():ToString()
                                dump_value(out, "    ", n, p:GetClass():GetFName():ToString(), p,
                                    safe(function() return row[n] end), 0)
                            end)
                        end
                    end
                end)
            end)
            out:write("#   ForEachRow: ", ok and (rows .. " rows") or ("failed: " .. tostring(err)), "\n")
            if not ok or rows == 0 then
                local names = {}
                local ok2, err2 = pcall(function()
                    local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
                    lib:GetDataTableRowNames(dt, names)
                end)
                out:write("#   GetDataTableRowNames: ", ok2 and (#names .. " names") or ("failed: " .. tostring(err2)), "\n")
                for i, n in ipairs(names) do
                    if i <= 200 then
                        out:write("  name ", value_text(n), "\n")
                    end
                end
            end
        end
    end
    out:flush()
end

function M.run(log, player, done)
    local out = io.open(OUT_FILE, "w")
    local lines = 0
    local panels = {}  -- { widget, children }

    local function dump(w, depth, seen)
        if lines >= MAX_LINES or seen[w:GetAddress()] then
            return
        end
        seen[w:GetAddress()] = true
        local line, class_name = describe(w)
        out:write(string.rep("  ", depth), line, "\n")
        lines = lines + 1
        local children = children_of(w)
        if class_name == "CanvasPanel" then
            panels[#panels + 1] = { widget = w, count = #children }
        end
        for _, child in ipairs(children) do
            dump(child, depth + 1, seen)
        end
    end

    local before = visible_top_widgets()
    local names = {}
    for name in pairs(before) do
        names[#names + 1] = name
    end
    table.sort(names)
    out:write("# on screen before the map: ", #names, "\n")
    for _, name in ipairs(names) do
        out:write("#   ", name, "\n")
    end
    out:flush()

    log("ACTION: open the in-game map now and leave it open until told to close it")
    local waited, stable, last_key = 0, 0, nil

    local function finish_marker(marker)
        ExecuteInGameThreadWithDelay(MARKER_SHOW_MS, function()
            if marker then
                out:write("\n# marker still valid after ", MARKER_SHOW_MS / 1000, " s: ",
                    tostring(safe(function() return marker:IsValid() end)), ", visible: ",
                    tostring(safe(function() return marker:IsVisible() end)), "\n")
            end
            out:close()
            log("ACTION: you can close the map now. Did a magenta 'AP TEST' label show on it? Note where.")
            log("map probe done")
            done()
        end)
    end

    local function add_marker()
        table.sort(panels, function(a, b) return a.count > b.count end)
        local target = panels[1]
        if not target then
            out:write("\n# no CanvasPanel in the map widgets: no marker\n")
            return nil
        end
        out:write("\n# marker target: ", target.widget:GetFullName(), " (", target.count, " children)\n")
        local marker = nil
        local ok, err = pcall(function()
            -- Place it on the panel's first child, so it lands inside the drawn map.
            local x, y = 0, 0
            local first = safe(function() return target.widget:GetChildAt(0) end)
            local p = first and safe(function() return first.Slot:GetPosition() end)
            if p then
                x, y = p.X, p.Y
            end
            marker = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), target.widget)
            local slot = target.widget:AddChildToCanvas(marker)
            slot:SetAutoSize(true)
            slot:SetPosition({ X = x, Y = y })
            slot:SetZOrder(1000)
            marker:SetText(FText("AP TEST"))
            pcall(function()
                marker:SetColorAndOpacity({ SpecifiedColor = { R = 1, G = 0, B = 1, A = 1 }, ColorUseRule = 0 })
            end)
            out:write("# marker added at ", num(x), ",", num(y), "\n")
        end)
        if not ok then
            out:write("# marker FAILED: ", tostring(err), "\n")
            marker = nil
        end
        out:flush()
        return marker
    end

    local function poll()
        waited = waited + POLL_MS / 1000
        local now = visible_top_widgets()
        local new, key = {}, {}
        for name, w in pairs(now) do
            if not before[name] then
                new[#new + 1] = w
                key[#key + 1] = name
            end
        end
        table.sort(key)
        local joined = table.concat(key, "|")
        if #new > 0 and joined == last_key then
            stable = stable + 1
        else
            stable = 0
        end
        last_key = joined
        if #new == 0 or stable < STABLE_POLLS then
            if waited >= WAIT_FOR_MAP_S then
                out:write("# no new widget appeared within ", WAIT_FOR_MAP_S, " s\n")
                out:close()
                log("map probe: the map never appeared")
                log("map probe done")
                done()
                return
            end
            ExecuteInGameThreadWithDelay(POLL_MS, poll)
            return
        end

        local at = safe(function() return player:K2_GetActorLocation() end)
        out:write("\n# player world position: ", at and (num(at.X) .. "," .. num(at.Y) .. "," .. num(at.Z)) or "?", "\n")
        local seen = {}
        for _, w in ipairs(new) do
            out:write("\n# NEW WIDGET ", w:GetFullName(), "\n")
            dump_properties(out, w)
            dump(w, 1, seen)
        end
        out:write("\n# ", lines, " widget lines", lines >= MAX_LINES and " (truncated)" or "", "\n")
        out:flush()
        for _, w in ipairs(new) do
            if safe(function() return w.PlayerMinimapComp end) ~= nil then
                local ok, err = pcall(dump_config, out, w)
                if not ok then
                    out:write("# config dump failed: ", tostring(err), "\n")
                end
            end
        end
        log(string.format("map probe: %d new widgets, %d lines dumped, %d canvas panels", #new, lines, #panels))
        finish_marker(add_marker())
    end

    ExecuteInGameThreadWithDelay(POLL_MS, poll)
end

-- Experiment mode "mapcal": fully automatic map calibration. The runner opens
-- the map (log "PRESS: M"; UIOpenMap is M in the saved key bindings),
-- screenshots it (log "SCREENSHOT: <name>") and closes it ("PRESS: Escape").
-- Two snapshots of the view, at the default zoom and after one press of the
-- map's zoom key (D), go to AfterimageAP_mapcal.txt: zoom values, the view
-- position, the player's world position, the area labels and layout widgets.
-- Each snapshot also places a magenta "+" on every check in view, using
-- to_panel(), and is screenshotted, so the transform can be checked by eye.
local CAL_LAYOUT = { "SizeBox_Map", "CanvasPanel_Holder", "ScaleBox_ScrollingBox", "SizeBox_MapSize", "Overlay",
    "MinimapImg", "MapNamePanel", "CustomSignPanel", "Image_Focus" }

local function geometry_text(w)
    local lib = StaticFindObject("/Script/UMG.Default__SlateBlueprintLibrary")
    local geometry = safe(function() return w:GetCachedGeometry() end)
    if not lib or not geometry then
        return "geometry=?"
    end
    local size = safe(function() return lib:GetLocalSize(geometry) end)
    local abs_size = safe(function() return lib:GetAbsoluteSize(geometry) end)
    local origin = safe(function() return lib:LocalToAbsolute(geometry, { X = 0, Y = 0 }) end)
    return "local_size=" .. vec2(size) .. " abs_size=" .. vec2(abs_size) .. " abs_origin=" .. vec2(origin)
end

local function find_open_map()
    for _, w in ipairs(FindAllOf("Minimap_C") or {}) do
        if safe(function() return w:IsValid() and w:IsInViewport() end) then
            return w
        end
    end
    return nil
end

local function snapshot(out, tag, map, player)
    out:write("\n=== SNAP ", tag, "\n")
    local at = safe(function() return player:K2_GetActorLocation() end)
    out:write("player\t", at and (num(at.X) .. "\t" .. num(at.Z)) or "?", "\n")
    for _, field in ipairs({ "CurrentZoom", "TargetZoom", "MinZoom", "MaxZoom", "ZoomingEnabled", "ScrollingEnabled" }) do
        out:write("map\t", field, "\t", tostring(safe(function() return map[field] end)), "\n")
    end
    local comp = safe(function() return map.PlayerMinimapComp end)
    for _, field in ipairs({ "PreviewLoc", "CacheLoc", "MinimapUIScale" }) do
        out:write("comp\t", field, "\t", value_text(safe(function() return comp[field] end)), "\n")
    end
    for _, name in ipairs(CAL_LAYOUT) do
        local w = safe(function() return map[name] end)
        if w and safe(function() return w:IsValid() end) then
            local line = describe(w)
            local width = safe(function() return w.WidthOverride end)
            local height = safe(function() return w.HeightOverride end)
            out:write("layout\t", line, width and ("\toverride=" .. num(width) .. "," .. num(height)) or "",
                "\t", geometry_text(w), "\n")
        else
            out:write("layout\t", name, "\tnot found\n")
        end
    end
    local panel = safe(function() return map.MapNamePanel end)
    local count = panel and safe(function() return panel:GetChildrenCount() end) or 0
    for i = 0, count - 1 do
        local label = safe(function() return panel:GetChildAt(i) end)
        if label then
            local p = safe(function() return label.Slot:GetPosition() end)
            local text = safe(function() return label:GetText():ToString() end) or ""
            out:write("label\t", i + 1, "\t", vec2(p), "\t", tostring(safe(function() return label:GetVisibility() end)),
                "\t", (text:gsub("[\r\n\t]", " ")), "\n")
        end
    end
    out:flush()
end

-- World -> map panel. The map is a MAP_SCALE copy of the world (map px per
-- world unit, from MinimapCollection), shown at CurrentZoom, with screen y
-- against world Z. MapNamePanel is PANEL_W x PANEL_H (SizeBox_MapSize) and
-- shows the view centre in its middle; when the map opens the view centre is
-- the player. Fitted from a screenshot on 2026-11-17 (rooms of Lv1 against
-- the drawn map); mode "mapcal" checks it with markers.
local MAP_SCALE = 0.04
local PANEL_W, PANEL_H = 1472, 828

local function to_panel(x, z, centre_x, centre_z, zoom)
    local k = MAP_SCALE * zoom
    return PANEL_W / 2 + (x - centre_x) * k, PANEL_H / 2 - (z - centre_z) * k
end

-- Puts a magenta "+" on every catalogued check that falls inside the panel,
-- replacing the markers from an earlier call. Returns the number placed.
local markers = {}
local function place_markers(out, map, player, tag)
    for _, m in ipairs(markers) do
        pcall(function() m:RemoveFromParent() end)
    end
    markers = {}
    local panel = map.MapNamePanel
    local zoom = map.CurrentZoom
    local at = player:K2_GetActorLocation()
    local text_class = StaticFindObject("/Script/UMG.TextBlock")
    local placed = 0
    for key, pos in pairs(require("data_positions")) do
        local px, py = to_panel(pos[1], pos[2], at.X, at.Z, zoom)
        if px >= 0 and px <= PANEL_W and py >= 0 and py <= PANEL_H then
            local ok, err = pcall(function()
                local marker = StaticConstructObject(text_class, panel)
                local slot = panel:AddChildToCanvas(marker)
                slot:SetAutoSize(true)
                slot:SetAlignment({ X = 0.5, Y = 0.5 })
                slot:SetPosition({ X = px, Y = py })
                slot:SetZOrder(1000)
                marker:SetText(FText("+"))
                marker:SetColorAndOpacity({ SpecifiedColor = { R = 1, G = 0, B = 1, A = 1 }, ColorUseRule = 0 })
                markers[#markers + 1] = marker
            end)
            out:write("marker\t", tag, "\t", key, "\t", num(px), "\t", num(py), ok and "" or ("\tFAILED " .. tostring(err)), "\n")
            if ok then
                placed = placed + 1
            end
        end
    end
    out:write("# ", tag, ": ", placed, " markers at zoom ", tostring(zoom), ", centre ", num(at.X), ",", num(at.Z), "\n")
    out:flush()
    return placed
end

local function view_text(map)
    local comp = safe(function() return map.PlayerMinimapComp end)
    local parts = {}
    for _, field in ipairs({ "PreviewLoc", "CacheLoc" }) do
        local v = safe(function() return comp[field] end)
        parts[#parts + 1] = field .. "=" .. vec2(v)
    end
    return table.concat(parts, " ")
end

function M.calibrate(log, player, done)
    local out = io.open("AfterimageAP_mapcal.txt", "w")
    local function finish(message)
        for _, m in ipairs(markers) do
            pcall(function() m:RemoveFromParent() end)
        end
        markers = {}
        out:close()
        log("map calibration " .. message)
        done()
    end
    local function after(ms, fn) ExecuteInGameThreadWithDelay(ms, fn) end

    -- A loaded save starts with the player resting at the save point (no HUD,
    -- hourglass over the head), and the map key does nothing until the player
    -- moves. A short step right ends the rest, as for a real player.
    local polls = 0
    local function wait_open()
        polls = polls + 1
        local map = find_open_map()
        if not map then
            if polls == 3 then
                log("SCREENSHOT: mapcal_after_press")  -- what the screen shows if the map did not open
            end
            if polls == 12 then
                log("PRESS: M")  -- once more, in case the first press went elsewhere
            end
            if polls >= 25 then
                return finish("failed: the map did not open")
            end
            return after(1000, wait_open)
        end
        after(3000, function()
            snapshot(out, "default", map, player)
            out:write("view\tdefault\t", view_text(map), "\n")
            local ok, err = pcall(place_markers, out, map, player, "default")
            if not ok then
                out:write("# markers FAILED: ", tostring(err), "\n")
            end
            after(1000, function()
                log("SCREENSHOT: mapcal_default")
                -- Zoom with the map's own key (A / D), then re-place the markers.
                after(1000, function()
                    log("PRESS: D")
                    after(4000, function()
                        snapshot(out, "zoomed", map, player)
                        out:write("view\tzoomed\t", view_text(map), "\n")
                        pcall(place_markers, out, map, player, "zoomed")
                        after(1000, function()
                            log("SCREENSHOT: mapcal_zoomed")
                            after(2000, function()
                                log("PRESS: Escape")
                                after(2000, function() finish("written") end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end
    log("PRESS: Right")
    after(3000, function()
        log("SCREENSHOT: mapcal_after_move")
        after(1000, function()
            log("PRESS: M")
            after(1000, wait_open)
        end)
    end)
end

-- Experiment mode "mapoverlay": the live overlay (map_overlay.lua, every
-- location) against panning and zooming. The runner opens the map, holds the
-- arrow keys (log "HOLD: <key> <ms>") and the zoom keys, and screenshots
-- after each step, including one mid-zoom. Status lines go to
-- AfterimageAP_overlay.txt.
function M.overlay_test(log, player, done)
    local overlay = require("map_overlay")
    -- With an AfterimageAP_missing.txt next to the exe, show what it lists
    -- (the client's path); otherwise every location.
    local listed = io.open("AfterimageAP_missing.txt", "r")
    if listed then
        listed:close()
    end
    overlay.start({ show_all = not listed })
    local out = io.open("AfterimageAP_overlay.txt", "w")
    local function after(ms, fn) ExecuteInGameThreadWithDelay(ms, fn) end
    local function note(tag)
        local map = find_open_map()
        local p = map and safe(function() return map.PlayerMinimapComp.PreviewLoc end)
        local at = safe(function() return player:K2_GetActorLocation() end)
        -- The game's own area-name labels (not our TextBlock markers): how
        -- many have text and are drawn, and the first one's opacity.
        local labels, shown, opacity = 0, 0, "-"
        local panel = map and safe(function() return map.MapNamePanel end)
        local count = panel and safe(function() return panel:GetChildrenCount() end) or 0
        for i = 0, count - 1 do
            local w = safe(function() return panel:GetChildAt(i) end)
            local class = w and safe(function() return w:GetClass():GetFName():ToString() end) or ""
            if class ~= "TextBlock" then
                local text = safe(function() return w:GetText():ToString() end) or ""
                if text ~= "" then
                    labels = labels + 1
                    local vis = safe(function() return w:GetVisibility() end)
                    local alpha = safe(function() return w:GetRenderOpacity() end)
                    if vis ~= 1 and vis ~= 2 and (alpha or 1) > 0.01 then
                        shown = shown + 1
                    end
                    if opacity == "-" then
                        opacity = num(alpha) .. " vis " .. tostring(vis)
                    end
                end
            end
        end
        out:write(tag, "\t", overlay.status(), "\tPreviewLoc=", vec2(p),
            "\tplayer=", at and (num(at.X) .. "," .. num(at.Z)) or "?",
            "\tgame labels ", shown, "/", labels, " first ", opacity, "\n")
        out:flush()
    end
    -- Zoom samples: TargetZoom / CurrentZoom every 40 ms for 1.6 s after a
    -- zoom key line, to see whether TargetZoom moves in one go or while the
    -- key is held, and whether CurrentZoom (the lagging value) moves at all.
    local function sample_zoom(tag)
        local t, n = 0, 0
        local function one()
            local map = find_open_map()
            local tz = map and safe(function() return map.TargetZoom end)
            local cz = map and safe(function() return map.CurrentZoom end)
            local f4 = function(v) return type(v) == "number" and string.format("%.4f", v) or tostring(v) end
            out:write(string.format("zoomsample %s t=%d target=%s current=%s clock=%.3f\n", tag, t, f4(tz), f4(cz), os.clock()))
            n = n + 1
            t = t + 40
            if n < 40 then after(40, one) else out:flush() end
        end
        one()
    end
    -- Steps after the map is open: { log lines, wait ms, tag to note and
    -- screenshot }. The view stays where the map opened (centred on the
    -- player, with locations around her) so markers are on screen at every
    -- zoom at or above the default. A zoom line is followed in the same
    -- write by burst screenshots (<tag>_b1.._b3), which the runner takes
    -- straight after the key press: if the map glides to the new zoom, the
    -- bursts show the markers ahead of it.
    local burst = function(key, tag)
        return "PRESS: " .. key .. "\nSCREENSHOT: ov_" .. tag .. "_b1\nSCREENSHOT: ov_" .. tag
            .. "_b2\nSCREENSHOT: ov_" .. tag .. "_b3"
    end
    local steps = {
        { nil, 3000, "open" },
        { burst("D", "zoom_in_1"), 3000, "zoom_in_1", true },
        { burst("D", "zoom_in_2"), 3000, "zoom_in_2", true },
        { burst("A", "zoom_out_1"), 3000, "zoom_out_1", true },
        { burst("A", "zoom_out_2"), 3000, "zoom_out_2", true },
        { burst("A", "zoom_out_3"), 3000, "zoom_out_3", true },
        { burst("D", "zoom_back_1"), 3000, "zoom_back_1", true },
        { "HOLD: Right 500", 2500, "pan_right" },
        { burst("D", "zoom_in_3"), 3000, "zoom_in_3", true },
        { burst("A", "zoom_out_4"), 3000, "zoom_out_4", true },
        { "HOLD: Left 900", 2500, "pan_left" },
        { burst("D", "zoom_in_4"), 3000, "zoom_in_4", true },
        { burst("D", "zoom_in_5"), 3000, "zoom_in_5", true },
    }
    local function run_step(i)
        local step = steps[i]
        if not step then
            log("PRESS: Escape")
            after(2000, function()
                note("closed")
                out:close()
                log("map overlay test done")
                done()
            end)
            return
        end
        if step[1] then
            log(step[1])
        end
        if step[4] then
            sample_zoom(step[3])
        end
        after(step[2], function()
            note(step[3])
            log("SCREENSHOT: ov_" .. step[3])
            after(1500, function() run_step(i + 1) end)
        end)
    end
    local polls = 0
    local function wait_open()
        polls = polls + 1
        if find_open_map() then
            return run_step(1)
        end
        if polls == 3 then
            log("SCREENSHOT: ov_after_press")
        end
        if polls == 12 then
            log("PRESS: M")
        end
        if polls >= 25 then
            out:close()
            log("map overlay test failed: the map did not open")
            return done()
        end
        after(1000, wait_open)
    end
    -- Input check: the player's position before and after holding Right. If
    -- it changes, keyboard input reaches the character. Then M; after a load
    -- the player rests at the save point and M works only once they moved.
    after(1000, function()
        note("before")
        log("HOLD: Right 400")
        after(2500, function()
            note("after_step")
            log("SCREENSHOT: ov_after_step")
            log("PRESS: M")
            after(1000, wait_open)
        end)
    end)
end

-- Experiment mode "maptracker": the overlay as main.lua starts it (standalone
-- tracker, no randomizer), with checked locations drawn grey. Screenshots:
--   tracker_open         default zoom: coloured "+" undone, grey "x" done
--   tracker_zoom_in      one zoom step in, to judge the grey glyph up close
--   tracker_nocollected  flag word "nocollected": grey markers gone (live)
--   tracker_randomizer   a test AfterimageAP_missing.txt (Lv1 keys,
--                        alternately unchecked / "checked"), only if no
--                        such file existed; removed afterwards
-- Status lines (markers / checked / visible) go to the experiment log. The
-- tracker flag is restored to what it was.
function M.tracker_test(log, done)
    local overlay = require("map_overlay")
    local FLAG, MISSING = "AfterimageAP_tracker.flag", "AfterimageAP_missing.txt"
    local function after(ms, fn) ExecuteInGameThreadWithDelay(ms, fn) end
    local function read(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local text = f:read("a")
        f:close()
        return text
    end
    local function write(path, text)
        local f = io.open(path, "w")
        if f then f:write(text); f:close() end
    end
    local old_flag = read(FLAG)
    local had_missing = read(MISSING) ~= nil
    local function restore_flag()
        if old_flag then write(FLAG, old_flag) else os.remove(FLAG) end
    end
    local function shot(tag)
        log("tracker " .. tag .. ": " .. overlay.status())
        log("SCREENSHOT: tracker_" .. tag)
    end
    -- Rubiwood Desert keys with a map position, half of them "checked".
    local function test_missing_file()
        local positions, locations = require("data_positions"), require("data_locations")
        local keys = {}
        for key, d in pairs(locations) do
            if d.level == "Lv1" and positions[key] then keys[#keys + 1] = key end
        end
        table.sort(keys)
        overlay.accept_session("test\t1")   -- shown on this save without marking it
        local lines = { "AP1\ttest\t1" }
        for i, key in ipairs(keys) do
            lines[#lines + 1] = (i % 2 == 0) and ("checked\t" .. key) or key
        end
        write(MISSING, table.concat(lines, "\n") .. "\n")
        log("test missing file: " .. #keys .. " Lv1 keys, " .. (#keys // 2) .. " checked")
    end
    local steps = {
        function() shot("open") end,
        function() log("PRESS: D") end,
        function() shot("zoom_in") end,
        function() log("PRESS: A"); write(FLAG, (old_flag or "") .. " nocollected\n") end,
        function() shot("nocollected"); restore_flag() end,
        function()
            if had_missing then
                log("tracker randomizer: skipped, an AfterimageAP_missing.txt is already there")
            else
                test_missing_file()
            end
        end,
        function()
            if not had_missing then
                shot("randomizer")
                os.remove(MISSING)
            end
        end,
        function() log("tracker back to standalone: " .. overlay.status()) end,
    }
    local function run_step(i)
        if not steps[i] then
            log("PRESS: Escape")
            return after(2000, done)
        end
        local ok, err = pcall(steps[i])
        if not ok then
            log("tracker step " .. i .. " failed: " .. tostring(err))
            restore_flag()
        end
        after(3000, function() run_step(i + 1) end)   -- the overlay re-reads its files every 2 s
    end
    log("PRESS: Right")   -- ends the rest at the save point; the map key does nothing until then
    after(3000, function() log("PRESS: M") end)
    after(8000, function() run_step(1) end)
end

-- Experiment mode "mapdata": no map needed. Dumps the player's minimap
-- component and the minimap data assets it references (MinimapCollection,
-- MinimapUIInfoCollection), deep, to AfterimageAP_mapdata.txt. The per-room
-- map layout (world area -> map rectangle) is expected to live there.
function M.dump_data(log, player, done)
    limits = { depth = 7, elements = 4000, follow = "/Game/Assets/Minimap" }
    visited = {}
    local out = io.open("AfterimageAP_mapdata.txt", "w")
    local comp = safe(function() return player.Minimap end)
    if not comp or not safe(function() return comp:IsValid() end) then
        comp = (FindAllOf("MinimapComponent") or {})[1]
    end
    local at = safe(function() return player:K2_GetActorLocation() end)
    out:write("# player world position: ", at and (num(at.X) .. "," .. num(at.Y) .. "," .. num(at.Z)) or "?", "\n")
    local ok, err = pcall(function()
        -- The component itself without following references: its collections
        -- are dumped in full right after.
        limits.follow = nil
        dump_object(out, "minimap component", comp)
        limits.follow = "/Game/Assets/Minimap"
        for _, field in ipairs({ "MinimapCollection", "MinimapUIInfoCollection" }) do
            out:write("\n")
            dump_object(out, field, safe(function() return comp[field] end))
        end
    end)
    if not ok then
        out:write("# dump failed: ", tostring(err), "\n")
    end
    out:close()
    log("map data dump " .. (ok and "written" or "failed: " .. tostring(err)))
    done()
end

-- Runs fns[i] = { delay before it (ms), function } one after another, then
-- closes the map and calls done. A failing step is logged and skipped.
local function run_steps(log, tag, steps, done, cleanup)
    local function run_step(i)
        local step = steps[i]
        if not step then
            if cleanup then pcall(cleanup) end
            log("PRESS: Escape")
            return ExecuteInGameThreadWithDelay(2000, done)
        end
        ExecuteInGameThreadWithDelay(step[1], function()
            local ok, err = pcall(step[2])
            if not ok then
                log(tag .. " step " .. i .. " failed: " .. tostring(err))
            end
            run_step(i + 1)
        end)
    end
    run_step(1)
end

-- Experiment mode "maplabels": the overlay's kind markers, legend and labels
-- (map_overlay.lua) in the default and the vanilla mode, at the default zoom
-- and zoomed in, with a screenshot and the shown labels after each step:
--   labels_default    default mode, zoom 1.2: kind glyphs, legend (title
--                     "Locations" or "Archipelago"), at most one label (the
--                     marker nearest the view centre, within 60 px)
--   labels_pan        after panning right: the focus label moved to another marker
--   labels_vanilla    flag "vanilla", zoom 1.2: title "Vanilla items", the focus
--                     label a vanilla item name (as in the default mode)
--   labels_vanilla_zoom   4 x D (zoom ~2.2): every visible marker labelled
--   labels_default_zoom   flag back: the same labels (item names in both modes;
--                     legend title back to "Locations" / "Archipelago")
--   labels_back       4 x A (zoom ~1.2): one label or none
--   labels_overview   3 x A more (area-name overview): no marker, label or legend
-- Status lines and "label <key> = <text>" lines go to the experiment log. The
-- tracker flag is restored to what it was.
function M.labels_test(log, done)
    local overlay = require("map_overlay")
    local FLAG = "AfterimageAP_tracker.flag"
    local function read(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local text = f:read("a")
        f:close()
        return text
    end
    local function write(path, text)
        local f = io.open(path, "w")
        if f then f:write(text); f:close() end
    end
    local old_flag = read(FLAG)
    local function restore_flag()
        if old_flag then write(FLAG, old_flag) else os.remove(FLAG) end
    end
    local function shot(tag)
        log("labels " .. tag .. ": " .. overlay.status())
        for _, line in ipairs(overlay.labels_shown()) do
            log("  label " .. line)
        end
        log("  legend " .. table.concat(overlay.legend_shown(), " | "))
        log("SCREENSHOT: labels_" .. tag)
    end
    local function press(key) return { 700, function() log("PRESS: " .. key) end } end
    local steps = {
        { 8000, function() shot("default") end },
        { 500, function() log("HOLD: Right 400") end },
        { 1500, function() shot("pan") end },
        { 200, function() write(FLAG, (old_flag or "") .. " vanilla\n") end },
        { 3000, function() shot("vanilla") end },
        press("D"), press("D"), press("D"), press("D"),
        { 1500, function() shot("vanilla_zoom") end },
        { 200, restore_flag },
        { 3000, function() shot("default_zoom") end },
        press("A"), press("A"), press("A"), press("A"),
        { 1500, function() shot("back") end },
        press("A"), press("A"), press("A"),
        { 1500, function() shot("overview") end },
    }
    log("PRESS: Right")   -- ends the rest at the save point; the map key does nothing until then
    ExecuteInGameThreadWithDelay(3000, function() log("PRESS: M") end)
    run_steps(log, "labels", steps, done, restore_flag)
end

-- Experiment mode "mapitemicons": the overlay's item icons (map_overlay.lua,
-- ICON_PX) as main.lua starts it, on whatever save is loaded (meant for a
-- copy of GameSave1, the full map), with a screenshot, the status, the icon
-- report (which frames are loaded) and the overlay's cost after each step:
--   icons_default        zoom 1.2, the save's own unchecked locations
--   icons_dense          a test list with every location unchecked (the
--                        densest the map gets: a new save in vanilla mode)
--   icons_dense_a / _b   panned left to two denser stretches (world delta
--                        seconds sampled every 100 ms during each pan)
--   icons_dense_a_glyphs / _b_glyphs  the same with "noicons" (as before)
--   icons_dense_b_zoom   4 x D (zoom ~2.2), icons; _glyphs the same, glyphs
--   icons_zoom_pan       icons, panned right while zoomed
--   icons_back           4 x A (zoom ~1.2)
-- The tracker flag and the missing file are restored to what they were.
function M.item_icons_test(log, done)
    local overlay = require("map_overlay")
    local FLAG, LIST = "AfterimageAP_tracker.flag", "AfterimageAP_missing.txt"
    local function read(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local text = f:read("a")
        f:close()
        return text
    end
    local function write(path, text)
        local f = io.open(path, "w")
        if f then f:write(text); f:close() end
    end
    local old_flag, old_list = read(FLAG), read(LIST)
    local function restore()
        if old_flag then write(FLAG, old_flag) else os.remove(FLAG) end
        if old_list then write(LIST, old_list) else os.remove(LIST) end
    end
    local deltas = {}
    local sampling = false
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local function sample()
        if not sampling then return end
        local pc = FindFirstOf("PlayerController")
        local d = safe(function() return gs:GetWorldDeltaSeconds(pc) end)
        if type(d) == "number" then deltas[#deltas + 1] = d end
        ExecuteInGameThreadWithDelay(100, sample)
    end
    local function shot(tag)
        log("icons " .. tag .. ": " .. overlay.status())
        log("  " .. overlay.icon_report())
        log("  perf " .. overlay.perf())
        local shown = overlay.icons_shown()
        for i = 1, math.min(#shown, 12) do
            log("  icon " .. shown[i])
        end
        for _, line in ipairs(overlay.labels_shown()) do
            log("  label " .. line)
        end
        log("  legend " .. table.concat(overlay.legend_shown(), " | "))
        log("SCREENSHOT: icons_" .. tag)
    end
    local function dense_list()
        local keys = {}
        for key in pairs(require("data_positions")) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
        overlay.accept_session("icontest\t1")
        write(LIST, "AP1\ticontest\t1\n" .. table.concat(keys, "\n") .. "\n")
    end
    local function press(key) return { 700, function() log("PRESS: " .. key) end } end
    local function icons_off() write(FLAG, (old_flag or "") .. " noicons\n") end
    local function icons_on() if old_flag then write(FLAG, old_flag) else os.remove(FLAG) end end
    -- A pan with the overlay's cost and the world's delta seconds sampled.
    local function pan(key, ms)
        return { 500, function()
            overlay.perf()
            deltas = {}
            sampling = true
            sample()
            log("HOLD: " .. key .. " " .. ms)
        end }
    end
    local function pan_done(tag)
        return { 0, function()
            sampling = false
            local n, sum, max = #deltas, 0, 0
            for _, d in ipairs(deltas) do sum = sum + d; max = math.max(max, d) end
            log(string.format("  world delta during the pan: %d samples, avg %.1f ms, max %.1f ms",
                n, n > 0 and sum / n * 1000 or 0, max * 1000))
            shot(tag)
        end }
    end
    -- Every loaded atlas frame / texture whose name looks like money, a
    -- balm or a potion, any path (the mapicons list kept only map and item
    -- icon paths): candidates for the currency (dew) icon. Written to
    -- AfterimageAP_iconlist.txt; the candidates are shown in a row with a
    -- number each (screenshot icons_candidates).
    local candidates, cand_widgets = {}, {}
    local function list_textures(tag)
        local out = io.open("AfterimageAP_iconlist.txt", tag == "closed" and "w" or "a")
        local n = 0
        for _, class in ipairs({ "VtaSlateTexture", "Texture2D", "PaperSprite" }) do
            for _, obj in ipairs(FindAllOf(class) or {}) do
                local name = safe(function() return obj:GetFullName() end) or "?"
                local lower = name:lower()
                if out then out:write(tag, "\t", name, "\n") end
                n = n + 1
                local short = lower:match("([^/%.]+)$") or lower
                local item_frame = lower:find("/itemicon/", 1, true)
                local money = short:find("coin") or short:find("money") or short:find("dew") or short:find("gold")
                    or short:find("currenc") or short:find("cash")
                local balm = short:find("bottle") or short:find("balm")
                if tag == "map" and class ~= "Texture2D" and ((money and not item_frame) or balm)
                    and #candidates < 14 then
                    candidates[#candidates + 1] = { class = class, path = name:match("^%S+%s+(.+)$") }
                end
            end
        end
        if out then out:close() end
        log(string.format("  textures listed (%s): %d", tag, n))
    end
    local function show_candidates()
        local map = find_open_map()
        local panel = map and map.MapNamePanel
        if not panel then return end
        local image_class = StaticFindObject("/Script/UMG.Image")
        local text_class = StaticFindObject("/Script/UMG.TextBlock")
        for i, c in ipairs(candidates) do
            local obj = StaticFindObject(c.path)
            local ok, err = pcall(function()
                local x, y = 736 - 7 * 52 + (i - 1) % 14 * 52, 250
                local img = StaticConstructObject(image_class, panel)
                local slot = panel:AddChildToCanvas(img)
                slot:SetAutoSize(false)
                slot:SetSize({ X = 40, Y = 40 })
                slot:SetAlignment({ X = 0.5, Y = 0.5 })
                slot:SetZOrder(1003)
                slot:SetPosition({ X = x, Y = y })
                img:SetBrushResourceObject(obj)
                img:SetVisibility(3)
                local t = StaticConstructObject(text_class, panel)
                local ts = panel:AddChildToCanvas(t)
                ts:SetAutoSize(true)
                ts:SetAlignment({ X = 0.5, Y = 0 })
                ts:SetZOrder(1003)
                ts:SetPosition({ X = x, Y = y + 24 })
                t:SetText(FText(tostring(i)))
                t:SetVisibility(3)
                cand_widgets[#cand_widgets + 1] = img
                cand_widgets[#cand_widgets + 1] = t
            end)
            log(string.format("  candidate %d %s %s: %s", i, c.class, c.path, ok and "shown" or ("failed: " .. tostring(err))))
        end
        -- (Run 3 drew coin rocks with the first of these, a money bag; the
        -- dew is ST_HUD1_Button_Gold, now map_overlay.lua NAMED_FRAMES.dew.)
    end
    local function hide_candidates()
        for _, w in ipairs(cand_widgets) do
            pcall(function() w:RemoveFromParent() end)
        end
        cand_widgets = {}
    end
    -- After a long HOLD the screen kept a stale frame (2026-11-19 run 2:
    -- the shot after each pan equalled the next one, taken 3 s later), so
    -- a short press brings the game to the front first.
    local function settle() return { 300, function() log("PRESS: Up") end } end
    list_textures("closed")
    log("  " .. overlay.load_report())
    -- From the GameSave1 copy's start (Lv18, map px ~9990, 4490), left to
    -- the denser rooms near (7700, 4310), then (4100, 3970) (by
    -- data_positions: 26 and 28 locations in 80 % of a view at zoom 1.2).
    local steps = {
        { 8000, function() log("  " .. overlay.load_report()); list_textures("map"); shot("default") end },
        { 300, show_candidates },
        { 1500, function() log("SCREENSHOT: icons_candidates") end },
        { 1500, hide_candidates },
        { 200, dense_list },
        { 3000, function() shot("dense") end },
        pan("Left", 3800), { 5300, function() end }, settle(), { 1500, function() end }, pan_done("dense_a"),
        { 200, icons_off },
        { 3000, function() shot("dense_a_glyphs") end },
        { 200, icons_on },
        pan("Left", 6000), { 7500, function() log("HOLD: Up 600") end }, { 2100, function() end },
        settle(), { 1500, function() end }, pan_done("dense_b"),
        { 200, icons_off },
        { 3000, function() shot("dense_b_glyphs") end },
        { 200, icons_on },
        { 3000, function() log("  icons back on") end },
        press("D"), press("D"), press("D"), press("D"),
        { 1500, function() shot("dense_b_zoom") end },
        { 200, icons_off },
        { 3000, function() shot("dense_b_zoom_glyphs") end },
        { 200, icons_on },
        { 2500, function() end },
        pan("Right", 800), { 2300, function() end }, settle(), { 1500, function() end }, pan_done("zoom_pan"),
        press("A"), press("A"), press("A"), press("A"),
        { 1500, function() shot("back") end },
    }
    log("PRESS: Right")   -- ends the rest at the save point; the map key does nothing until then
    ExecuteInGameThreadWithDelay(3000, function() log("PRESS: M") end)
    run_steps(log, "icons", steps, done, function() hide_candidates(); restore() end)
end

-- Experiment mode "mapicons": can the overlay draw the game's own textures
-- instead of text glyphs? Nothing in the overlay depends on it.
-- 1. Lists the loaded textures whose path looks like a map or item icon
--    (Texture2D, VtaSlateTexture) to AfterimageAP_mapicons.txt.
-- 2. With the map open, adds one UMG Image per candidate to MapNamePanel,
--    left of the view centre in a row, 40 px apart: SetBrushFromTexture for a
--    Texture2D, SetBrushResourceObject for an atlas frame (VtaSlateTexture),
--    logging each call's result; screenshot "mapicons", then removes them.
-- Candidates: the minimap component's own sign icons (Icon_Shop,
-- Icon_Archive, Icon_Death: Texture2D, known paths), a map atlas frame
-- (ST_Map_Icon_Star) and the first item icon frame found loaded.
-- Risk: a wrong brush call could crash the game (UE4SS cannot catch that);
-- run it on its own, on slot 4.
function M.icon_probe(log, done)
    local out = io.open("AfterimageAP_mapicons.txt", "w")
    local item_frame = nil
    for _, class in ipairs({ "Texture2D", "VtaSlateTexture" }) do
        local n, kept = 0, 0
        for _, obj in ipairs(FindAllOf(class) or {}) do
            n = n + 1
            local name = safe(function() return obj:GetFullName() end) or "?"
            local lower = name:lower()
            if lower:find("/map/", 1, true) or lower:find("itemicon", 1, true) or lower:find("treasure", 1, true)
                or lower:find("chest", 1, true) or lower:find("boss", 1, true) or lower:find("minimap", 1, true) then
                kept = kept + 1
                if out then out:write(class, "\t", name, "\n") end
                if class == "VtaSlateTexture" and not item_frame and lower:find("itemicon", 1, true) then
                    item_frame = name:match("^%S+%s+(.+)$")
                end
            end
        end
        log(string.format("mapicons: %s loaded %d, icon-like %d", class, n, kept))
    end
    if out then out:close() end
    local candidates = {
        { "Texture2D", "/Game/Assets/UMG/TextureAtlases/Map/Sign/Icon_Shop.Icon_Shop" },
        { "Texture2D", "/Game/Assets/UMG/TextureAtlases/Map/Sign/Icon_Archive.Icon_Archive" },
        { "Texture2D", "/Game/Assets/UMG/TextureAtlases/Map/Sign/Icon_Death.Icon_Death" },
        { "VtaSlateTexture", "/Game/Assets/UMG/TextureAtlases/Map/Frames/ST_Map_Icon_Star.ST_Map_Icon_Star" },
    }
    if item_frame then
        candidates[#candidates + 1] = { "VtaSlateTexture", item_frame }
    end
    local added = {}
    local function add_images()
        local map = find_open_map()
        if not map then
            log("mapicons: map not open")
            return
        end
        local panel = map.MapNamePanel
        local image_class = StaticFindObject("/Script/UMG.Image")
        for i, c in ipairs(candidates) do
            local obj = StaticFindObject(c[2])
            if not obj or not safe(function() return obj:IsValid() end) then
                log("mapicons: not loaded: " .. c[2])
            else
                local ok, err = pcall(function()
                    local img = StaticConstructObject(image_class, panel)
                    local slot = panel:AddChildToCanvas(img)
                    slot:SetAutoSize(false)
                    slot:SetSize({ X = 32, Y = 32 })
                    slot:SetAlignment({ X = 0.5, Y = 0.5 })
                    slot:SetZOrder(1002)
                    slot:SetPosition({ X = 736 - 40 * i, Y = 414 })
                    if c[1] == "Texture2D" then
                        img:SetBrushFromTexture(obj, false)
                    else
                        img:SetBrushResourceObject(obj)
                    end
                    img:SetVisibility(3)
                    added[#added + 1] = img
                end)
                log(string.format("mapicons: %d %s %s: %s", i, c[1], c[2], ok and "ok" or ("failed: " .. tostring(err))))
            end
        end
    end
    local steps = {
        { 8000, add_images },
        { 1500, function() log("SCREENSHOT: mapicons") end },
        { 1000, function() log("PRESS: D"); end },
        { 1500, function() log("SCREENSHOT: mapicons_zoom") end },
        -- The runner takes the screenshot when it reads the line: wait before
        -- the cleanup removes the images (the 2026-11-19 run's zoom shot
        -- had none).
        { 1500, function() log("HOLD: Right 300") end },
        { 1500, function() log("SCREENSHOT: mapicons_pan") end },
        { 2000, function() end },
    }
    log("PRESS: Right")
    ExecuteInGameThreadWithDelay(3000, function() log("PRESS: M") end)
    run_steps(log, "mapicons", steps, done, function()
        for _, img in ipairs(added) do
            pcall(function() img:RemoveFromParent() end)
        end
    end)
end

return M

-- AfterimageMapTracker: UE4SS Lua mod. An in-game map tracker for Afterimage:
-- a marker on every check (treasure box, pickup, coin rock) on the game's map,
-- with its item's icon and a label naming the item, grey once checked.
--
-- Needs no Archipelago client. By default it tracks the loaded save and
-- shows what each check holds in the unrandomized game. If the Afterimage
-- randomizer's client has written its list of open checks
-- (AfterimageAP_missing.txt, next to the game exe) for the save being
-- played, that list is used instead (map_overlay.lua, "Which locations").
--
-- Configuration: AfterimageMapTracker.flag next to the game exe
-- (<game>/Afterimage/Binaries/Win64/), optional, whitespace-separated words
-- (see README.md): vanilla, legend, noicons, nolabels, norocks, nocollected,
-- noload, off, and "both" (draw even when the randomizer's mod is enabled).
-- Without it, the randomizer launcher's AfterimageAP_tracker.flag is read.

local MOD = "[AfterimageMapTracker] "
local FLAG_FILES = { "AfterimageMapTracker.flag", "AfterimageAP_tracker.flag" }
-- The randomizer's mod (AfterimageAP) draws the same overlay: both enabled
-- would draw every marker twice. UE4SS runs from the game exe's folder, the
-- mods are under ue4ss/Mods.
local MODS_DIR = "ue4ss/Mods/"
local RANDOMIZER_MOD = "AfterimageAP"

local function read_words()
    for _, name in ipairs(FLAG_FILES) do
        local f = io.open(name, "r")
        if f then
            local text = f:read("a") or ""
            f:close()
            local words = {}
            for word in text:gmatch("%S+") do
                words[word:lower()] = true
            end
            return words
        end
    end
    return {}
end

-- Whether UE4SS loads the randomizer's mod: its enabled.txt, or a
-- "AfterimageAP : 1" line in mods.txt.
local function randomizer_mod_enabled()
    local enabled = io.open(MODS_DIR .. RANDOMIZER_MOD .. "/enabled.txt", "r")
    if enabled then
        enabled:close()
        return true
    end
    local mods = io.open(MODS_DIR .. "mods.txt", "r")
    if not mods then
        return false
    end
    local text = mods:read("a") or ""
    mods:close()
    for line in text:gmatch("[^\r\n]+") do
        local name, value = line:match("^%s*([%w_%-]+)%s*:%s*(%d+)")
        if name == RANDOMIZER_MOD and value == "1" then
            return true
        end
    end
    return false
end

local function start()
    if randomizer_mod_enabled() and not read_words().both then
        print(MOD .. "the AfterimageAP (randomizer) mod is enabled and draws the same map overlay: "
            .. "not drawing a second one (disable one of them, or add the word \"both\" to "
            .. FLAG_FILES[1] .. ")\n")
        return
    end
    -- Pawn switches (the flying fish): the overlay pauses and drops the game
    -- objects it kept (transition.lua).
    local transition_ok, transition = pcall(require, "transition")
    if transition_ok then
        transition.start()
    else
        print(MOD .. "transition.lua not loaded: " .. tostring(transition) .. "\n")
    end
    local ok, overlay = pcall(require, "map_overlay")
    if not ok then
        print(MOD .. "map_overlay.lua not loaded: " .. tostring(overlay) .. "\n")
        return
    end
    overlay.start({ flag_files = FLAG_FILES, log_prefix = MOD })
    print(MOD .. "loaded.\n")
end

start()

-- Pawn switches: getting on or off the flying fish (the Clammy Whistle's
-- voyage) makes the player controller possess another pawn
-- (PlayerController:ClientRestart, the hook CheatManagerEnabler logs) while
-- the game streams whole areas out and the Voyage level in, or back. Game
-- objects a script kept from before (the player, its components, level
-- streaming objects) can be destroyed then, and calling a destroyed object
-- crashes the game in native code, which pcall cannot catch: the game crashed
-- getting off the fish at the lighthouse island on 2026-11-18 (UE4SS frames
-- under Lua calls, right after ClientRestart).
--
-- So after each switch the scripts sit out QUIET_S seconds (M.quiet()) and
-- drop every object they kept (M.generation() changed since their last tick).
-- Without the hook (offline tests) nothing is ever quiet.

local M = {}

local QUIET_S = 3
local quiet_until = 0
local generation = 0
local started = false

function M.start()
    if started then
        return
    end
    started = true
    local ok, err = pcall(RegisterHook, "/Script/Engine.PlayerController:ClientRestart", function()
        generation = generation + 1
        quiet_until = os.time() + QUIET_S
    end)
    if not ok then
        print("[AfterimageMapTracker] transition hook not registered: " .. tostring(err) .. "\n")
    end
end

-- True for QUIET_S seconds after a pawn switch: touch no game object.
function M.quiet()
    return os.time() < quiet_until
end

-- Changes with every pawn switch: a script whose last tick saw another value
-- drops the objects it kept.
function M.generation()
    return generation
end

return M

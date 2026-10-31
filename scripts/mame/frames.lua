-- Snapshot every frame from CORE_FIRST to CORE_LAST (MAME frame numbers, at the
-- frame notifier) into CORE_OUT/frame<n>.png, for scripts/compare_reset_frames.py.
-- Driven by scripts/mame_frames.py.

local OUT   = os.getenv("CORE_OUT") or "frames"
local FIRST = tonumber(os.getenv("CORE_FIRST") or "1")
local LAST  = tonumber(os.getenv("CORE_LAST") or "60")
local m     = manager.machine

os.execute('mkdir "' .. OUT:gsub("/", "\\") .. '" 2>nul')

core_frames_sub = emu.add_machine_frame_notifier(function()
    local scr = m.screens[":screen"]
    local n = scr:frame_number()
    if n >= FIRST and n <= LAST then scr:snapshot(string.format("%s/frame%d.png", OUT, n)) end
    if n >= LAST then print("CORE_FRAMES_OK"); m:exit() end
end)

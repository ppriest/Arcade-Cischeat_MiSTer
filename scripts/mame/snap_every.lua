-- Snapshot the screen every CORE_EVERY frames (default 60) up to CORE_N frames (default 7200),
-- as CORE_OUT/fNNNNN.png, then exit. For comparing attract runs across MAME builds that cannot
-- write AVIs.
local OUT = os.getenv("CORE_OUT") or "."
local EVERY = tonumber(os.getenv("CORE_EVERY") or "60")
local N = tonumber(os.getenv("CORE_N") or "7200")
local m = manager.machine
local k = 0
core_snap = emu.add_machine_frame_notifier(function()
    if k % EVERY == 0 then
        m.screens[":screen"]:snapshot(string.format("%s/f%05d.png", OUT, k))
    end
    k = k + 1
    if k > N then m:exit() end
end)

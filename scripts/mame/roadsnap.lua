-- Every CORE_STEP frames up to CORE_LAST: a snapshot and both road RAMs (256 lines x 4
-- words, big-endian) into CORE_OUT/f<n>.png and f<n>_road<k>.bin.

local OUT  = os.getenv("CORE_OUT") or "roadsnap"
local STEP = tonumber(os.getenv("CORE_STEP") or "20")
local LAST = tonumber(os.getenv("CORE_LAST") or "3600")
local m    = manager.machine
local ROADBASE = tonumber(os.getenv("CORE_ROADBASE") or "0x100000")   -- F1 GP Star family; 0x80000 on Cisco Heat

os.execute('mkdir "' .. OUT:gsub("/", "\\") .. '" 2>nul')

local function dump(cpu, name)
    local sp = m.devices[cpu].spaces["program"]
    local f = io.open(name, "wb")
    for a = ROADBASE, ROADBASE + 0x7fe, 2 do
        local w = sp:read_u16(a)
        f:write(string.char((w >> 8) & 0xff, w & 0xff))
    end
    f:close()
end

core_roadsnap_sub = emu.add_machine_frame_notifier(function()
    local scr = m.screens[":screen"]
    local n = scr:frame_number()
    if n > 0 and n % STEP == 0 then
        scr:snapshot(string.format("%s/f%d.png", OUT, n))
        dump(":road1cpu", string.format("%s/f%d_road0.bin", OUT, n))
        dump(":road2cpu", string.format("%s/f%d_road1.bin", OUT, n))
    end
    if n >= LAST then print("CORE_FRAMES_OK"); m:exit() end
end)

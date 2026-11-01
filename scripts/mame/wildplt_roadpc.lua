-- Wild Pilot: which road CPU code writes the road line list. Runs wildplt_stage.lua's
-- setup (coin, start, boss index), then for frame CORE_AT taps road CPU CORE_CPU's writes
-- to its road RAM (0x100000-0x1007ff) and its local list copy (CORE_LO-CORE_HI) and logs
-- frame, PC, address, data per write into CORE_OUT/roadpc.txt. Also logs that CPU's reads of
-- its shared RAM (0x080000-0x087fff, or CORE_RLO-CORE_RHI) as "R".

local OUT   = os.getenv("CORE_OUT") or "roadpc"
local AT    = tonumber(os.getenv("CORE_AT") or "1950")
local CPU   = os.getenv("CORE_CPU") or ":road2cpu"
local LO    = tonumber(os.getenv("CORE_LO") or "0x182580")
local HI    = tonumber(os.getenv("CORE_HI") or "0x182d7f")
local STAGE = 6
local COIN  = 300
local m     = manager.machine

os.execute('mkdir "' .. OUT:gsub("/", "\\") .. '" 2>nul')

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
end
local coin, start, shot = field("Coin 1"), field("1 Player Start"), field("P1 Shot")

local cpu = m.devices[CPU]
local sp  = cpu.spaces["program"]
local log = io.open(OUT .. "/roadpc.txt", "w")
local frame_now, on = 0, false
local function pc() return cpu.state["PC"].value end

_G.__core_taps = {
    sp:install_write_tap(0x100000, 0x1007ff, "roadw", function(off, data, mask)
        if on then log:write(string.format("%d W %06x %06x %04x\n", frame_now, pc(), off, data)) end
        return data
    end),
    sp:install_write_tap(LO, HI, "listw", function(off, data, mask)
        if on then log:write(string.format("%d L %06x %06x %04x\n", frame_now, pc(), off, data)) end
        return data
    end),
    sp:install_read_tap(tonumber(os.getenv("CORE_RLO") or "0x080000"), tonumber(os.getenv("CORE_RHI") or "0x087fff"), "sharedr", function(off, data, mask)
        if on then log:write(string.format("%d R %06x %06x %04x\n", frame_now, pc(), off, data)) end
        return data
    end),
}

core_roadpc_sub = emu.add_machine_frame_notifier(function()
    local n = m.screens[":screen"]:frame_number()
    frame_now = n
    coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
    start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
    if shot then shot:set_value((n >= COIN + 120 and (n % 8) < 4) and 1 or 0) end
    if n >= COIN + 90 and n < COIN + 90 + 1150 then
        local msp = m.devices[":maincpu"].spaces["program"]
        msp:write_u16(0x0f0114, STAGE - 1)
        msp:write_u16(0x0f021a, STAGE - 1)
    end
    on = (n == AT)
    if n == AT + 1 then
        m.screens[":screen"]:snapshot(string.format("%s/f%d.png", OUT, AT))
        log:close(); m:exit()
    end
end)

-- Capture a Cisco Heat state from MAME at a chosen frame, for scripts/state.py
-- from-mame (docs/SAVESTATES.md). Driven by scripts/mame_state.py:
--
--   CORE_OUT     output directory
--   CORE_FRAME   frame to capture at (MAME's frame number, at its frame notifier)
--   CORE_COIN    frame to insert a coin and start, 0 for attract
--   CORE_LINE    scanline to capture at, after frame CORE_FRAME's notifier (default 1)
--
-- Writes state.txt (registers, "name hexvalue" per line) and one <region>.hex
-- per RAM (16-bit words, one per line), read through each CPU's own space.
-- Write-only registers are rebuilt from write taps installed at power-on.

local OUT   = os.getenv("CORE_OUT") or "state"
local FRAME = tonumber(os.getenv("CORE_FRAME") or "600")
local COIN  = tonumber(os.getenv("CORE_COIN") or "0")
local LINE  = tonumber(os.getenv("CORE_LINE") or "1")
local m     = manager.machine

os.execute('mkdir "' .. OUT:gsub("/", "\\") .. '" 2>nul')

local function guard(what, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            local f = io.open(OUT .. "/ERROR.txt", "a")
            if f then f:write(what, ": ", tostring(err), "\n"); f:close() end
            print("CORE_CAPTURE_ERROR " .. what .. ": " .. tostring(err))
            error(err)
        end
        return ok
    end
end

core_subs = {}

local function space(tag) return m.devices[tag].spaces["program"] end
local main, snd = space(":maincpu"), space(":soundcpu")

-- write-only registers: the last value written
local wo = { ip_select = 0, comms = 0, oki_bank0 = 0, oki_bank1 = 0 }
local ga = { 0, 0, 0, 0, 0 }
local ga_hs = 0
local function merge(old, data, mask) return (old & ~mask) | (data & mask) end

core_subs[#core_subs + 1] = main:install_write_tap(0x080010, 0x080011, "st_ipsel",
    guard("ipsel", function(o, d, mk) wo.ip_select = merge(wo.ip_select, d, mk) end))
core_subs[#core_subs + 1] = main:install_write_tap(0x082308, 0x082309, "st_comms",
    guard("comms", function(o, d, mk) wo.comms = merge(wo.comms, d, mk) end))
core_subs[#core_subs + 1] = snd:install_write_tap(0x040002, 0x040005, "st_oki",
    guard("oki", function(o, d, mk)
        if mk & 0xff ~= 0 then
            if o == 0x040002 then wo.oki_bank0 = d & 1 else wo.oki_bank1 = d & 1 end
        end
    end))
-- gate array handshake (ms1_gatearray.cpp gatearray_w): offset & 7, hs on a write of word 4
core_subs[#core_subs + 1] = snd:install_write_tap(0x020000, 0x02ffff, "st_ga",
    guard("ga", function(o, d, mk)
        local k = (o >> 1) & 7
        if k <= 4 then ga[k + 1] = merge(ga[k + 1], d, mk) end
        ga_hs = (k == 4 and ga[1] == 0x00ff and ga[2] == 0x0055 and ga[3] == 0x00aa and ga[4] == 0) and 1 or 0
    end))

local function dump(name, sp, lo, words)
    local t = {}
    for i = 0, words - 1 do t[#t + 1] = string.format("%04x", sp:read_u16(lo + 2 * i)) end
    local f = assert(io.open(OUT .. "/" .. name .. ".hex", "w"))
    f:write(table.concat(t, "\n"), "\n")
    f:close()
end

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
end
local coin, start = field("Coin 1"), field("1 Player Start")

-- The capture runs at scanline 1 after frame FRAME's notifier (vblank start),
-- the bench's restore row (docs/SAVESTATES.md, "Restore point"): captured at
-- the notifier instead, the main loop loses the lines up to row 1 and the
-- sprite list it builds there misses the next latch.
local function capture()
    local scr = m.screens[":screen"]
    local n = scr:frame_number()
    local f = assert(io.open(OUT .. "/state.txt", "w"))
    f:write(string.format("frame %x\n", n))
    for _, c in ipairs({ "maincpu", "road1cpu", "road2cpu", "soundcpu" }) do
        local st = m.devices[":" .. c].state
        for _, r in ipairs({ "D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7",
                             "A0", "A1", "A2", "A3", "A4", "A5", "A6",
                             "SP", "USP", "PC", "CURPC", "SR" }) do
            if not st[r] then
                local names = {}
                for k, _ in pairs(st) do names[#names + 1] = k end
                error(c .. " has no state entry " .. r .. "; it has " .. table.concat(names, " "))
            end
            f:write(string.format("%s.%s %x\n", c, r, st[r].value))
        end
    end
    -- readable registers, through the CPU that reads them
    local scroll = { 0x082000, 0x082008, 0x082100 }
    for l = 1, 3 do
        for k = 0, 2 do
            f:write(string.format("scroll%d_%s %x\n", l - 1, ({ "x", "y", "c" })[k + 1],
                                  main:read_u16(scroll[l] + 2 * k)))
        end
    end
    f:write(string.format("sl_to_main %x\n", main:read_u16(0x082300)))
    f:write(string.format("sl_to_sound %x\n", snd:read_u16(0x060004)))
    for k, v in pairs(wo) do f:write(string.format("%s %x\n", k, v)) end
    for i = 1, 5 do f:write(string.format("ga_ram%d %x\n", i - 1, ga[i])) end
    f:write(string.format("ga_hs %x\n", ga_hs))
    f:close()

    dump("work_ram", main, 0x0f0000, 32768)
    -- road CPU 1's window is the upper one except on Wild Pilot (docs/HACKS.md)
    local wp = manager.machine.system.name == "wildplt"
    dump("shared_road1", main, wp and 0x090000 or 0x098000, 16384)
    dump("shared_road2", main, wp and 0x098000 or 0x090000, 16384)
    dump("scroll0", main, 0x0a0000, 16384)
    dump("scroll1", main, 0x0a8000, 16384)
    dump("scroll2", main, 0x0b0000, 16384)
    dump("palette", main, 0x0b8000, 16384)
    dump("link", main, 0x088000, 1024)
    dump("road_list0", space(":road1cpu"), 0x080000, 1024)
    dump("road_list1", space(":road2cpu"), 0x080000, 1024)
    dump("road1_local", space(":road1cpu"), 0x0c0000, 8192)
    dump("road2_local", space(":road2cpu"), 0x0c0000, 8192)
    dump("sound_ram", snd, 0x0f0000, 32768)
    print(string.format("CORE_STATE_DONE %d, next line %d in %.6f of %.6f s", n, LINE, scr:time_until_pos(LINE), scr.frame_period))
end

local done, armed = false, false
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(guard("frame", function()
    if armed then return end
    local scr = m.screens[":screen"]
    local n = scr:frame_number()
    if COIN > 0 and coin and start then
        coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
        start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
    end
    if n ~= FRAME then return end
    armed = true
    scr:snapshot(OUT .. "/frame0.png")
    local co = coroutine.create(guard("capture", function()
        emu.wait(scr:time_until_pos(LINE))
        capture()
        done = true
    end))
    local ok, err = coroutine.resume(co)
    if not ok then error(err) end
end))

-- the frames after the captured one, for the bench to be compared against
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(guard("after", function()
    if not done then return end
    local scr = m.screens[":screen"]
    local k = scr:frame_number() - FRAME
    if k >= 1 and k <= 3 then scr:snapshot(string.format("%s/frame%d.png", OUT, k)) end
    if k >= 3 then print("CORE_STATE_OK"); m:exit() end
end))

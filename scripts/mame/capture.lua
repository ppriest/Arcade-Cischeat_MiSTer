-- Capture video/machine state from MAME at a chosen frame. Driven by
-- scripts/mame_capture.py, which passes scripts/mame/regions.json as:
--
--   CORE_OUT     output directory
--   CORE_FRAME   frame to capture at
--   CORE_CPU     device tag, e.g. :maincpu
--   CORE_SPACE   address space, e.g. program
--   CORE_BYTES   bus width in bytes (1, 2, 4, 8)
--   CORE_BIG     1 if the bus is big-endian
--   CORE_READ    "name:hexlo:hexhi,..."  RAM readable through the CPU's view
--   CORE_READ_EXTRA "name:cpu:space:hexlo:hexhi,..." RAM in other CPU spaces
--   CORE_WTAP    "name:hexlo:hexhi,..."  write-only registers, rebuilt from writes
--   CORE_COIN    frame to insert a coin, then start and drive
--
-- Readable RAM is read through the CPU's address space: that is what the CPU
-- would read, handlers and umask included, which is what the RTL must match.
-- Write-only registers cannot be read back; MAME keeps them inside the device.
-- They are rebuilt from a write tap installed before the machine runs: the last
-- byte written to each address is the register state at the captured frame.
--
-- Banked memory (a window whose page is set by a register) needs the bank
-- tracked per write. Add that per core below the generic taps; see the
-- KonamiGX core's scripts/mame/capture.lua for a worked example.

local OUT   = os.getenv("CORE_OUT") or "capture"
local FRAME = tonumber(os.getenv("CORE_FRAME") or "1200")
local COIN  = tonumber(os.getenv("CORE_COIN") or "0")
local BYTES = tonumber(os.getenv("CORE_BYTES") or "2")
local BIG   = os.getenv("CORE_BIG") ~= "0"
local m     = manager.machine

local function mkdir(p) os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') end
mkdir(OUT)

-- An error inside a Lua callback is silent: MAME keeps running and exits 0
-- having produced nothing. Every callback goes through guard(), which writes
-- the failure where the Python side reads it back.
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

local function wr(name, bytes)
    local f = assert(io.open(OUT .. "/" .. name, "wb"))
    f:write(bytes)
    f:close()
end

local function ranges(s)
    local out = {}
    for spec in string.gmatch(s or "", "([^,]+)") do
        local name, lo, hi = spec:match("^([^:]+):(%x+):(%x+)$")
        assert(name, "bad range spec: " .. spec)
        out[#out + 1] = { name = name, lo = tonumber(lo, 16), hi = tonumber(hi, 16) }
    end
    return out
end

local function extra_ranges(s)
    local out = {}
    for spec in string.gmatch(s or "", "([^,]+)") do
        local name, cpu, space, lo, hi = spec:match("^([^:]+):([^:]+):([^:]+):(%x+):(%x+)$")
        assert(name, "bad extra read range: " .. spec)
        out[#out + 1] = { name = name, cpu = cpu, space = space,
                          lo = tonumber(lo, 16), hi = tonumber(hi, 16) }
    end
    return out
end

-- Global on purpose: an autoboot chunk's locals are collected once the chunk
-- returns, and taps and notifiers held only by a local stop firing silently.
core_subs = {}

local sp = m.devices[os.getenv("CORE_CPU") or ":maincpu"].spaces[os.getenv("CORE_SPACE") or "program"]

-- Split a tap's data by the mask actually driven, not by an assumed width.
local function note(tbl, base, addr, data, mask)
    for b = 0, BYTES - 1 do
        local sh = BIG and (BYTES - 1 - b) * 8 or b * 8
        if (mask >> sh) & 0xff ~= 0 then
            tbl[(addr - base) + b] = (data >> sh) & 0xff
        end
    end
end

local regs = {}
local WTAP = ranges(os.getenv("CORE_WTAP"))
for _, r in ipairs(WTAP) do
    regs[r.name] = {}
    core_subs[#core_subs + 1] = sp:install_write_tap(r.lo, r.hi, "core_" .. r.name,
        guard("tap_" .. r.name, function(offset, data, mask)
            note(regs[r.name], r.lo, offset, data, mask)
        end))
end

local function read_block(space, lo, hi)
    local t = {}
    for a = lo, hi do t[#t + 1] = string.char(space:read_u8(a)) end
    return table.concat(t)
end

local function dump_sparse(name, tbl, size)
    local t = {}
    for i = 0, size - 1 do t[i + 1] = string.char(tbl[i] or 0) end
    wr(name, table.concat(t))
end

local done = false
local function field(name)
    for _, port in pairs(m.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
end
local coin, start, hold, pulse
if COIN > 0 then
    coin = field(os.getenv("CORE_IN_COIN") or "Coin 1")
    start = field(os.getenv("CORE_IN_START") or "1 Player Start")
    hold = field(os.getenv("CORE_IN_HOLD") or "P1 Right")
    pulse = field(os.getenv("CORE_IN_PULSE") or "P1 Button 1")
end
core_subs[#core_subs + 1] = emu.add_machine_frame_notifier(guard("frame", function()
    if done then return end
    local scr = m.screens[":screen"]
    local n = scr:frame_number()
    if COIN > 0 and coin and start then
        coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
        start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
        if n >= COIN + 96 then
            if hold then hold:set_value(1) end
            if pulse then pulse:set_value((n % 20) < 4 and 1 or 0) end
        end
    end
    if scr:frame_number() < FRAME then return end
    done = true

    for _, r in ipairs(ranges(os.getenv("CORE_READ"))) do
        wr(r.name .. ".bin", read_block(sp, r.lo, r.hi))
    end
    for _, r in ipairs(extra_ranges(os.getenv("CORE_READ_EXTRA"))) do
        local cpu = assert(m.devices[":" .. r.cpu], "missing capture CPU: " .. r.cpu)
        local space = assert(cpu.spaces[r.space], "missing capture space: " .. r.space)
        wr(r.name .. ".bin", read_block(space, r.lo, r.hi))
    end
    for _, r in ipairs(WTAP) do
        dump_sparse("reg_" .. r.name .. ".bin", regs[r.name], r.hi - r.lo + 1)
    end

    scr:snapshot(OUT .. "/reference.png")

    local f = assert(io.open(OUT .. "/manifest.txt", "w"))
    f:write("set ", m.system.name, "\n")
    f:write("mame ", emu.app_version(), "\n")
    f:write("frame ", tostring(scr:frame_number()), "\n")
    f:write("screen ", tostring(scr.width), "x", tostring(scr.height), "\n")
    f:close()

    print("CORE_CAPTURE_OK " .. OUT)
    m:exit()
end))

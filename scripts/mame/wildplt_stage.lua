-- Wild Pilot: coin up, start, and force the stage index so play begins on stage CORE_STAGE.
-- The slot count (a word) is at 0xf0114 and 0xf021a; the game sets both from the 0xf0b82 list. Both equal
-- stage - 1 in every attract stage seen (1, 2, 3, 5). Held from the Start press for CORE_HOLD frames.
--
--   CORE_OUT    output directory: f<n>.png every CORE_STEP frames, road RAM at each
--   CORE_STAGE  stage to start on (default 6)
--   CORE_LAST   last frame
--   CORE_SAVE   frame to save a MAME state named "stage<CORE_STAGE>" (0: none)
--   CORE_FIRE   1: hold Shot from the start, so the plane keeps firing

local OUT   = os.getenv("CORE_OUT") or "stage"
local STAGE = tonumber(os.getenv("CORE_STAGE") or "6")
local HOLD  = tonumber(os.getenv("CORE_HOLD") or "60")
local STEP  = tonumber(os.getenv("CORE_STEP") or "30")
local LAST  = tonumber(os.getenv("CORE_LAST") or "2400")
local SAVE  = tonumber(os.getenv("CORE_SAVE") or "0")
local FIRE  = tonumber(os.getenv("CORE_FIRE") or "0")
local COIN  = 300
local RAMAT = {}
for v in string.gmatch(os.getenv("CORE_RAMAT") or "", "%d+") do RAMAT[tonumber(v)] = true end
local m     = manager.machine
local ROADBASE = 0x100000   -- road RAM in the road CPUs' space (f1gpstar_map2/3)

os.execute('mkdir "' .. OUT:gsub("/", "\\") .. '" 2>nul')

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
end
local coin, start, shot = field("Coin 1"), field("1 Player Start"), field("P1 Shot")

local function dump(cpu, name)
    local sp = m.devices[cpu].spaces["program"]
    local f = io.open(name, "wb")
    for a = ROADBASE, ROADBASE + 0x7fe, 2 do
        local w = sp:read_u16(a)
        f:write(string.char((w >> 8) & 0xff, w & 0xff))
    end
    f:close()
end

-- CORE_TAP=1: log main-CPU writes to the video registers (0x82000-0x82fff), one line per
-- change of (address, value), to CORE_OUT/vregs.txt
local tapf, last_w, frame_now = nil, {}, 0
if os.getenv("CORE_TAP") == "1" then
    tapf = io.open(OUT .. "/vregs.txt", "w")
    _G.__core_vtap = m.devices[":maincpu"].spaces["program"]:install_write_tap(0x082000, 0x082fff, "vregs",
        function(offset, data, mask)
            if last_w[offset] ~= data then
                last_w[offset] = data
                tapf:write(string.format("%d %06x %04x %04x\n", frame_now, offset, data, mask))
            end
            return data
        end)
end

core_stage_sub = emu.add_machine_frame_notifier(function()
    local scr = m.screens[":screen"]
    local n = scr:frame_number()
    frame_now = n
    coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
    start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
    if shot then shot:set_value((FIRE ~= 0 and n >= COIN + 120 and (n % 8) < 4) and 1 or 0) end
    if n >= COIN + 90 and n < COIN + 90 + HOLD then
        local sp = m.devices[":maincpu"].spaces["program"]
        sp:write_u16(0x0f0114, STAGE - 1)
        sp:write_u16(0x0f021a, STAGE - 1)
    end
    if n > 0 and n % STEP == 0 then
        scr:snapshot(string.format("%s/f%d.png", OUT, n))
        dump(":road1cpu", string.format("%s/f%d_road0.bin", OUT, n))
        dump(":road2cpu", string.format("%s/f%d_road1.bin", OUT, n))
        -- sprite DMA source (wildplt_state::video_start), not the copy MAME draws
        local sp = m.devices[":maincpu"].spaces["program"]
        local f = io.open(string.format("%s/f%d_spr.bin", OUT, n), "wb")
        for a = 0x0f8000, 0x0f8ffe, 2 do
            local w = sp:read_u16(a)
            f:write(string.char((w >> 8) & 0xff, w & 0xff))
        end
        f:close()
    end
    if n == SAVE then m:save("stage" .. STAGE) end
    -- CORE_RAMAT (comma list): every road CPU RAM (road RAM, shared, local) and main RAM at these frames
    if RAMAT[n] then
        local function region(cpu, lo, hi, name)
            local sp = m.devices[cpu].spaces["program"]
            local f = io.open(string.format("%s/f%d_%s.bin", OUT, n, name), "wb")
            for a = lo, hi, 2 do
                local w = sp:read_u16(a)
                f:write(string.char((w >> 8) & 0xff, w & 0xff))
            end
            f:close()
        end
        for k, cpu in ipairs({":road1cpu", ":road2cpu"}) do
            region(cpu, 0x080000, 0x087ffe, "r" .. (k - 1) .. "_shared")
            region(cpu, 0x100000, 0x1007fe, "r" .. (k - 1) .. "_roadram")
            region(cpu, 0x180000, 0x183ffe, "r" .. (k - 1) .. "_local")
        end
        region(":maincpu", 0x0f0000, 0x0ffffe, "main_ram")
        region(":maincpu", 0x0a0000, 0x0b7ffe, "scroll_ram")   -- scroll0, 1, 2 at 0x0, 0x8000, 0x10000
        region(":maincpu", 0x0b8000, 0x0bfffe, "palette")
        local sp = m.devices[":maincpu"].spaces["program"]
        local f = io.open(string.format("%s/f%d_scroll_regs.txt", OUT, n), "w")
        for _, a in ipairs({0x082000, 0x082008, 0x082100}) do
            f:write(string.format("%04x %04x %04x\n", sp:read_u16(a), sp:read_u16(a + 2), sp:read_u16(a + 4)))
        end
        f:close()
    end
    if n >= LAST then if tapf then tapf:close() end m:exit() end
end)

-- Dump the program-space ROM as the CPU sees it, for a simulation testbench.
-- Driven by scripts/mame_rom_dump.py:
--
--   CORE_OUT        directory to write into (must exist)
--   CORE_TAG        output filename prefix (normally the set name)
--   CORE_ROM_RANGES "lo:hi,lo:hi" inclusive byte ranges from regions.json
--   CORE_CPU, CORE_SPACE, CORE_BYTES   from regions.json
--
-- One 16-bit word per line, in ascending CPU order. This is MAME's decoded,
-- interleaved view of the region, not the ROM files: the driver's
-- ROM_LOAD16_BYTE pairs and any byte swap are already applied, so the
-- testbench does not reimplement them (and cannot get them wrong).
--
-- The MAME region image would be a third option only where the map installs
-- the region at offset 0; the address map is the definition used here.

local OUT    = os.getenv("CORE_OUT") or "."
local TAG    = os.getenv("CORE_TAG") or "rom"
local RANGES = os.getenv("CORE_ROM_RANGES") or "0:0"
local BYTES  = tonumber(os.getenv("CORE_BYTES") or "2")

local mach = manager.machine
local cpu  = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local prog = cpu.spaces[os.getenv("CORE_SPACE") or "program"]
local fmt  = "%0" .. (2 * BYTES) .. "X\n"

local f = assert(io.open(string.format("%s/%s_rom.hex", OUT, TAG), "w"))
local words, lo_first, hi_last = 0, nil, nil

for lo, hi in RANGES:gmatch("([^:,]+):([^,]+)") do
    lo, hi = tonumber(lo, 16), tonumber(hi, 16)
    lo_first = lo_first or lo
    hi_last = hi
    for a = lo, hi, BYTES do
        if BYTES == 2 then
            f:write(string.format(fmt, prog:read_u16(a)))
        elseif BYTES == 1 then
            f:write(string.format(fmt, prog:read_u8(a)))
        else
            f:write(string.format(fmt, prog:read_u32(a)))
        end
        words = words + 1
    end
end
f:close()

print(string.format("ROMDUMP %d words, %06X-%06X -> %s/%s_rom.hex",
                    words, lo_first, hi_last, OUT, TAG))
mach:exit()

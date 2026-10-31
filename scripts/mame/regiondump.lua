-- Dump an initialized MAME memory region for ROM-transform verification.
-- CORE_REGION is an absolute tag (for example, :sprites).
-- CORE_OUT and CORE_TAG select the output path.
local OUT = os.getenv("CORE_OUT") or "."
local TAG = os.getenv("CORE_TAG") or "region"
local REGION = os.getenv("CORE_REGION") or ":maincpu"
local region = assert(manager.machine.memory.regions[REGION], "missing region " .. REGION)
local f = assert(io.open(string.format("%s/%s.bin", OUT, TAG), "wb"))
local data = region:read(0, region.size)
assert(#data == region.size, "short region read")
f:write(data)
f:close()
print(string.format("REGIONDUMP %s (%X bytes) -> %s/%s.bin", REGION, region.size, OUT, TAG))
manager.machine:exit()

-- Main CPU reads of one road CPU's x/y tables (0x?0300-0x?05ff) return the other road CPU's entry.
-- CORE_YSRC=1: reads of road 2's tables (0x90xxx) get road 1's; CORE_YSRC=2: the reverse. Then CORE_NEXT.
local m=manager.machine; local sp=m.devices[":maincpu"].spaces["program"]
local SRC=os.getenv("CORE_YSRC") or "1"
local lo=(SRC=="1") and 0x90300 or 0x98300
local delta=(SRC=="1") and 0x8000 or -0x8000
local road={m.devices[":road1cpu"].spaces["program"],m.devices[":road2cpu"].spaces["program"]}
local other=(SRC=="1") and road[1] or road[2]
_G.__ys=sp:install_read_tap(lo,lo+0x2ff,"ys",function(off,data,mask)
  return other:read_u16(0x80000+(off-lo)+0x300) end)
dofile(os.getenv("CORE_NEXT"))

-- Road CPU 2 reads its block words 0x8000c-0x80017 from main 0x98000 (road CPU 1's block) and road CPU 1 from 0x90000:
-- the two shared RAMs swapped for the words where the blocks differ. Then wildplt_stick.lua.
local m=manager.machine
local sp=m.devices[":maincpu"].spaces["program"]
local r1=m.devices[":road1cpu"].spaces["program"]; local r2=m.devices[":road2cpu"].spaces["program"]
local FROM=tonumber(os.getenv("CORE_SWAPFROM") or "0")
local function frame() return m.screens[":screen"]:frame_number() end
_G.__s2=r2:install_read_tap(0x8000c,0x80017,"sw2",function(off,data,mask) if frame()>=FROM then return sp:read_u16(0x98000+(off&0xfffe)-0x80000) end return data end)
_G.__s1=r1:install_read_tap(0x8000c,0x80017,"sw1",function(off,data,mask) if frame()>=FROM then return sp:read_u16(0x90000+(off&0xfffe)-0x80000) end return data end)
dofile(os.getenv("CORE_SCRIPTDIR").."/wildplt_stick.lua")

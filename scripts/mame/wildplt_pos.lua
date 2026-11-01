-- Log track position 0xf0118, mode word 0xf0218, pitch 0xf0216 and road CPU 2's 0x1800b6/0x180040/0x180074 every 10 frames.
local OUT=os.getenv("CORE_OUT"); local m=manager.machine
local sp=m.devices[":maincpu"].spaces["program"]; local r2=m.devices[":road2cpu"].spaces["program"]
local f=io.open(OUT.."/pos.txt","w")
core_pos=emu.add_machine_frame_notifier(function()
  local n=m.screens[":screen"]:frame_number()
  if n%10==0 and n>=1500 then
    f:write(string.format("%d pos %d f0218 %d pitch %d b6 %d alt %d p74 %d s80018 %d\n",n,sp:read_u32(0xf0118),sp:read_u16(0xf0218),
      (sp:read_u16(0xf0216)~32768)-32768,r2:read_u16(0x1800b6),r2:read_u32(0x180040),(r2:read_u16(0x180074)~32768)-32768,r2:read_u16(0x80018)))
    f:flush()
  end
end)
dofile(os.getenv("CORE_SCRIPTDIR").."/wildplt_stick.lua")

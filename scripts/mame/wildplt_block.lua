-- Dump road CPU 2's block (main 0x90000-0x90021) and road CPU 1's (0x98000-0x98021) every 20 frames from 1900.
local OUT=os.getenv("CORE_OUT"); local m=manager.machine
local sp=m.devices[":maincpu"].spaces["program"]
local f=io.open(OUT.."/block.txt","w")
core_b=emu.add_machine_frame_notifier(function()
  local n=m.screens[":screen"]:frame_number()
  if n%20==0 and n>=1900 then
    for _,b in ipairs({0x90000,0x98000}) do
      local t={}
      for a=0,0x20,2 do t[#t+1]=string.format("%04x",sp:read_u16(b+a)) end
      f:write(string.format("%d %05x %s\n",n,b,table.concat(t," ")))
    end
    f:flush()
  end
end)
dofile(os.getenv("CORE_SCRIPTDIR").."/wildplt_stick.lua")

-- Load state CORE_STATE, after CORE_K frames dump both road CPUs' line words (0x100000, 4 words per line) and both camera blocks.
local OUT=os.getenv("CORE_OUT"); local m=manager.machine; local K=tonumber(os.getenv("CORE_K") or "40")
local sp=m.devices[":maincpu"].spaces["program"]
local r={m.devices[":road1cpu"].spaces["program"],m.devices[":road2cpu"].spaces["program"]}
local k=-1
core_s=emu.add_machine_frame_notifier(function()
  if k<0 then k=0; m:load(os.getenv('CORE_STATE') or '6'); return end
  k=k+1
  if k==K then local f=io.open(OUT.."/roadw.txt","w")
    for _,b in ipairs({0x90000,0x98000}) do local t={} for a=b,b+0x20,2 do t[#t+1]=string.format("%04x",sp:read_u16(a)) end f:write(string.format("blk %05x: %s\n",b,table.concat(t," "))) end
    for y=0,255 do local t={} for n=1,2 do for j=0,3 do t[#t+1]=string.format("%04x",r[n]:read_u16(0x100000+y*8+j*2)) end t[#t+1]="|" end
      f:write(string.format("%3d %s\n",y,table.concat(t," "))) end
    f:close(); m.screens[":screen"]:snapshot(OUT.."/k.png"); m:exit() end
end)

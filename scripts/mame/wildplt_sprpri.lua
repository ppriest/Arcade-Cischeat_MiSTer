-- Load state CORE_STATE, run CORE_K frames, dump visible sprites (source main 0xf8000) and both roads' line priorities.
local OUT=os.getenv("CORE_OUT"); local m=manager.machine; local K=tonumber(os.getenv("CORE_K") or "40")
local sp=m.devices[":maincpu"].spaces["program"]
local r={m.devices[":road1cpu"].spaces["program"],m.devices[":road2cpu"].spaces["program"]}
local k=-1
core_s=emu.add_machine_frame_notifier(function()
  if k<0 then k=0; m:load(os.getenv('CORE_STATE') or '4'); return end
  k=k+1
  if k==K then
    local f=io.open(OUT.."/sprpri.txt","w")
    for i=0,255 do local a=0xf8000+i*16; local w={} for j=0,7 do w[j]=sp:read_u16(a+j*2) end
      if (w[0]&0x1000)==0 then f:write(string.format("spr %3d size %04x xz %04x yz %04x sx %d sy %d code %04x attr %04x pri %d\n",i,w[0],w[1],w[2],w[3]&0x7ff,w[4]&0x7ff,w[6],w[7],(w[7]>>8)&7)) end end
    for n=1,2 do local line={} for y=0,255 do local w0=r[n]:read_u16(0x100000+y*8); line[#line+1]=string.format("%x",(w0>>12)&7) end
      f:write("road"..n.." pri by line: "..table.concat(line).."\n") end
    f:close(); m.screens[":screen"]:snapshot(OUT.."/k.png"); m:exit()
  end
end)

-- Load state CORE_STATE, after CORE_K frames dump main's view of the road tables 0x?0300-0x?03c2 and 0x?0500-0x?05c2 (both road CPUs) and log writer PCs on road CPUs.
local OUT=os.getenv("CORE_OUT"); local m=manager.machine; local K=tonumber(os.getenv("CORE_K") or "4")
local sp=m.devices[":maincpu"].spaces["program"]
local rc={m.devices[":road1cpu"],m.devices[":road2cpu"]}
local pcs={}; local k=-1
core_s=emu.add_machine_frame_notifier(function()
  if k<0 then k=0; m:load(os.getenv('CORE_STATE') or '5'); return end
  if k==0 then for n=1,2 do local c=rc[n]; _G["__w"..n]=c.spaces["program"]:install_write_tap(0x80300,0x805ff,"w"..n,function(off,data,mask)
      local key=string.format("road%d %03x pc %06x",n,(off-0x80000)&0xf00,c.state["PC"].value); pcs[key]=(pcs[key] or 0)+1 end) end end
  k=k+1
  if k==K then local f=io.open(OUT.."/ytab.txt","w")
    for _,base in ipairs({0x90300,0x98300,0x90500,0x98500}) do local t={} for a=base,base+0xc2,2 do t[#t+1]=string.format("%04x",sp:read_u16(a)) end f:write(string.format("%05x: %s\n",base,table.concat(t," "))) end
    for a,n in pairs(pcs) do f:write(a.." n "..n.."\n") end
    f:close(); m.screens[":screen"]:snapshot(OUT.."/k.png"); m:exit() end
end)

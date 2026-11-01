-- Load state CORE_STATE; for CORE_K frames log writes to 0x8000c (value, PC, frame).
local OUT=os.getenv("CORE_OUT"); local m=manager.machine; local K=tonumber(os.getenv("CORE_K") or "120")
local cpu=m.devices[":maincpu"]; local sp=cpu.spaces["program"]
local f=io.open(OUT.."/dmareg.txt","w"); local k=-1; local last=nil
core_s=emu.add_machine_frame_notifier(function()
  if k<0 then k=0; m:load(os.getenv('CORE_STATE') or '9'); return end
  if k==0 then _G.__t=sp:install_write_tap(0x8000c,0x8000d,"w",function(off,data,mask)
      local v=data&0xff; if v~=last then f:write(string.format("k %d pc %06x data %04x idx %d\n",k,cpu.state["PC"].value,data,sp:read_u16(0xf0114))); last=v end end) end
  k=k+1
  if k>=K then f:close(); m:exit() end
end)

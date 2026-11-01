-- Load state CORE_STATE; for frames CORE_K..CORE_K+2 log, at main 0x37328 (y table read), d6 flags, the table (road 1/2), a2 and the entry read.
local OUT=os.getenv("CORE_OUT"); local m=manager.machine; local K=tonumber(os.getenv("CORE_K") or "4")
local cpu=m.devices[":maincpu"]; local sp=cpu.spaces["program"]
local f=io.open(OUT.."/objtab.txt","w"); local k=-1
core_s=emu.add_machine_frame_notifier(function()
  if k<0 then k=0; m:load(os.getenv('CORE_STATE') or '5'); return end
  k=k+1
  if k==K then _G.__t=sp:install_read_tap(0x90300,0x9ffff,"r",function(off,data,mask)
      local pc=cpu.state["PC"].value
      if ((off & 0x7f00)==0x500) then
        local d6=cpu.state["D6"].value&0xffff; local a0=cpu.state["A0"].value
        f:write(string.format("k %d d6 %04x road %d a2 %05x entry %04x d2idx %d obj %06x\n",k,d6,(off>=0x98000) and 1 or 2,off,data,cpu.state["D2"].value&0xffff,a0)) end end) end
  if k>=K+2 then f:close(); m:exit() end
end)

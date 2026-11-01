-- Log the per-road offsets 0xf4d00-07, the P/Q words sent to each road CPU (0x90014/16 road 2, 0x98014/16 road 1), and writers of 0xf4d00-07.
local OUT=os.getenv("CORE_OUT"); local m=manager.machine
local cpu=m.devices[":maincpu"]; local sp=cpu.spaces["program"]
local f=io.open(OUT.."/offs.txt","w"); local pcs={}
local function s16(v) return (v~32768)-32768 end
core_w=sp:install_write_tap(0xf4d00,0xf4d07,"offs",function(off,data,mask)
  local k=string.format("%05x pc %06x",off,cpu.state["PC"].value); pcs[k]=(pcs[k] or 0)+1 end)
core_o=emu.add_machine_frame_notifier(function()
  local n=m.screens[":screen"]:frame_number()
  if n%10==0 and n>=1900 then
    f:write(string.format("%d f4d00 %d %d %d %d  r2 Q %d P %d  r1 Q %d P %d  f0214 %d f0216 %d\n",n,
      s16(sp:read_u16(0xf4d00)),s16(sp:read_u16(0xf4d02)),s16(sp:read_u16(0xf4d04)),s16(sp:read_u16(0xf4d06)),
      s16(sp:read_u16(0x90014)),s16(sp:read_u16(0x90016)),s16(sp:read_u16(0x98014)),s16(sp:read_u16(0x98016)),
      s16(sp:read_u16(0xf0214)),s16(sp:read_u16(0xf0216))))
  end
end)
core_end=emu.add_machine_stop_notifier(function()
  for k,v in pairs(pcs) do f:write(k," x",v,"\n") end; f:close() end)
dofile(os.getenv("CORE_SCRIPTDIR").."/wildplt_stick.lua")

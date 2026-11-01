-- Log writes to the tilemap 0 scroll shadow 0xf0608-0xf060b (PC, value) from frame 2000, plus pitch per 10 frames.
local OUT=os.getenv("CORE_OUT"); local m=manager.machine
local cpu=m.devices[":maincpu"]; local sp=cpu.spaces["program"]
local f=io.open(OUT.."/sky.txt","w"); local last={}
core_sky=sp:install_write_tap(0xf0608,0xf060b,"sky",function(off,data,mask)
  local n=m.screens[":screen"]:frame_number()
  if n>=2000 and n<=2600 then
    local pc=cpu.state["PC"].value
    local k=string.format("%05x %x",off,pc)
    if last[k]~=data then f:write(string.format("%d %05x pc %06x data %04x mask %04x\n",n,off,pc,data,mask)); last[k]=data end
  end
end)
dofile(os.getenv("CORE_SCRIPTDIR").."/wildplt_stick.lua")

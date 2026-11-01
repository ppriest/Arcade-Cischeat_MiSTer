-- Wild Pilot index CORE_IDX: road CPU 2 (CORE_GAIN) and road CPU 1 (CORE_GAIN1) read shared 0x80016 (pitch) multiplied by CORE_GAIN (float),
-- from frame CORE_FROM. Snapshots every CORE_STEP from CORE_FIRST; logs pitch and road 1's first line every 10.
local OUT=os.getenv("CORE_OUT"); local IDX=tonumber(os.getenv("CORE_IDX") or "4")
local GAIN=tonumber(os.getenv("CORE_GAIN") or "1"); local FROM=tonumber(os.getenv("CORE_FROM") or "1900")
local STEP=tonumber(os.getenv("CORE_STEP") or "30"); local FIRST=tonumber(os.getenv("CORE_FIRST") or "2010"); local LAST=tonumber(os.getenv("CORE_LAST") or "3000")
local m=manager.machine
local function field(name) for _,p in pairs(m.ioport.ports) do local f=p.fields[name]; if f then return f end end end
local coin,start,shot=field("Coin 1"),field("1 Player Start"),field("P1 Shot")
local sp=m.devices[":maincpu"].spaces["program"]; local rp=m.devices[":road2cpu"].spaces["program"]
local n=0
_G.__t=rp:install_read_tap(0x80016,0x80017,"pitch",function(off,data,mask)
  if n>=FROM then local v=data; if v>=0x8000 then v=v-0x10000 end; v=math.floor(v*GAIN+0.5); if v<-32768 then v=-32768 end; if v>32767 then v=32767 end; return v & 0xffff end
  return data end)
local G1=tonumber(os.getenv("CORE_GAIN1") or "1")
local r1=m.devices[":road1cpu"].spaces["program"]
_G.__t1=r1:install_read_tap(0x80016,0x80017,"pitch1",function(off,data,mask)
  if n>=FROM then local v=data; if v>=0x8000 then v=v-0x10000 end; v=math.floor(v*G1+0.5); if v<-32768 then v=-32768 end; if v>32767 then v=32767 end; return v & 0xffff end
  return data end)
local log=io.open(OUT.."/gain.txt","w")
core_sub=emu.add_machine_frame_notifier(function()
  n=m.screens[":screen"]:frame_number()
  coin:set_value((n>=300 and n<306) and 1 or 0)
  start:set_value((n>=390 and n<396) and 1 or 0)
  shot:set_value((n>=420 and n%8<4) and 1 or 0)
  if n>=390 and n<1540 then sp:write_u16(0xf0114,IDX); sp:write_u16(0xf021a,IDX) end
  if n%10==0 and n>=FIRST then
    local first=nil
    for y=16,239 do local w0=rp:read_u16(0x100000+y*8); if (w0>>12)&7~=7 and w0~=0 then first=y break end end
    log:write(string.format("%d pitch %04x first %s\n",n,sp:read_u16(0xf0216),tostring(first)))
  end
  if n%STEP==0 and n>=FIRST then m.screens[":screen"]:snapshot(string.format("%s/f%d.png",OUT,n)) end
  if n>=LAST then log:close(); m:exit() end
end)

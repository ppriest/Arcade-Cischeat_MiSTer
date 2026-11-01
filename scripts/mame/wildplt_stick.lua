-- Wild Pilot index CORE_IDX with the P1 stick Y held at CORE_SY (0..255) from CORE_SFROM to CORE_STO.
-- Logs frame, pitch 0xf0216, and road 1's first non-sky line every 10 frames; snapshots and road dumps every 30.
local OUT=os.getenv("CORE_OUT"); local IDX=tonumber(os.getenv("CORE_IDX") or "4")
local SY=tonumber(os.getenv("CORE_SY") or "128"); local SFROM=tonumber(os.getenv("CORE_SFROM") or "2040"); local STO=tonumber(os.getenv("CORE_STO") or "2400")
local LAST=tonumber(os.getenv("CORE_LAST") or "2700")
local m=manager.machine
local function field(name) for _,p in pairs(m.ioport.ports) do local f=p.fields[name]; if f then return f end end end
local coin,start,shot,sy=field("Coin 1"),field("1 Player Start"),field("P1 Shot"),field("P1 Y")
if not sy then sy=field("AD Stick Y"); print("stick field:", sy and "AD Stick Y" or "none") end
local sp=m.devices[":maincpu"].spaces["program"]; local rp=m.devices[":road2cpu"].spaces["program"]
local log=io.open(OUT.."/stick.txt","w")
local function dump(name)
  local f=io.open(name,"wb")
  for a=0x100000,0x1007fe,2 do local w=rp:read_u16(a); f:write(string.char((w>>8)&0xff,w&0xff)) end
  f:close()
end
core_sub=emu.add_machine_frame_notifier(function()
  local n=m.screens[":screen"]:frame_number()
  coin:set_value((n>=300 and n<306) and 1 or 0)
  start:set_value((n>=390 and n<396) and 1 or 0)
  shot:set_value((n>=420 and n%8<4) and 1 or 0)
  if sy then sy:set_value((n>=SFROM and n<STO) and SY or 128) end
  if n>=390 and n<1540 then sp:write_u16(0xf0114,IDX); sp:write_u16(0xf021a,IDX) end
  local LF=tonumber(os.getenv("CORE_LOGFROM") or "1900")
  if n%10==0 and n>=LF then
    local first=nil
    for y=16,239 do local w0=rp:read_u16(0x100000+y*8); if (w0>>12)&7~=7 and w0~=0 then first=y break end end
    log:write(string.format("%d pitch %04x first %s\n",n,sp:read_u16(0xf0216),tostring(first)))
  end
  local SS=tonumber(os.getenv("CORE_SNAPSTEP") or "30")
  if n%SS==0 and n>=LF then m.screens[":screen"]:snapshot(string.format("%s/f%d.png",OUT,n)); dump(string.format("%s/f%d_road1.bin",OUT,n)) end
  if n>=LAST then log:close(); m:exit() end
end)

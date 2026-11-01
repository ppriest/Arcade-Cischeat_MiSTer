-- Wild Pilot: loads savestate CORE_STATE (default 1) on the first frame, then: log stage, position, pitch, road CPU 2 state, and snapshot every CORE_STEP calls for CORE_N calls.
local OUT=os.getenv("CORE_OUT"); local m=manager.machine
local sp=m.devices[":maincpu"].spaces["program"]; local r2=m.devices[":road2cpu"].spaces["program"]
local STEP=tonumber(os.getenv("CORE_STEP") or "4"); local N=tonumber(os.getenv("CORE_N") or "120")
local f=io.open(OUT.."/state.txt","w"); local k=0
local function s16(v) return (v~32768)-32768 end
local loaded=false
core_s=emu.add_machine_frame_notifier(function()
  if not loaded then loaded=true; m:load(os.getenv('CORE_STATE') or '1'); return end
  k=k+1
  if k%STEP==0 then
    local b={} for a=0,0x20,2 do b[#b+1]=string.format("%04x",sp:read_u16(0x90000+a)) end
    f:write(string.format("%d frame %d idx %d pos %d pitch %d p74 %d flat %d b6 %d alt %d off %d %d blk %s\n",k,m.screens[":screen"]:frame_number(),
      sp:read_u16(0xf0114),sp:read_u32(0xf0118),s16(sp:read_u16(0xf0216)),s16(r2:read_u16(0x180074)),r2:read_u16(0x18009a),
      r2:read_u16(0x1800b6),r2:read_u32(0x180040),s16(sp:read_u16(0xf0230)),s16(sp:read_u16(0xf0234)),table.concat(b," ")))
    m.screens[":screen"]:snapshot(string.format("%s/s%03d.png",OUT,k))
    local fh=io.open(string.format("%s/s%03d_road1.bin",OUT,k),"wb")
    for a=0x100000,0x1007fe,2 do local w=r2:read_u16(a); fh:write(string.char((w>>8)&0xff,w&0xff)) end
    fh:close()
  end
  if k>=N then f:close(); m:exit() end
end)

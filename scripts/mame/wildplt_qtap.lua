-- Road CPU 2's read of Q (shared 0x80014): CORE_QMODE=neg negates it; off negates only the per-road
-- offset main 0xf0230 (Q - 2*offset). Then runs CORE_NEXT.
local m=manager.machine
local r2=m.devices[":road2cpu"].spaces["program"]; local sp=m.devices[":maincpu"].spaces["program"]
local MODE=os.getenv("CORE_QMODE") or "neg"
local function s16(v) return (v~32768)-32768 end
_G.__q=r2:install_read_tap(0x80014,0x80015,"q",function(off,data,mask)
  local v=s16(data)
  if MODE=="neg" then v=-v else v=v-2*s16(sp:read_u16(0xf0230)) end
  return v & 0xffff end)
dofile(os.getenv("CORE_NEXT"))

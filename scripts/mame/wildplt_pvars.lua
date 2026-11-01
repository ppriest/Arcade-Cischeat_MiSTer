-- Load state CORE_STATE; for CORE_N frames log both road CPUs' P-path variables at frame end.
local OUT=os.getenv("CORE_OUT"); local m=manager.machine; local N=tonumber(os.getenv("CORE_N") or "12")
local r={m.devices[":road1cpu"].spaces["program"],m.devices[":road2cpu"].spaces["program"]}
local f=io.open(OUT.."/pvars.txt","w"); local k=-1
local function w(s,a) return s:read_u16(a) end
local function sw(v) if v>=0x8000 then return v-0x10000 end return v end
f:write("k  cpu aa b6 78 9a | P74 b4 | h40 h68 | ae c0 76 5c | 10c 15e\n")
core_s=emu.add_machine_frame_notifier(function()
  if k<0 then k=0; m:load(os.getenv('CORE_STATE') or '5'); return end
  k=k+1
  for n=1,2 do local s=r[n]
    f:write(string.format("%2d r%d %d %d %d %d | %5d %5d | %08x %08x | %08x %5d %5d %5d | %04x %04x\n",k,n,
      w(s,0x1800aa),w(s,0x1800b6),w(s,0x180078),w(s,0x18009a),sw(w(s,0x180074)),sw(w(s,0x1800b4)),
      s:read_u32(0x180040),s:read_u32(0x180068),s:read_u32(0x1800ae),sw(w(s,0x1800c0)),sw(w(s,0x180076)),sw(w(s,0x18005c)),w(s,0x18010c),w(s,0x18015e)))
  end
  if k>=N then f:close(); m:exit() end
end)

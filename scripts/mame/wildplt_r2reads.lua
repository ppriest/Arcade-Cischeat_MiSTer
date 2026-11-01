-- Log road CPU 2 reads outside ROM/work RAM: unmapped ranges, shared RAM and road RAM, with PC; then run wildplt_stick.lua.
local OUT=os.getenv("CORE_OUT")
local m=manager.machine
local cpu=m.devices[":road2cpu"]; local rp=cpu.spaces["program"]
local seen={}; local cnt={}
local function rec(kind,off)
  local pc=cpu.state["PC"].value
  local k=string.format("%s %06x pc %06x",kind,off,pc)
  cnt[k]=(cnt[k] or 0)+1
end
core_taps={}
local ranges={{"unm",0x040000,0x07ffff},{"shr",0x080000,0x087fff},{"unm",0x088000,0x0fffff},{"road",0x100000,0x1007ff},{"unm",0x100800,0x17ffff},{"unm",0x184000,0xffffff}}
for _,r in ipairs(ranges) do
  local kind=r[1]
  table.insert(core_taps, rp:install_read_tap(r[2],r[3],"r2"..r[2],function(off,data,mask) rec(kind,off) end))
end
core_end=emu.add_machine_stop_notifier(function()
  local f=io.open(OUT.."/r2reads.txt","w")
  local keys={} for k in pairs(cnt) do keys[#keys+1]=k end table.sort(keys)
  for _,k in ipairs(keys) do f:write(k," x",cnt[k],"\n") end
  f:close()
end)
dofile(os.getenv("CORE_SCRIPTDIR").."/wildplt_stick.lua")

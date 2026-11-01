-- Scale every camera script record (accel, vmax) in the 0x2fd00 table by CORE_SCALE in user1, then run wildplt_stick.lua (CORE_SCRIPTDIR).
local OUT=os.getenv("CORE_OUT"); local S=tonumber(os.getenv("CORE_SCALE") or "2.5")
local m=manager.machine
local sp=m.devices[":maincpu"].spaces["program"]
local rg=m.memory.regions[":user1"]
local lg=io.open(OUT.."/scale.txt","w")
local function s32(v) if v>=0x80000000 then return v-0x100000000 end return v end
local function u32(v) if v<0 then return v+0x100000000 end return v end
-- check the region accessor matches the CPU's view
local t=sp:read_u32(0x142970+4)
lg:write(string.format("check cpu %08x region %08x\n",t,rg:read_u32(0x42970+4)))
if rg:read_u32(0x42970+4)~=t then lg:write("region order mismatch\n"); lg:close(); m:exit(); return end
local done={}; local n=0
for e=0,19 do
  local p=sp:read_u32(0x2fd00+e*4)
  for k=1,400 do
    if not done[p] then
      done[p]=true
      for _,o in ipairs({0,4}) do
        local v=s32(sp:read_u32(p+o)); rg:write_u32(p-0x100000+o,u32(math.floor(v*S+0.5)))
      end
      n=n+1
    end
    if (sp:read_u16(p+10+8)&0x8000)~=0 then break end
    p=p+10
  end
end
lg:write(string.format("records scaled %d\n",n))
lg:write(string.format("0x1429ca now accel %d vmax %d\n",s32(sp:read_u32(0x1429ca)),s32(sp:read_u32(0x1429ce))))
lg:close()
dofile(os.getenv("CORE_SCRIPTDIR").."/wildplt_stick.lua")

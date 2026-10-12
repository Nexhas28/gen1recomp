package.path="./?.lua;./?/init.lua;"..package.path
local savedLove=love
love=require("tests.love_stub")
local T=require("tests.harness")

local preLoaded={}
for k in pairs(package.loaded) do preLoaded[k]=true end

local names={"map","ghosts","objects","scripting.space","field_view"}
local saved={}
for _,n in ipairs(names) do
  local k="src.core.game3."..n
  saved[k]={package.loaded[k]}
end

local obj={localId=1,x=2,y=3,graphicsId=5,movementType=0}
local mapDef={}
package.loaded["src.core.game3.map"]={world={
  {id="MAP_A",def=mapDef,ox=10,oy=0},
  {id="MAP_B",def=mapDef,ox=0,oy=20},
}}
package.loaded["src.core.game3.ghosts"]={forDraw=function() return nil end}
package.loaded["src.core.game3.objects"]={}
package.loaded["src.core.game3.scripting.space"]={
  bundle={events={MAP_A={objects={obj}},MAP_B={objects={obj}}}},
  neighborObjectState=function() return nil end,
  resolveObjectGraphicsId=function() return 7 end,
}
package.loaded["src.core.game3.field_view"]=nil

local ok,FV=pcall(require,"src.core.game3.field_view")
local function restore()
  for k in pairs(package.loaded) do
    if not preLoaded[k] then package.loaded[k]=nil end
  end
  for k,v in pairs(saved) do package.loaded[k]=v[1] end
  love=savedLove
end
if not ok then
  restore()
  error("field_view failed to load: "..tostring(FV))
end

local function up(fn,wanted)
  for i=1,100 do
    local name,value=debug.getupvalue(fn,i)
    if name==wanted then return value end
  end
  error("missing upvalue "..wanted)
end
local collect=up(up(FV.draw,"collectGame3Actors"),"collectNeighborActors")
T.check(type(collect)=="function","collect reachable")

local actors={}
collect(actors,0,"HOST",{},nil,nil)
T.eq(#actors,2,"two neighbor actors")
local a,b=actors[1],actors[2]
T.check(a~=b,"distinct actor tables")
T.check(a.ghost~=b.ghost,"distinct ghost ids")
T.check(a.x~=b.x and a.y~=b.y,"distinct positions")
T.eq(a.x,(10+2)*16,"a.x")
T.eq(b.y,(20+3)*16,"b.y")
T.check(next(a)~=nil,"actor populated")

local again={}
collect(again,0,"HOST",{},nil,nil)
T.check(again[1]==a and again[2]==b,"same host reuses pooled actors")

-- alternating hosts keep their own pools
local other={}
collect(other,0,"OTHER",{},nil,nil)
T.check(other[1]~=a and other[2]~=b,"different host has its own pool")
local back={}
collect(back,0,"HOST",{},nil,nil)
T.check(back[1]==a and back[2]==b,"returning to first host reuses its pool")
local other2={}
collect(other2,0,"OTHER",{},nil,nil)
T.check(other2[1]==other[1] and other2[2]==other[2],"alternating keeps second host pool")

-- LRU: hosts A,B,A,C -> A survives, B is evicted
FV.invalidate()
local la1,lb1,la2,lc1,la3,lb2={},{},{},{},{},{}
collect(la1,0,"A",{},nil,nil)
collect(lb1,0,"B",{},nil,nil)
collect(la2,0,"A",{},nil,nil)
collect(lc1,0,"C",{},nil,nil)
collect(la3,0,"A",{},nil,nil)
T.check(la2[1]==la1[1] and la3[1]==la1[1],"LRU keeps recently used host A")
collect(lb2,0,"B",{},nil,nil)
T.check(lb2[1]~=lb1[1],"LRU evicted host B")

-- nil host uses a sentinel pool
local n1,n2={},{}
collect(n1,0,nil,{},nil,nil)
collect(n2,0,nil,{},nil,nil)
T.check(n1[1]==n2[1],"nil host pooled")

-- invalidate resets
local pre={}
collect(pre,0,"OTHER",{},nil,nil)
FV.invalidate()
local post={}
collect(post,0,"OTHER",{},nil,nil)
T.check(post[1]~=pre[1],"invalidate resets pool")

restore()
T.finish("game3_field_view_neighbor_pool")

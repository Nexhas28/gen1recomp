package.path="./?.lua;./?/init.lua;"..package.path
love=require("tests.love_stub")
local T=require("tests.harness")
local R=require("src.core.game3.field_weather_rse")

-- tileOrigin/drawTiled are locals; reach them through upvalues of R.draw.
local function findUp(root,wanted,maxDepth)
  local seen,level={[root]=true},{root}
  for _=1,maxDepth do
    local nextLevel={}
    for _,fn in ipairs(level) do
      for i=1,200 do
        local name,value=debug.getupvalue(fn,i)
        if name==nil then break end
        if name==wanted and type(value)=="function" then return value end
        if type(value)=="function" and not seen[value] then
          seen[value]=true; nextLevel[#nextLevel+1]=value
        end
      end
    end
    level=nextLevel
  end
end
local tileOrigin=findUp(R.draw,"tileOrigin",6)
local drawTiled=findUp(R.draw,"drawTiled",6)
T.check(type(tileOrigin)=="function","tileOrigin not reachable from R.draw within depth 6 (renamed?)")
T.check(type(drawTiled)=="function","drawTiled not reachable from R.draw within depth 6 (renamed?)")

-- tileOrigin: always in the first off-screen period, floored.
local sx,sy=tileOrigin(10,20,0,0)
T.eq(sx,-118,"integer x origin")
T.eq(sy,-108,"integer y origin")
for _,v in ipairs({{0,0,0,0},{10.5,20.25,0.5,0.75},{63.9,1.1,-3.3,2.7},{0,0,64.5,-0.5},{300,500,40,12}}) do
  sx,sy=tileOrigin(v[1],v[2],v[3],v[4])
  T.eq(sx,math.floor(sx),"x floored")
  T.eq(sy,math.floor(sy),"y floored")
  T.check(sx<=-64 and sx>-128,"x within first tile period")
  T.check(sy<=-64 and sy>-128,"y within first tile period")
end

-- Recording stubs.
local gfx=love.graphics
local saved={}
for _,k in ipairs({"newSpriteBatch","newQuad","getColor","setColor","draw"}) do saved[k]=gfx[k] end
local color={1,1,1,1}
local batches,draws,clears={}, {}, 0
gfx.newQuad=function() return newproxy() end
gfx.getColor=function() return color[1],color[2],color[3],color[4] end
gfx.setColor=function(r,g,b,a) color={r,g,b,a or 1} end
gfx.draw=function(obj,x,y) if type(obj)=="table" and obj.isBatch then draws[#draws+1]={obj,x,y} end end
gfx.newSpriteBatch=function(_,cap)
  local b={isBatch=true,capacity=cap,adds={}}
  function b:add(_,x,y) self.adds[#self.adds+1]={x,y} end
  function b:clear() clears=clears+1; self.adds={} end
  function b:setColor() end
  batches[#batches+1]=b
  return b
end

local function newSheet(cols)
  return {image={},w=cols*8,h=64,cols=cols,quads={}}
end

-- Drawn tile origins = batch add positions + draw translation.
local function origins(sheet,cw,ch,baseX,baseY,ox,oy)
  draws={}
  drawTiled(sheet,0,baseX,baseY,ox,oy,cw,ch)
  local d=draws[#draws]
  local b=d[1]
  return b,d[2],d[3]
end

for _,cols in ipairs({8,16}) do -- 8: single quad per tile, 16: 64px frame built from 8x8 parts
  local perTile=cols==8 and 1 or 64
  for _,size in ipairs({{240,160},{320,180},{427,240}}) do
    local cw,ch=size[1],size[2]
    for _,off in ipairs({{0,0,0,0},{10,20,0,0},{63,1,5,3},{37.5,12.25,0,0},{200,130,-3,2},{64,64,0,0},{127,255,26,10}}) do
      local sheet=newSheet(cols)
      local b,tx,ty=origins(sheet,cw,ch,off[1],off[2],off[3],off[4])
      local osx,osy=tileOrigin(off[1],off[2],off[3],off[4])
      local label=("cols=%d %dx%d off=%s,%s"):format(cols,cw,ch,off[1],off[2])
      T.check(#b.adds<=b.capacity,"batch overflow "..label)
      -- distinct tile origins (parts of one tile share a tile origin)
      local seen,list={}, {}
      for _,a in ipairs(b.adds) do
        local px,py=a[1]+tx,a[2]+ty
        -- reduce part offsets (multiples of 8 within a tile) to the tile grid
        local gx=osx+math.floor((px-osx)/64)*64
        local gy=osy+math.floor((py-osy)/64)*64
        local key=gx..","..gy
        if not seen[key] then seen[key]=true; list[#list+1]={gx,gy} end
      end
      -- every origin lies on the original grid
      local onGrid=true
      for _,o in ipairs(list) do
        if (o[1]-osx)%64~=0 or (o[2]-osy)%64~=0 then onGrid=false end
      end
      T.check(onGrid,"tiles off original grid "..label)
      -- the original draws sx+64k <= cw; each of those that touches the canvas must be present
      local missing=0
      for y=osy,ch,64 do
        for x=osx,cw,64 do
          if x+64>0 and y+64>0 and not seen[x..","..y] then missing=missing+1 end
        end
      end
      T.eq(missing,0,"visible original tiles missing "..label)
      -- union of tiles covers the full canvas
      local minX,minY,maxX,maxY=math.huge,math.huge,-math.huge,-math.huge
      for _,o in ipairs(list) do
        minX=math.min(minX,o[1]); minY=math.min(minY,o[2])
        maxX=math.max(maxX,o[1]+64); maxY=math.max(maxY,o[2]+64)
      end
      T.check(minX<=0 and minY<=0 and maxX>=cw and maxY>=ch,"canvas not covered "..label)
      -- no fully off-screen wasted row/column on the left/top
      T.check(minX>-64 and minY>-64,"wasted off-screen tile row/column "..label)
      -- capacity is exact for the layout
      T.eq(#b.adds,(math.floor((cw+64)/64)+1)*(math.floor((ch+64)/64)+1)*perTile,"quad count "..label)
      T.eq(b.capacity,#b.adds,"capacity matches adds "..label)
    end
  end
end

-- Rebuild behaviour: scroll alone never rebuilds; size/colour/frame do.
do
  local sheet=newSheet(8)
  clears=0
  drawTiled(sheet,0,0,0,0,0,320,180)
  T.eq(clears,1,"first draw builds")
  for i=1,5 do drawTiled(sheet,0,i*13.5,i*7,0,0,320,180) end
  T.eq(clears,1,"scroll only does not rebuild")
  drawTiled(sheet,0,0,0,0,0,427,240)
  T.eq(clears,2,"canvas size change rebuilds")
  drawTiled(sheet,0,0,0,0,0,427,240)
  T.eq(clears,2,"repeat does not rebuild")
  color={1,1,1,0.5}
  drawTiled(sheet,0,0,0,0,0,427,240)
  T.eq(clears,3,"colour (blend) change rebuilds")
  drawTiled(sheet,0,5,5,0,0,427,240)
  T.eq(clears,3,"scroll under tint does not rebuild")
  color={1,1,1,1}
  drawTiled(sheet,0,0,0,0,0,427,240)
  T.eq(clears,3,"base and tint use separate batches, no rebuild on return")
  drawTiled(sheet,1,0,0,0,0,427,240)
  T.eq(clears,4,"frame change rebuilds")
  T.eq(color[4],1,"colour restored after draw")
end

for k,v in pairs(saved) do gfx[k]=v end
T.finish("game3_rse_weather_tile_origin")

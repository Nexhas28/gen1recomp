package.path="./?.lua;./?/init.lua;"..package.path
love=require("tests.love_stub")
local T=require("tests.harness")

local Space=require("src.core.game3.scripting.space")
local Ctx=require("src.core.game3.scripting.ctx")

local realProfile=package.loaded["src.core.game3.profile"]
local realConstants=package.loaded["src.core.game3.constants"]
local savedStore,savedVm=Space.store,Space.vm
local function restore()
  package.loaded["src.core.game3.profile"]=realProfile
  package.loaded["src.core.game3.constants"]=realConstants
  Space.store,Space.vm=savedStore,savedVm
  Space.invalidateGfxCache()
end

-- plain id, no profile quirks (stub profile without invalidGfx)
local plainProfile={id="firered",field={}}
package.loaded["src.core.game3.profile"]={forSession=function() return plainProfile end}
Space.invalidateGfxCache()
Space.store={flags={},vars={}}
Space.vm=nil

T.eq(Space.resolveObjectGraphicsId({graphicsId=5}),5,"plain graphicsId")
T.eq(Space.resolveObjectGraphicsId({graphics=7}),7,"plain graphics field")
T.eq(Space.resolveObjectGraphicsId({graphicsId=152}),16,"frlg >=152 clamps to 16")
T.eq(Space.resolveObjectGraphicsId(nil),nil,"nil obj")

-- graphicsVar: store var wins when non-zero
Space.store.vars[0x4020]=9
T.eq(Space.resolveObjectGraphicsId({graphicsId=5,graphicsVar=0x4020}),9,"graphicsVar store value wins")
Space.store.vars[0x4020]=0
T.eq(Space.resolveObjectGraphicsId({graphicsId=5,graphicsVar=0x4020}),5,"graphicsVar zero keeps base")

-- 240..255 var path
local obj={graphicsId=241}
local gv=Ctx.GFX_VAR_LO+1
Space.store.vars[gv]=11
T.eq(Space.resolveObjectGraphicsId(obj),11,"gfx var path reads own store")
local nbMissing={store={flags={},vars={}}}
T.eq(Space.resolveObjectGraphicsId(obj,nbMissing),nil,"neighbor store missing var -> nil")
local nbPresent={store={flags={},vars={[gv]=13}}}
T.eq(Space.resolveObjectGraphicsId(obj,nbPresent),13,"neighbor store with var")
-- own store without var, no neighbor: var reads 0
Space.store.vars[gv]=nil
T.eq(Space.resolveObjectGraphicsId(obj),0,"missing var without neighbor reads 0")

-- invalidGfx path with stub profile + constants
local byNameCalls=0
local E={NUM_OBJ_EVENT_GFX=100,OBJ_EVENT_GFX_FALLBACK=3}
package.loaded["src.core.game3.constants"]={of=function()
  byNameCalls=byNameCalls+1
  return {event_objects={byName=E}}
end}
local rseProfile={id="emerald",field={invalidGfx="OBJ_EVENT_GFX_FALLBACK"}}
package.loaded["src.core.game3.profile"]={forSession=function() return rseProfile end}
Space.invalidateGfxCache()
T.eq(Space.resolveObjectGraphicsId({graphicsId=50}),50,"in-range id unchanged")
T.eq(Space.resolveObjectGraphicsId({graphicsId=150}),3,"out-of-range id -> fallback")
T.eq(Space.resolveObjectGraphicsId({graphicsId=150}),3,"fallback again")
T.eq(byNameCalls,1,"constants lookup cached")
Space.invalidateGfxCache()
Space.resolveObjectGraphicsId({graphicsId=150})
T.eq(byNameCalls,2,"invalidateGfxCache forces re-lookup")

-- explicit profile parameter overrides per-call lookup
local calls=0
package.loaded["src.core.game3.profile"]={forSession=function() calls=calls+1; return rseProfile end}
T.eq(Space.resolveObjectGraphicsId({graphicsId=160},nil,plainProfile),16,"passed profile used (plain)")
T.eq(Space.resolveObjectGraphicsId({graphicsId=160},nil,false),16,"false profile: no profile quirks")
T.eq(calls,0,"no profile lookup when profile passed")
T.eq(Space.resolveObjectGraphicsId({graphicsId=150},nil,rseProfile),3,"passed invalidGfx profile")
T.eq(calls,0,"still no lookup")
T.eq(Space.resolveObjectGraphicsId({graphicsId=150}),3,"nil profile does lookup")
T.eq(calls,1,"one lookup")
T.eq(Space.gfxProfile(),rseProfile,"gfxProfile returns profile")
package.loaded["src.core.game3.profile"]={forSession=function() error("boom") end}
T.eq(Space.gfxProfile(),false,"gfxProfile false on error")

restore()
T.finish("game3_resolve_object_graphics_id")

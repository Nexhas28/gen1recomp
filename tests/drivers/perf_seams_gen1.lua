-- Perf driver (Gen 1): where does a seamless area change spend main-thread
-- time?  Wraps module functions for timing; walks a route chain with
-- setMap(seamless) and 20 idle frames between crossings.
--   PROBE_COLORS=redpp POKEPORT_IDENTITY=<sandbox> \
--     POKEPORT_DRIVER=tests/drivers/perf_seams_gen1.lua POKEPORT_TOUCH=0 love .
-- PROBE_SHOT=<png path> captures one frame in VIRIDIAN_CITY (worker on/off
-- comparison: run again with POKEPORT_NO_THREAD=1 and diff the PNGs).
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local PaletteFX = require("src.render.PaletteFX")
  local OW = require("src.world.OverworldController")
  local Map = require("src.world.Map")
  local TR = require("src.render.TileRenderer")
  local Music = require("src.core.Music")
  local P = dofile("tests/drivers/perf_util.lua")
  local now = P.now
  local acc = {}
  local patches = P.patches()
  local function sink(label, ms) acc[label] = (acc[label] or 0) + ms end
  local function wrap(tbl, name, label) patches:timed(tbl, name, label, sink) end
  wrap(Map, "new", "Map.new")
  wrap(TR, "new", "TileRenderer.new")
  wrap(OW, "rebuildNeighbors", "rebuildNeighbors")
  wrap(Music, "playMap", "Music.playMap")
  -- sync bakes (AtlasBake.bake on the main thread) and ready-store hits
  wrap(require("src.render.AtlasBake"), "bake", "syncBake")
  local AP = require("src.render.AtlasPrefetch")
  patches:replace(AP, "take", function(realTake)
    return function(key)
      local r = realTake(key)
      if r then acc.readyHit = (acc.readyHit or 0) + 1 end
      return r
    end
  end)
  -- background image decodes: store hits vs the files Assets still decodes here
  patches:replace(AP, "peekDecoded", function(realPeek)
    return function(path)
      local r = realPeek(path)
      acc[r and "decodeHit" or "decodeMiss"] = (acc[r and "decodeHit" or "decodeMiss"] or 0) + 1
      if not r and os.getenv("PROBE_MISS") then
        print("MISS", path, (debug.traceback("", 2):gsub("\n%s*", " | ")))
      end
      return r
    end
  end)
  wrap(love.graphics, "newImage", "newImage")
  wrap(PaletteFX, "worldGroupColors", "worldGroupColors")
  wrap(PaletteFX, "worldGroupAt", "worldGroupAt")
  wrap(require("src.render.Assets"), "imageData", "imageData")
  wrap(require("src.world.MapLoader"), "trim", "MapLoader.trim")
  wrap(OW, "computeNeighbors", "computeNeighbors")
  wrap(require("src.mods.Runtime"), "emit", "Runtime.emit")
  wrap(require("src.render.Assets"), "resolve", "resolve")
  wrap(require("src.render.TileRenderer"), "prefetchAtlas", "prefetchAtlas")
  wrap(OW, "rebuildGhosts", "rebuildGhosts")
  wrap(OW, "prefetchAtlases", "prefetchAtlases")
  wrap(OW, "setMap", "setMap_total")

  local ok, err = pcall(function()
    local mode = os.getenv("PROBE_COLORS") or "redpp"
    PaletteFX.setMode(mode)
    U.log("colors", PaletteFX.mode)
    U.teleport(game, "PALLET_TOWN", 5, 5)
    U.wait(30)
    local chain = { "ROUTE_1", "VIRIDIAN_CITY", "ROUTE_2", "PEWTER_CITY", "ROUTE_3",
      "ROUTE_4", "CERULEAN_CITY", "ROUTE_5", "SAFFRON_CITY", "ROUTE_8",
      "LAVENDER_TOWN", "ROUTE_12", "ROUTE_13", "ROUTE_14", "ROUTE_15",
      "FUCHSIA_CITY", "ROUTE_18", "ROUTE_17", "ROUTE_16", "CELADON_CITY",
      "ROUTE_7", "SAFFRON_CITY", "ROUTE_6", "VERMILION_CITY" }
    for _, id in ipairs(chain) do
      acc = {}
      local ow = game.overworld
      if os.getenv("PROBE_MISS") then print("STEP", id) end
      local t0 = now()
      ow:setMap(id, 5, 5, "up", { seamless = true, keepMusic = true })
      local total = (now() - t0) * 1000
      local parts = {}
      for k, v in pairs(acc) do parts[#parts + 1] = ("%s=%.1f"):format(k, v) end
      table.sort(parts)
      print(("SEAM %-16s total=%.1fms %s"):format(id, total, table.concat(parts, " ")))
      U.wait(20)
      local shot = os.getenv("PROBE_SHOT")
      if shot and id == "VIRIDIAN_CITY" then
        U.wait(20)
        U.shot(game, shot)
        U.log("shot", shot)
        if os.getenv("PROBE_SHOT_ONLY") then break end
      end
    end
  end)
  patches:restore()
  if not ok then print("SEAM ERROR " .. tostring(err)) end
  love.event.quit()
end

#!/usr/bin/env luajit
package.path = "./?.lua;./?/init.lua;" .. package.path
_G.love = _G.love or require("tests.love_stub")

local T = require("tests.harness")
local check = T.check

T.suite("pokedex metric units")

local Font = require("src.render.Font")
local drawn
local fontDraw = Font.draw
Font.draw = function(text) drawn[#drawn + 1] = tostring(text) end
local function has(text)
  for _, value in ipairs(drawn) do if value == text then return true end end
  return false
end

local DexEntryMenu = require("src.ui.DexEntryMenu")
local game = { save = { pokedex = { owned = {} } }, data = { text = {}, constants = {} } }
local metric = { id = "BULBASAUR", name = "BULBASAUR", dex = 1,
  dexEntry = { kind = "SEED", heightFt = 2, heightIn = 4, weight = 152, heightM = 0.7, weightKg = 6.9 } }
local imperial = { id = "BULBASAUR", name = "BULBASAUR", dex = 1,
  dexEntry = { kind = "SEED", heightFt = 2, heightIn = 4, weight = 152 } }

drawn = {}
DexEntryMenu.render(game, metric, nil, true)
check(has("GR. 0,7m") and has("GEW. 6,9kg"), "a caught Gen 1 entry prints its metric height and weight")
drawn = {}
DexEntryMenu.render(game, metric, nil, false)
check(has("GR. ???m") and has("GEW. ???kg"), "a seen Gen 1 entry prints the metric unknown masks")
check(not has("lb") and not has("???"), "a metric Gen 1 entry prints no imperial field")
drawn = {}
DexEntryMenu.render(game, metric, nil, false, nil, 1, { metricMasks = { "TAI ???m", "PDS ???kg" } })
check(has("TAI ???m") and has("PDS ???kg"), "the entry page prints the masks it resolved when it opened")
drawn = {}
DexEntryMenu.render(game, imperial, nil, false)
check(has("???") and has("lb") and not has("GR. ???m"), "an entry without metric values keeps the US fields")

Font.draw = fontDraw

T.finish("pokedex metric units")

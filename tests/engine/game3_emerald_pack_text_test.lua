-- Emerald screens that keep their own copy of a cart string read the script
-- cache's text for it when the cache holds it, the way script messages do,
-- so a mod's text overrides reach them; the pack's copy stays the fallback.

package.path = "./?.lua;./?/init.lua;" .. package.path

local function ir(s) return { { t = "text", s = s }, { t = "eos" } } end

local BUNDLE = { text = {} }
package.loaded["src.core.game3.scripting.space"] = { ensureBundle = function() return BUNDLE end }

local RomText = require("src.core.game3.rom_text")
local TextIR = require("src.core.game3.scripting.text_ir")

local failed = 0
local function check(cond, msg)
  if cond then
    print("[ok] " .. msg)
  else
    failed = failed + 1
    print("[FAIL] " .. msg)
  end
end
local function plain(x) return x and TextIR.toPlain(x, {}) or nil end

-- RomText.irOr / RomText.refIr
BUNDLE.text = { gText_RecordsLv50 = ir("NIVEAU 50"), ["g3:08abcdef"] = ir("PAR ADRESSE") }
check(plain(RomText.irOr("gText_RecordsLv50", ir("LV. 50"))) == "NIVEAU 50", "irOr reads the cached text")
check(plain(RomText.irOr("gText_Missing", ir("LV. 50"))) == "LV. 50", "irOr falls back on the copy")
check(plain(RomText.irOr(nil, ir("LV. 50"))) == "LV. 50", "irOr without a key keeps the copy")
check(plain(RomText.refIr({ name = "gText_RecordsLv50", key = "g3:08000000", ir = ir("LV. 50") })) == "NIVEAU 50",
  "refIr reads a reference by its symbol")
check(plain(RomText.refIr({ name = "sUnnamed", key = "g3:08abcdef", ir = ir("BY ADDRESS") })) == "PAR ADRESSE",
  "refIr reads a reference by its address")
check(plain(RomText.refIr({ name = "sUnnamed", key = "g3:08000000", ir = ir("COPY") })) == "COPY",
  "refIr falls back on the reference's copy")
check(RomText.refIr(nil) == nil, "refIr of no reference is nil")

-- Battle Dome tables, keyed by the table's label (extract_scripts.lua).
BUNDLE.text = { ["sBattleDomePotentialTexts[1]"] = ir("Fort potentiel") }
local Dome = require("src.core.game3.rse.frontier.dome")
local potential = { ir("Best candidate"), ir("Strong potential") }
check(plain(Dome.tableText(potential, "sBattleDomePotentialTexts", 2)) == "Fort potentiel",
  "a Dome table string reads the cached text by its label")
check(plain(Dome.tableText(potential, "sBattleDomePotentialTexts", 1)) == "Best candidate",
  "a Dome table string missing from the cache keeps the copy")

-- Apprentice messages are pack references.
local Apprentice = require("src.core.game3.rse.frontier.apprentice")
BUNDLE.text = { gText_ApprenticeWhichMon = ir("Lequel?") }
Apprentice.manifest = function()
  return { whichMon = { { { name = "gText_ApprenticeWhichMon", key = "g3:08000001", ir = ir("Which one?") },
    { name = "gText_ApprenticeThanks", key = "g3:08000002", ir = ir("Thanks!") } } } }
end
Apprentice.player = function() return { id = 0 } end
check(plain(Apprentice.message({}, Apprentice.MSG.WHICH_MON)) == "Lequel?", "an Apprentice line reads the cached text")
check(plain(Apprentice.message({}, Apprentice.MSG.THANKS_MON)) == "Thanks!",
  "an Apprentice line missing from the cache keeps the copy")

-- The Battle Pyramid bag's "Return to ..." line (pokeemerald/src/battle_pyramid_bag.c:687).
local Pyramid = require("src.core.game3.rse.frontier.pyramid")
local PyramidBag = require("src.ui.game3.rse.pyramid_bag")
Pyramid.bagCursor = { scroll = 0, cursor = 0 }
Pyramid.bagLists = function() return {}, {} end
Pyramid.manifest = function()
  return { bagReturnTo = { { name = "gText_TheField", key = "g3:08000003", ir = ir("the field") } } }
end
PyramidBag._st.count, PyramidBag._st.location = 1, "field"
BUNDLE.text = { gText_ReturnToVar1 = { { t = "text", s = "Retourner " }, { t = "strvar", n = 1 }, { t = "eos" } },
  gText_TheField = ir("au jeu") }
check(PyramidBag.description() == "Retourner au jeu", "the bag's return line names the place from the cache")
BUNDLE.text.gText_TheField = nil
check(PyramidBag.description() == "Retourner the field", "a place missing from the cache keeps the copy")

-- Ever Grande City's fly destinations (pokeemerald/src/region_map.c:343).
local RegionMap = require("src.ui.game3.rse.region_map")
RegionMap.manifest = function()
  return { multiNameFlyDestinations = { { names = { "POKéMON LEAGUE", "POKéMON CENTER" }, mapSecId = 5, flag = 2100 } } }
end
local function flySub()
  local s = { mapSecType = RegionMap.TYPE.CITY_CANFLY, mapSecId = 5, posWithinMapSec = 1, mapSecName = "EVER GRANDE",
    session = { flags = { [2100] = true } } }
  RegionMap.updateFlyText(s)
  return s.flyText.sub
end
BUNDLE.text = { ["sEverGrandeCityNames[1]"] = ir("CENTRE POKéMON") }
check(flySub() == "CENTRE POKéMON", "a fly destination reads its name from the cache")
BUNDLE.text = {}
check(flySub() == "POKéMON CENTER", "a fly destination missing from the cache keeps the copy")

-- The Pokédex search screen (pokeemerald/src/pokedex.c:1017, 1042, 1330).
local Gfx = require("src.ui.game3.rse.pokedex_gfx")
Gfx.manifest = function()
  return { search = {
    topBar = { { description = "Search for POKéMON based on selected parameters." } },
    items = { { description = "List by the first letter in the name." }, {}, {}, {}, {}, {},
      { description = "Execute search/switch." } },
    orders = { { title = "NUMERICAL", description = "Pokédex listing by number." },
      { title = "A TO Z", description = "Alphabetical order." } },
    types = { { title = "NONE" }, { title = "NORMAL" }, { title = "FIGHT" } },
  } }
end
local Pokedex = require("src.ui.game3.rse.pokedex")
BUNDLE.text = {
  gText_SearchForPkmnBasedOnParameters = ir("Chercher des POKéMON."),
  gText_ListByFirstLetter = ir("Classer par initiale."),
  gText_ExecuteSearchSwitch = ir("Lancer la recherche."),
  gText_DexSortNumericalTitle = ir("NUMERIQUE"),
  gText_DexSortNumericalDescription = ir("Classement par numéro."),
  ["gTypeNames[0]"] = ir("NORMAL"), ["gTypeNames[1]"] = ir("COMBAT"),
}
local orders = Pokedex.searchOptionTexts(Pokedex.SEARCH.ORDER)
check(orders[1].title == "NUMERIQUE" and orders[1].description == "Classement par numéro.",
  "a search option reads its title and description from the cart")
check(orders[2].title == "A TO Z" and orders[2].description == "Alphabetical order.",
  "a search option missing from the cache keeps the copy")
local types = Pokedex.searchOptionTexts(Pokedex.SEARCH.TYPE_LEFT)
check(types[1].title == "NONE" and types[3].title == "COMBAT", "type options read gTypeNames by type id")
check(Pokedex.topBarDescription(0) == "Chercher des POKéMON.", "a top bar description reads the cart's text")
check(Pokedex.itemDescription(0) == "Classer par initiale.", "a search item description reads the cart's text")
check(Pokedex.itemDescription(Pokedex.SEARCH.OK) == "Lancer la recherche.", "the OK item's description reads the cart's text")

if failed > 0 then
  print(failed .. " check(s) failed")
  os.exit(1)
end
print("all checks passed")

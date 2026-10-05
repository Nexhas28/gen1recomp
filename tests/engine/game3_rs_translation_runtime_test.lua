-- Ruby and Sapphire read the cart strings a translation mod overrides from
-- the script cache, where the mod's text overrides land, as Emerald does
-- (game3_emerald_pack_text_test.lua); the extract's or the pack's copy stays
-- the fallback.

package.path = "./?.lua;./?/init.lua;" .. package.path

local function ir(s) return { { t = "text", s = s }, { t = "eos" } } end

local BUNDLE = { text = {} }
package.loaded["src.core.game3.scripting.space"] = { ensureBundle = function() return BUNDLE end }

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

-- Expanded placeholders (pokeruby/src/string_util.c:476): the teams, their
-- leaders and legendaries by edition, the version, the rival and the
-- honorific.
local Extract = require("src.import.gba.text_placeholders_extract")
local ruby, sapphire = Extract.rsSymbols("ruby"), Extract.rsSymbols("sapphire")
check(ruby.EVIL_TEAM == "gExpandedPlaceholder_Magma" and sapphire.EVIL_TEAM == "gExpandedPlaceholder_Aqua",
  "the evil team is Magma in Ruby and Aqua in Sapphire")
check(ruby.GOOD_LEADER == "gExpandedPlaceholder_Archie" and sapphire.GOOD_LEADER == "gExpandedPlaceholder_Maxie",
  "the good team's leader follows the edition")
check(ruby.VERSION == "gExpandedPlaceholder_Ruby" and sapphire.VERSION == "gExpandedPlaceholder_Sapphire",
  "the version names the edition")
check(Extract.symbolsFor("emerald") == Extract.SYMBOLS, "Emerald keeps its own labels")

local Message = require("src.ui.game3.message")
BUNDLE.text = {
  gExpandedPlaceholder_Maxie = ir("MAX"), gExpandedPlaceholder_Archie = ir("ARTHUR"),
  gExpandedPlaceholder_Ruby = ir("RUBIS"), gExpandedPlaceholder_May = ir("FLORA"),
  gExpandedPlaceholder_Kun = ir("くん"),
}
local placeholders = Message.cartPlaceholders({
  EVIL_TEAM = "MAGMA", EVIL_LEADER = "MAXIE", GOOD_LEADER = "ARCHIE", VERSION = "RUBY",
  RIVAL_MALE = "MAY", RIVAL_FEMALE = "BRENDAN", KUN_MALE = "", KUN_FEMALE = "",
  byGender = { RIVAL = { male = "MAY", female = "BRENDAN" }, KUN = { male = "", female = "" } },
}, "ruby")
check(placeholders.EVIL_LEADER == "MAX" and placeholders.GOOD_LEADER == "ARTHUR",
  "the leaders' names read the cache by the edition's labels")
check(placeholders.VERSION == "RUBIS", "the version's name reads the cache")
check(placeholders.EVIL_TEAM == "MAGMA", "a placeholder missing from the cache keeps the copy")
check(placeholders.byGender.RIVAL.male == "FLORA", "the rival's name reads the cache")
local line = { { t = "player" }, { t = "ph", code = 5, name = "KUN" }, { t = "text", s = ": " },
  { t = "ph", code = 10, name = "EVIL_LEADER" }, { t = "text", s = " / " },
  { t = "ph", code = 6, name = "RIVAL" }, { t = "eos" } }
check(TextIR.toPlain(line, { dialect = "rs", playerName = "RED", playerGender = 0, placeholders = placeholders })
  == "REDくん: MAX / FLORA", "a Ruby line expands the honorific, the leader and the rival from the cache")
BUNDLE.text = { gExpandedPlaceholder_Archie = ir("ARTHUR"), gExpandedPlaceholder_Maxie = ir("MAX") }
local sapphireLine = Message.cartPlaceholders({ EVIL_LEADER = "ARCHIE", byGender = {} }, "sapphire")
check(sapphireLine.EVIL_LEADER == "ARTHUR", "Sapphire's evil leader is Archie's row")

-- The native Pokédex (src/ui/game3/rse/pokedex.lua): the entry's pages by
-- their own labels, its labels and the search screen by the labels the
-- packs name next to their copies.
local MANIFEST = {
  assetLayout = "rs",
  strings = { UnknownPoke = "            ????? POKéMON", CryOf = "\252\019\002CRY OF", RegisterComplete = "REGISTERED",
    UnknownHeight = "\252\019\012??'??\"", UnknownWeight = "????.? lbs.", SizeComparedTo = "SIZE COMPARED TO ",
    Searching = "Searching...", SearchComplete = "Search completed.", NoMatching = "No matching POKéMON.",
    RightPointingTriangle = ">" },
  search = {
    topBar = { { description = "Search for POKéMON.", descriptionKey = "DexText_SearchForPoke" } },
    items = { { description = "List by the first letter.", descriptionKey = "DexText_ListByABC" } },
    names = { { title = "ABC", titleKey = "DexText_ABC", description = "" } },
    colors = {}, types = {}, orders = {}, modes = {},
  },
}
package.loaded["src.ui.game3.rse.pokedex_gfx"] = setmetatable({ manifest = function() return MANIFEST end },
  { __index = function() return function() end end })
package.loaded["src.ui.game3.rse.mapsec"] = setmetatable({ readLua = function(path)
  if path:find("entries", 1, true) then
    return { [277] = { category = "WOOD GECKO", height = 5, weight = 50, description = "Ruby page one.",
      description2 = "Ruby page two.", descriptionLabel = "DexDescription_Treecko_1",
      descriptionLabel2 = "DexDescription_Treecko_2" } }
  end
  return { nationalToRegional = {} }
end }, { __index = function() return function() end end })
package.loaded["src.core.game3.pokemon"] = { speciesFromNational = function() return 277 end,
  name = function() return "ARCKO" end }
local Pokedex = require("src.ui.game3.rse.pokedex")
BUNDLE.text = {
  DexDescription_Treecko_2 = ir("Page deux."), gDexText_UnknownPoke = ir("            ????? POKéMON"),
  gDexText_CryOf = ir("CRI DE"), DexText_SearchForPoke = ir("Chercher des POKéMON."), DexText_ABC = ir("ABC FR"),
}
local function texts(rows)
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = row.text end
  return table.concat(out, "|")
end
local page1 = texts(Pokedex.monInfo({ descriptionPage = 0 }, 252, true, true, false))
local page2 = texts(Pokedex.monInfo({ descriptionPage = 1 }, 252, true, true, false))
check(page1:find("Ruby page one.", 1, true) ~= nil, "a page missing from the cache keeps the pack's copy")
check(page2:find("Page deux.", 1, true) ~= nil, "the second page reads the cache by its own label")
check(page1:find("WOOD GECKO POKéMON", 1, true) ~= nil, "the category keeps the cart's POKéMON after it")
check(Pokedex.topBarDescription(0) == "Chercher des POKéMON.", "the search top bar reads its own label")
check(Pokedex.itemDescription(0) == "List by the first letter.", "a search line missing from the cache keeps the copy")
check(Pokedex.searchOptionTexts(Pokedex.SEARCH.NAME)[1].title == "ABC FR", "a search option reads its own label")
-- pokeruby/src/pokedex.c:4228: only the English cart follows the category
-- with the word after its unknown-category string's question marks.
local function infoRow(owned, y)
  for _, row in ipairs(Pokedex.monInfo({ descriptionPage = 0 }, 252, true, owned, false)) do
    if row.y == y then return row.text end
  end
end
local function category(unknown)
  BUNDLE.text.gDexText_UnknownPoke = ir(unknown)
  return infoRow(true, 40)
end
check(category("            ????? POKéMON") == "WOOD GECKO POKéMON", "the English cart follows the category with POKéMON")
check(category("?????") == "WOOD GECKO", "the French and German carts print the category alone")
check(category("POKéMON ?????") == "WOOD GECKO", "so does the Italian cart, whose word comes first")
check(category("？？？？？ポケモン") == "WOOD GECKOポケモン", "the Japanese word follows the category without a space")
BUNDLE.text.gDexText_UnknownHeight = ir("???,?  m")
check(infoRow(false, 56) == "\252\019\012???,?  m", "a label keeps its copy's CLEAR_TO in front of the cache's text")
local Registry = require("src.import.gba.layouts.registry")
local active = Registry.active
Registry.active = function() return { id = "rs" } end
local Entries = require("src.import.gba.pokedex_entries_extract")
local function entriesCache(body) return { exists = function() return true end, read = function() return body end } end
check(not Entries.ready(entriesCache("return { [277] = { description = \"x\" } }")),
  "an R/S cache without the description labels extracts its entries again")
check(Entries.ready(entriesCache("return { [277] = { descriptionLabel = \"DexDescription_Treecko_1\" } }")),
  "an R/S cache with the labels keeps its entries")
Registry.active = active

if failed > 0 then
  print(failed .. " check(s) failed")
  os.exit(1)
end
print("all checks passed")

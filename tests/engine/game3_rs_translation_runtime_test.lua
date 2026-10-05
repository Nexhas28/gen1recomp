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

if failed > 0 then
  print(failed .. " check(s) failed")
  os.exit(1)
end
print("all checks passed")

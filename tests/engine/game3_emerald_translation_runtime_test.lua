package.path = "./?.lua;./?/init.lua;" .. package.path

local Strings = require("src.core.Strings")
local Pokemon = require("src.core.game3.pokemon")
local BattleText = require("src.core.game3.battle.battle_text")
local SummaryData = require("src.core.game3.summary_data")

Pokemon._abilityNames = { [9] = "STATIC" }
Pokemon._romAbilityNames = { [9] = "STATIC" }

-- pokeemerald/src/contest.c:3237
local ContestUI = require("src.ui.game3.rse.contest")
ContestUI.has = function(key) return key == "gContestEffectDescriptionPointers[1]" end
ContestUI.plain = function(key)
  if key == "gContestEffectDescriptionPointers[1]" then return "Startles the audience." end
  return key
end
local function contestMoveDescription()
  local view = setmetatable({
    c = { data = { moves = { [33] = { category = 0, effect = 1 } }, effects = { [1] = { appeal = 20, jam = 0 } } } },
    win = {},
    fillBox = function() end,
    fillBoxInc = function() end,
  }, { __index = ContestUI })
  view:printContestMoveDescription(33)
  return view.win[10].text
end

-- A modded ability past the built-in id table resolves to a key from its name.
local Adapter = require("src.core.game3.battle.adapter")
Pokemon._abilityNames[200] = "NEW SKILL"
Pokemon._romAbilityNames[200] = "NEW SKILL"
local function adapterAbilityKey()
  return Adapter.new({}):abilityOf({ ability = 200 })
end

Strings.load({})
assert(Pokemon.abilityName(9) == "STATIC",
  "an ability name keeps its English ROM value without translations")
assert(SummaryData.contestCategoryName("Cool") == "Cool",
  "a contest category keeps its English source without translations")
assert(SummaryData.contestEffectDescription({ description = "Startles the audience." })
    == "Startles the audience.",
  "a contest effect description keeps its English source without translations")
assert(contestMoveDescription() == "Startles the audience.",
  "the contest move window keeps its English effect text without translations")
assert(adapterAbilityKey() == "NEW_SKILL", "the battle adapter keys an unlisted ability by its ROM name")

Strings.load({ strings = {
  STATIC = "STATIQUE",
  Cool = "Sang-froid",
  ["Startles the audience."] = "Surprend le public.",
  ["NEW SKILL"] = "NOUVEAU TALENT",
} })
assert(Pokemon.abilityName(9) == "STATIQUE",
  "the shared ability-name getter translates the displayed name")
assert(Pokemon.romAbilityName(9) == "STATIC",
  "the original ROM name stays available for stable ID lookups")
assert(BattleText.RESOLVE_RSE[0x17]({ lastAbility = 9 }) == "STATIQUE",
  "the RSE battle ability placeholder uses the translated shared getter")
assert(SummaryData.contestCategoryName("Cool") == "Sang-froid",
  "the move relearner translates the contest category source")
assert(SummaryData.contestEffectDescription({ description = "Startles the audience." })
    == "Surprend le public.",
  "the RSE summary and move relearner translate the contest effect source")
assert(contestMoveDescription() == "Surprend le public.",
  "the contest move window translates the effect text like the summary")
assert(Pokemon.abilityName(200) == "NOUVEAU TALENT", "the display name is translated")
assert(adapterAbilityKey() == "NEW_SKILL",
  "the battle adapter keeps keying on the ROM name when the display name is translated")

print("game3_emerald_translation_runtime_test: PASS")

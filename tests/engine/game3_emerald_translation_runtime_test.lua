package.path = "./?.lua;./?/init.lua;" .. package.path

local Strings = require("src.core.Strings")
local Pokemon = require("src.core.game3.pokemon")
local BattleText = require("src.core.game3.battle.battle_text")

Pokemon._abilityNames = { [9] = "STATIC" }
Pokemon._romAbilityNames = { [9] = "STATIC" }

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
assert(adapterAbilityKey() == "NEW_SKILL", "the battle adapter keys an unlisted ability by its ROM name")

Strings.load({ strings = {
  STATIC = "STATIQUE",
  ["NEW SKILL"] = "NOUVEAU TALENT",
} })
assert(Pokemon.abilityName(9) == "STATIQUE",
  "the shared ability-name getter translates the displayed name")
assert(Pokemon.romAbilityName(9) == "STATIC",
  "the original ROM name stays available for stable ID lookups")
assert(BattleText.RESOLVE_RSE[0x17]({ lastAbility = 9 }) == "STATIQUE",
  "the RSE battle ability placeholder uses the translated shared getter")
assert(Pokemon.abilityName(200) == "NOUVEAU TALENT", "the display name is translated")
assert(adapterAbilityKey() == "NEW_SKILL",
  "the battle adapter keeps keying on the ROM name when the display name is translated")

print("game3_emerald_translation_runtime_test: PASS")

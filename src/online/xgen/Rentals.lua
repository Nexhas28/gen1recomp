local Datasets = require("src.online.xgen.Datasets")
local Policy = require("src.online.xgen.Policy")
local Project = require("src.online.xgen.Project")

local Rentals = {}

Rentals.VERSION = 1
Rentals.LEVEL = 50
Rentals.IV = 20
Rentals.PERSONALITY = 150

Rentals.DEFINITIONS = {
  ["g3u-gen1"] = {
    { type = "NORMAL", species = 128, moves = { 70, 33, 59, 87 } },
    { type = "FIGHTING", species = 68, moves = { 66, 67, 126, 89 } },
    { type = "FLYING", species = 142, moves = { 17, 126, 36, 44 } },
    { type = "POISON", species = 89, moves = { 124, 87, 126, 1 } },
    { type = "GROUND", species = 28, moves = { 89, 70, 40, 163 } },
    { type = "ROCK", species = 76, moves = { 157, 88, 126, 89 } },
    { type = "BUG", species = 127, moves = { 66, 70, 11, 15 } },
    { type = "GHOST", species = 94, moves = { 122, 87, 94, 70 } },
    { type = "FIRE", species = 59, moves = { 126, 53, 36, 52 } },
    { type = "WATER", species = 130, moves = { 56, 57, 59, 87 } },
    { type = "GRASS", species = 3, moves = { 75, 22, 15, 33 } },
    { type = "ELECTRIC", species = 135, moves = { 87, 84, 36, 44 } },
    { type = "PSYCHIC", species = 97, moves = { 94, 93, 29, 1 } },
    { type = "ICE", species = 124, moves = { 59, 8, 94, 1 } },
    { type = "DRAGON", species = 149, moves = { 59, 87, 126, 57 } },
  },
  ["g3u-gen2"] = {
    { type = "NORMAL", species = 128, moves = { 70, 30, 59, 87 } },
    { type = "FIGHTING", species = 68, moves = { 223, 238, 126, 89 } },
    { type = "FLYING", species = 18, moves = { 17, 16, 211, 185 } },
    { type = "POISON", species = 89, moves = { 188, 124, 87, 126 } },
    { type = "GROUND", species = 51, moves = { 89, 189, 188, 163 } },
    { type = "ROCK", species = 76, moves = { 157, 88, 126, 89 } },
    { type = "BUG", species = 127, moves = { 66, 70, 168, 11 } },
    { type = "GHOST", species = 94, moves = { 247, 122, 87, 94 } },
    { type = "STEEL", species = 208, moves = { 231, 89, 21, 157 } },
    { type = "FIRE", species = 59, moves = { 126, 53, 231, 36 } },
    { type = "WATER", species = 130, moves = { 56, 57, 59, 87 } },
    { type = "GRASS", species = 3, moves = { 202, 75, 15, 22 } },
    { type = "ELECTRIC", species = 135, moves = { 87, 84, 231, 36 } },
    { type = "PSYCHIC", species = 65, moves = { 94, 60, 247, 7 } },
    { type = "ICE", species = 124, moves = { 59, 8, 94, 247 } },
    { type = "DRAGON", species = 149, moves = { 225, 239, 59, 87 } },
    { type = "DARK", species = 197, moves = { 44, 185, 231, 36 } },
  },
  ["g3u-gen3"] = {
    { type = "NORMAL", species = 128, moves = { 70, 290, 59, 87 } },
    { type = "FIGHTING", species = 68, moves = { 223, 238, 126, 89 } },
    { type = "FLYING", species = 18, moves = { 17, 332, 211, 290 } },
    { type = "POISON", species = 89, moves = { 188, 124, 87, 126 } },
    { type = "GROUND", species = 51, moves = { 89, 189, 188, 161 } },
    { type = "ROCK", species = 76, moves = { 157, 88, 38, 126 } },
    { type = "BUG", species = 127, moves = { 89, 66, 70, 185 } },
    { type = "GHOST", species = 94, moves = { 247, 325, 87, 94 } },
    { type = "STEEL", species = 208, moves = { 231, 89, 21, 157 } },
    { type = "FIRE", species = 59, moves = { 315, 126, 231, 36 } },
    { type = "WATER", species = 130, moves = { 56, 57, 59, 87 } },
    { type = "GRASS", species = 3, moves = { 202, 345, 89, 188 } },
    { type = "ELECTRIC", species = 135, moves = { 87, 85, 231, 36 } },
    { type = "PSYCHIC", species = 65, moves = { 94, 60, 231, 247 } },
    { type = "ICE", species = 124, moves = { 59, 58, 94, 247 } },
    { type = "DRAGON", species = 149, moves = { 337, 225, 59, 87 } },
    { type = "DARK", species = 197, moves = { 44, 185, 231, 36 } },
  },
}

function Rentals.definitions(rulesetId)
  return Project.copy(Rentals.DEFINITIONS[rulesetId])
end

local function hasType(types, want)
  for _, t in ipairs(types or {}) do
    if t == want then return true end
  end
  return false
end

function Rentals.validate(def, ruleset, data, unsupported)
  local sp = data.species[def.species]
  if def.species > ruleset.dexMax or not sp then return "species_not_in_ruleset" end
  if not hasType(sp.types, def.type) then return "rental_type_mismatch" end
  local seen = {}
  for _, move in ipairs(def.moves) do
    if seen[move] then return "rental_duplicate_move", { move = move } end
    seen[move] = true
    if move > ruleset.moveMax or not data.moves[move] then return "move_not_in_ruleset", { move = move } end
    if unsupported and unsupported[move] then return "move_unsupported", { move = move } end
    if not Datasets.learnable(data, def.species, move, Rentals.LEVEL) then return "move_not_legal", { move = move } end
  end
  if #def.moves < 1 or #def.moves > Policy.MAX_MOVES then return "rental_bad_moves" end
  return nil
end

function Rentals.build(rulesetId, data, opts)
  opts = opts or {}
  local ruleset = Policy.ruleset(rulesetId)
  local out = { version = Rentals.VERSION, ruleset = rulesetId, rentals = {}, excluded = {} }
  local defs = Rentals.DEFINITIONS[rulesetId]
  if not ruleset or not defs then
    out.excluded[1] = { code = "unknown_ruleset", detail = { ruleset = rulesetId } }
    return out
  end
  if type(data) ~= "table" then
    out.excluded[1] = { code = "missing_import" }
    return out
  end
  local unsupported = {}
  for k, v in pairs(opts.unsupported or {}) do
    if v == true then unsupported[tonumber(k) or k] = true elseif tonumber(v) then unsupported[tonumber(v)] = true end
  end
  for index, def in ipairs(defs) do
    local code, detail = Rentals.validate(def, ruleset, data, unsupported)
    if code then
      out.excluded[#out.excluded + 1] = { index = index, type = def.type, species = def.species, code = code, detail = detail }
    else
      local ivs, evs = {}, {}
      for _, k in ipairs(Policy.STAT_ORDER) do ivs[k], evs[k] = Rentals.IV, 0 end
      local view = { gen = 3, national = def.species, level = Rentals.LEVEL, ivs = ivs, evs = evs,
        personality = Rentals.PERSONALITY, nature = Rentals.PERSONALITY % 25, otId = 0, otSecretId = 0,
        abilityNum = 0, item = 0, moves = {} }
      for _, move in ipairs(def.moves) do view.moves[#view.moves + 1] = { move = move, ppUps = 0 } end
      local record = Project.battleMon(view, data, { legacyPresent = opts.legacyPresent ~= false, rental = true })
      record.nickname = data.species[def.species].name
      local disclosed = {}
      for _, move in ipairs(def.moves) do disclosed[#disclosed + 1] = Project.moveRecord(data, move, 0) end
      out.rentals[#out.rentals + 1] = { rental = true, index = index, type = def.type, national = def.species,
        name = data.species[def.species].name, types = Project.copy(data.species[def.species].types),
        level = Rentals.LEVEL, record = record, moves = disclosed,
        stats = { hp = record.maxHp, atk = record.atk, def = record.def, spAtk = record.spAtk,
          spDef = record.spDef, speed = record.speed } }
    end
  end
  return out
end

return Rentals

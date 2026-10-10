-- Perf tour (Gen 1): times the one-off main-thread costs that cause hitches
-- on low-power handhelds (map loads, battles, first-play audio, menus, COLORS).
-- Each step prints `TOUR <step> call=<ms>ms` for the triggering call itself;
-- the following ~60 frames then run so FrameProfiler sees follow-on cost.
--   POKEPORT_IDENTITY=<sandbox> POKEPORT_DRIVER=tests/drivers/perf_tour_gen1.lua \
--     POKEPORT_GAME_PROF=all POKEPORT_TOUCH=0 love .
-- Quits through love.event.quit() so FrameProfiler.finish() prints PROF.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Sound = require("src.core.Sound")
  local ChipAudio = require("src.core.ChipAudio")
  local Pokemon = require("src.pokemon.Pokemon")
  local BattleState = require("src.battle.BattleState")
  local PaletteFX = require("src.render.PaletteFX")
  local Screens = require("src.ui.Screens")

  local P = dofile("tests/drivers/perf_util.lua")
  local function step(name, fn, settle) P.step(U, name, fn, settle) end

  local bootSpecies = game.save.party and game.save.party[1]
    and game.save.party[1].species
  game.save.party = {}
  for _, s in ipairs({ { "CHARIZARD", 36 }, { "PIKACHU", 30 }, { "BLASTOISE", 36 } }) do
    table.insert(game.save.party, Pokemon.new(game.data, s[1], s[2]))
  end

  -- 1. map loads (first visits, then revisits)
  local maps = game.data.maps or {}
  -- U.teleport waits 5 frames inside, which would bury the load cost in the
  -- timing; push directly so call= is just the load, frames follow in `settle`
  local function jump(id)
    while game.stack:top() do game.stack:pop() end
    game.stack:push(require("src.world.OverworldController"), id, 5, 5, "down")
  end
  local function warp(id)
    if not maps[id] then
      U.log("skip unknown map", id)
      return false
    end
    step("map_" .. id, function()
      jump(id)
    end)
    return true
  end
  local list = { "PALLET_TOWN", "ROUTE_1", "VIRIDIAN_CITY", "VIRIDIAN_FOREST",
    "PEWTER_CITY", "MT_MOON_1F", "CERULEAN_CITY", "VERMILION_CITY",
    "CELADON_CITY", "SAFFRON_CITY", "SILPH_CO_1F", "FUCHSIA_CITY",
    "CINNABAR_ISLAND", "INDIGO_PLATEAU" }
  for _, id in ipairs(list) do warp(id) end
  step("map_PALLET_TOWN_revisit", function() jump("PALLET_TOWN") end)
  step("map_CELADON_CITY_revisit", function() jump("CELADON_CITY") end)

  -- 2. walk a few steps in a big city
  step("walk_celadon", function() U.hold(game, "right", 60) end, 10)

  -- 3. battles
  local ow = game.overworld
  local function endBattle()
    while game.stack:top() and game.stack:top() ~= ow do game.stack:pop() end
  end
  if ow then
    local wild = BattleState.newWild(game, "RATTATA", 5)
    wild.onFinish = function() end
    step("battle_wild_push", function() ow:pushBattle(wild) end, 180)
    step("battle_wild_exit", endBattle, 60)

    local trainers = game.data.trainers or {}
    local cls = trainers.OPP_BUG_CATCHER and "OPP_BUG_CATCHER" or next(trainers)
    if cls then
      local tb = BattleState.newTrainer(game, cls, 1)
      tb.onFinish = function() end
      step("battle_trainer_push", function() ow:pushBattle(tb) end, 180)
      step("battle_trainer_exit", endBattle, 60)
    else
      U.log("skip trainer battle: no trainers")
    end
  end

  -- 4a. boot prewarm probe: nothing has played these yet and nothing has
  -- invalidated the cache since game load, so ~0.03ms means the load-time
  -- Game:prewarmCommonAudio prewarm survived; ~40-100ms means it did not.
  do
    local s0 = (game.data.audio or {}).sfx or {}
    for _, n in ipairs({ "Heal_HP", "Get_Item1" }) do
      if s0[n] then
        step("boot_sfx_" .. n, function() Sound.play(game.data, n) end, 20)
      end
    end
    if bootSpecies then
      step("boot_cry_" .. bootSpecies,
        function() Sound.playCry(game.data, bootSpecies) end, 20)
    end
  end

  -- 4. audio.  Sound + ChipAudio invalidate empty the caches so every variant starts
  -- cold (the boot-time prewarm would otherwise have warmed these already).
  local sfx = (game.data.audio or {}).sfx or {}
  local sfxNames = {}
  for _, n in ipairs({ "Start_Menu", "Press_AB", "Collision", "Level_Up",
      "Heal_HP", "Get_Item1" }) do
    if sfx[n] then sfxNames[#sfxNames + 1] = n end
  end
  local cries = { "CHARIZARD", "SNORLAX", "MEWTWO" }
  local function playAll(tag)
    for _, n in ipairs(sfxNames) do
      step("sfx_" .. tag .. "_" .. n, function() Sound.play(game.data, n) end, 20)
    end
    for _, sp in ipairs(cries) do
      step("cry_" .. tag .. "_" .. sp, function() Sound.playCry(game.data, sp) end, 30)
    end
  end
  -- waits (in frames) for the chip worker's prewarm queue to go idle
  local function waitPrewarmIdle(label)
    local frames = 0
    local function busy()
      local st = ChipAudio._effectStateForTest()
      return st.queued + st.inFlight > 0
    end
    while busy() and frames < 1800 do
      U.wait(1)
      frames = frames + 1
    end
    print(("TOUR %s prewarm_idle_after=%d frames idle=%s"):format(
      label, frames, tostring(not busy())))
  end

  -- (b) no prewarm: today's synchronous first-play cost
  Sound.invalidate(); ChipAudio.invalidate()
  playAll("noprewarm")
  -- (a) prewarm, wait for the worker, then first play
  Sound.invalidate(); ChipAudio.invalidate()
  for _, n in ipairs(sfxNames) do Sound.prewarmSfx(game.data, n) end
  for _, sp in ipairs(cries) do Sound.prewarmCry(game.data, sp) end
  waitPrewarmIdle("audio")
  playAll("prewarmed")
  -- cached replays for reference
  playAll("cached")

  -- battle-creation prewarm: create the battle (do NOT push it, or the
  -- intro would play the cry itself), wait a normal transition length, then
  -- time the first cry and move sound
  local function battleAudio(tag, make, transitionFrames)
    Sound.invalidate(); ChipAudio.invalidate()
    local battle
    step("battle_create_" .. tag, function() battle = make() end, 0)
    U.wait(transitionFrames)
    local st = ChipAudio._effectStateForTest()
    print(("TOUR battle_%s after %d frames: queued=%d inflight=%d ready=%d"):format(
      tag, transitionFrames, st.queued, st.inFlight, st.ready))
    local enemy = battle.enemy and battle.enemy.mon
    local species = enemy and enemy.species
    local moveId = enemy and enemy.moves and enemy.moves[1]
      and enemy.moves[1].id
    local mdef = moveId and game.data.moves[moveId]
    step("battle_" .. tag .. "_enemy_cry_" .. tostring(species), function()
      Sound.playCry(game.data, species)
    end, 20)
    if mdef and mdef.anim then
      step("battle_" .. tag .. "_move_" .. tostring(moveId), function()
        Sound.playMove(game.data, mdef.anim)
      end, 20)
    end
  end
  battleAudio("wild", function() return BattleState.newWild(game, "RATTATA", 5) end, 90)
  do
    local trainers = game.data.trainers or {}
    local cls = trainers.OPP_BROCK and "OPP_BROCK" or next(trainers)
    if cls then
      battleAudio("trainer", function()
        return BattleState.newTrainer(game, cls, 1)
      end, 90)
    end
  end

  -- 5. menus
  ow = game.overworld
  if ow then
    U.teleport(game, "CELADON_CITY", 5, 5, "down")
    U.wait(30)
    step("menu_start_open", function() Screens.push(game, "StartMenu") end, 30)
    step("menu_party_open", function() Screens.push(game, "PartyMenu", {}) end, 30)
    step("menu_close_all", function()
      while game.stack:top() and game.stack:top() ~= game.overworld do game.stack:pop() end
    end, 30)
  end

  -- 6. COLORS mode (rebuilds atlases)
  local before = PaletteFX.mode
  step("colors_cycle_1", function() PaletteFX.cycleMode() end, 60)
  step("colors_cycle_2", function() PaletteFX.cycleMode() end, 60)
  step("colors_restore", function() PaletteFX.setMode(before) end, 60)

  print("TOUR done")
  love.event.quit()
  while true do coroutine.yield() end
end

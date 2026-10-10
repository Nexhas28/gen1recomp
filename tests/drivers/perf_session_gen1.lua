-- Perf session (Gen 1): ~3-4 minutes of busy, realistic play for CPU/GC
-- measurement.  Prints `PHASE <name> start/end frame=<n>` around each phase so
-- FrameProfiler spikes (by frame number) can be attributed.  Measuring only:
-- it changes no game code.  Run under jit.p / GC probe, e.g.
--   POKEPORT_IDENTITY=prof-red-fresh1 POKEPORT_DRIVER=tests/drivers/perf_session_gen1.lua \
--     POKEPORT_GAME_PROF=all POKEPORT_GC_PROBE=1 POKEPORT_JITP=Fl2 \
--     POKEPORT_JITP_OUT=jitp.txt POKEPORT_TOUCH=0 ALSOFT_DRIVERS=null love .
-- Frame numbers are driver frames (U.frame()), which the PROF spike `frame=`
-- values (post-warmup count) track to within the 60 warmup frames.
-- SHADER FX is skipped: it needs a .slangp preset in the save dir's shaders/.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pokemon = require("src.pokemon.Pokemon")
  local BattleState = require("src.battle.BattleState")
  local PaletteFX = require("src.render.PaletteFX")
  local Screens = require("src.ui.Screens")
  local Tilt = require("src.render.Tilt")

  PaletteFX.setMode("redpp")

  -- U.hold yields without bumping U.frame(), so count held frames here
  local held = 0
  local function frameNo() return U.frame() + held end
  local function hold(btn, n) held = held + n; U.hold(game, btn, n) end

  local P = dofile("tests/drivers/perf_util.lua")
  local function phase(name, fn) P.phase(name, fn, frameNo) end

  -- { species, level, { move ids } }: slot 1 must be a strong damaging move
  -- because the fight mashes A on the first menu entry
  local function setParty(list)
    game.save.party = {}
    for _, s in ipairs(list) do
      local mon = Pokemon.new(game.data, s[1], s[2])
      if s[3] then
        mon.moves = {}
        for _, id in ipairs(s[3]) do
          local mdef = game.data.moves[id]
          if mdef then mon.moves[#mon.moves + 1] = { id = id, pp = mdef.pp } end
        end
      end
      table.insert(game.save.party, mon)
    end
  end

  -- walk `frames` frames; turn at walls (position unchanged for 20 frames)
  local DIRS = { "right", "up", "left", "down" }
  local function walk(frames, startDir)
    local di = startDir or 1
    local last, still = nil, 0
    local f = 0
    while f < frames do
      local ow = game.overworld
      local p = ow and ow.player
      local pos = p and (p.cellX .. "," .. p.cellY) or "?"
      if pos == last then still = still + 1 else still = 0 end
      last = pos
      if still >= 20 then di = di % #DIRS + 1; still = 0 end
      hold(DIRS[di], 8)
      f = f + 8
    end
  end

  local function backToOverworld()
    while game.stack:top() and game.stack:top() ~= game.overworld do
      game.stack:pop()
    end
  end

  -- mash A (with an occasional B) until the battle leaves the stack, or the
  -- budget (frames) runs out: then it is cut off like perf_tour's endBattle
  local function fight(name, battle, budget)
    battle.onFinish = function() end
    game.overworld:pushBattle(battle)
    local n = 0
    while game.stack:top() ~= game.overworld and n < budget do
      -- the "will you change POKEMON?" prompt (trainer's next mon) opens the
      -- party menu on YES: back out with B so the fight carries on
      local top = game.stack:top()
      U.tap(game, (top ~= battle and top ~= game.overworld) and "b" or "a")
      U.wait(3)
      n = n + 4
      if n % 400 == 0 then U.tap(game, "b") end
    end
    if game.stack:top() ~= game.overworld then
      print(("PHASE %s timeout frame=%d"):format(name, frameNo()))
    end
    print(("FIGHT %s ended after %d frames, finished=%s"):format(
      name, n, tostring(game.stack:top() == game.overworld)))
    backToOverworld()
  end

  U.wait(5)
  setParty({ { "BLASTOISE", 24, { "WATER_GUN", "TACKLE" } }, { "PIKACHU", 20, { "THUNDERBOLT" } } })
  U.teleport(game, "CELADON_CITY", 41, 12, "down")
  U.wait(60)

  phase("overworld_celadon", function() walk(1200, 1) end)

  phase("seam_pallet_route1", function()
    U.teleport(game, "PALLET_TOWN", 10, 3, "up")
    hold("up", 90)   -- across the north seam into ROUTE_1
    hold("down", 90) -- and back
    hold("up", 90)
    hold("down", 90)
  end)

  phase("door_warp", function()
    U.teleport(game, "CELADON_CITY", 41, 10, "up") -- in front of the door
    hold("up", 40) -- into the POKECENTER
    U.wait(90)
    hold("up", 24)
    hold("down", 60) -- back out
    U.wait(90)
  end)

  phase("overworld_saffron", function()
    -- stand on the street just below the first door (door tiles are warps)
    local w = game.data.maps.SAFFRON_CITY.warps[1]
    U.teleport(game, "SAFFRON_CITY", w.x, w.y + 1, "down")
    U.wait(60)
    walk(1800, 2)
  end)

  phase("battle_wild", function()
    U.teleport(game, "CELADON_CITY", 41, 12, "down")
    fight("battle_wild", BattleState.newWild(game, "RATTATA", 18), 2400)
    U.wait(60)
  end)

  phase("battle_trainer", function()
    setParty({ { "CHARIZARD", 50, { "FLAMETHROWER", "SLASH" } }, { "PIKACHU", 30, { "THUNDERBOLT" } }, { "BLASTOISE", 50, { "SURF", "BODY_SLAM" } } })
    local trainers = game.data.trainers or {}
    local cls = trainers.OPP_BROCK and "OPP_BROCK" or next(trainers)
    fight("battle_trainer", BattleState.newTrainer(game, cls, 1), 3600)
    U.wait(60)
  end)

  phase("menus", function()
    U.teleport(game, "CELADON_CITY", 41, 12, "down")
    U.wait(30)
    local function open(name, args, scroll)
      Screens.push(game, name, args or {})
      U.wait(40)
      for _ = 1, scroll or 0 do U.tap(game, "down"); U.wait(6) end
      for _ = 1, (scroll or 0) / 2 do U.tap(game, "up"); U.wait(6) end
      backToOverworld()
      U.wait(20)
    end
    Screens.push(game, "StartMenu")
    U.wait(40)
    for _ = 1, 4 do U.tap(game, "down"); U.wait(8) end
    backToOverworld(); U.wait(20)
    open("PartyMenu", {}, 4)
    open("BagMenu", {}, 6)
    open("PokedexMenu", nil, 40)
  end)

  phase("tilt_walk", function()
    game:keypressed("3") -- 15 deg
    U.wait(1)
    game:keypressed("3") -- 35 deg
    U.wait(30)
    print("TILT level", Tilt.level)
    walk(1200, 3)
    while Tilt.level ~= 0 do game:keypressed("3"); U.wait(1) end
    U.wait(30)
  end)

  phase("survey_zoom_walk", function()
    game:zoomStep(-2)
    U.wait(30)
    walk(1200, 4)
    game:zoomStep(2)
    U.wait(30)
  end)

  print("PHASE all done frame=" .. frameNo())
  love.event.quit()
  while true do coroutine.yield() end
end

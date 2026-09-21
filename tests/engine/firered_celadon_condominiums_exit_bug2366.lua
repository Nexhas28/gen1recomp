-- #2366: the Celadon Condominiums interior (the "Celadon Mansion" the reporter
-- walked into) could be entered but never left -- the player was softlocked
-- inside, with no way back out of the front or the rear door.
--
-- Ground truth: pret/pokefirered data/layouts/CeladonCity_Condominiums_1F/map.bin
-- (15x20 u16 cells: mid | coll << 10 | elev << 12) plus the `building` (primary)
-- and `condominiums` (secondary) metatile_attributes. The map header carries SIX
-- warps: (11,19), (12,18) and (13,19) out to CeladonCity dest_warp_id 3, (2,1)
-- out to CeladonCity dest_warp_id 11 (the rear door), and (4,2)/(12,2) up to 2F.
-- (Those are pret's 0-based ids; the extractor stores id+1 -- see WARPS below.)
-- (11,19) and (13,19) are solid wall tiles, so they never fire in pret either.
-- Of the rest, the two exit mats are what this test is about:
--
--   mid 740 at (2,1)   -> 0x60 MB_CAVE_DOOR
--   mid 745 at (12,18) -> 0x65 MB_SOUTH_ARROW_WARP   (the exit mats)
--   mid 753 at (4,2)/(12,2) -> 0x6C MB_UP_RIGHT_STAIR_WARP
--
-- The engine's exported behavior table for this tileset pair does not reach
-- mid 740/745/753: its secondary entry carries only 24 metatiles
-- (attr_bytes = 96, the mis-sized `pretty_petals_flower_shop` slot in
-- src/import/gba/versions.lua), so interaction_scripts holds primary mids
-- 0..639 and secondary mids 640..663 and nothing above 663. Every warp cell on
-- this map is a walkable metatile, and Collision.behavior() answers nil for
-- them, so Collision.installWarps saw `cur == 0x00` with no warp behavior and
-- silently dropped all six warps -- the softlock.
--
-- The fix: a walkable cell whose behavior is unreadable (the attrs table cannot
-- answer for that mid) still indexes its header warp. Solid cells keep the
-- #2297 guard (see tests/engine/firered_house_wall_warp_bug2297.lua): only an
-- unreadable or live warp behavior may open them.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local Collision = require("src.core.game3.collision")
local Layout = require("src.core.game3.layout_native")
local Interactions = require("src.core.game3.scripting.interaction_scripts")
local ScriptingCollision = require("src.core.game3.scripting.collision")
local Doors = require("src.core.game3.doors")

-- pret map.bin, rows y=0..19 top to bottom, "mid:coll:elev" left to right.
local GRID_ROWS = {
  "649:1:0 731:1:0 732:1:0 747:1:0 760:1:0 649:1:0 649:1:0 652:1:0 648:1:0 696:1:0 697:1:0 649:1:0 760:1:0 649:1:0 649:1:0",
  "657:1:0 739:1:0 740:0:3 748:1:0 761:1:0 686:1:0 687:1:0 660:1:0 656:1:0 704:1:0 705:1:0 657:1:0 761:1:0 686:1:0 687:1:0",
  "642:0:3 642:0:3 642:0:3 642:0:3 753:0:3 694:1:0 695:1:0 660:1:0 656:1:0 642:0:3 642:0:3 642:0:3 753:0:3 694:1:0 695:1:0",
  "642:0:3 641:0:3 641:0:3 641:0:3 685:0:3 702:1:0 703:1:0 660:1:0 656:1:0 642:0:3 641:0:3 641:0:3 685:0:3 702:1:0 703:1:0",
  "672:0:3 673:0:3 673:0:3 673:0:3 673:0:3 770:0:3 672:0:3 668:1:0 656:1:0 642:0:3 641:0:3 641:0:3 641:0:3 647:0:3 645:0:3",
  "649:1:0 649:1:0 649:1:0 651:1:0 649:1:0 696:1:0 697:1:0 652:1:0 656:1:0 713:0:3 641:0:3 641:0:3 641:0:3 641:0:3 712:0:3",
  "714:1:0 657:1:0 714:1:0 659:1:0 714:1:0 704:1:0 705:1:0 660:1:0 656:1:0 721:1:0 641:0:3 641:0:3 641:0:3 641:0:3 720:1:0",
  "721:1:0 642:0:3 721:1:0 642:0:3 721:1:0 642:0:3 642:0:3 660:1:0 656:1:0 642:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3",
  "642:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3 660:1:0 656:1:0 713:0:3 641:0:3 641:0:3 641:0:3 641:0:3 712:0:3",
  "642:0:3 709:0:3 710:0:3 710:0:3 711:0:3 641:0:3 641:0:3 660:1:0 656:1:0 721:1:0 641:0:3 641:0:3 641:0:3 641:0:3 720:1:0",
  "642:0:3 717:1:0 718:1:0 718:1:0 719:1:0 643:0:3 641:0:3 660:1:0 656:1:0 642:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3",
  "642:0:3 725:1:0 726:1:0 726:1:0 727:1:0 643:0:3 641:0:3 762:1:0 756:1:0 713:0:3 641:0:3 641:0:3 641:0:3 641:0:3 712:0:3",
  "642:0:3 733:1:0 734:1:0 734:1:0 735:1:0 643:0:3 641:0:3 763:1:0 764:1:0 721:1:0 641:0:3 641:0:3 641:0:3 641:0:3 720:1:0",
  "642:0:3 692:0:3 645:0:3 645:0:3 692:0:3 646:0:3 641:0:3 642:0:3 642:0:3 642:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3",
  "672:0:3 673:0:3 673:0:3 673:0:3 673:0:3 673:0:3 673:0:3 673:0:3 673:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3 712:0:3",
  "649:1:0 649:1:0 698:1:0 699:1:0 649:1:0 649:1:0 649:1:0 649:1:0 680:1:0 642:0:3 641:0:3 641:0:3 641:0:3 641:0:3 720:1:0",
  "714:1:0 657:1:0 706:1:0 707:1:0 657:1:0 657:1:0 657:1:0 657:1:0 688:1:0 642:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3",
  "721:1:0 642:0:3 700:0:3 701:0:3 642:0:3 642:0:3 642:0:3 642:0:3 642:0:3 642:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3",
  "642:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3 641:0:3 744:0:3 745:0:3 746:0:3 641:0:3",
  "8:1:0 8:1:0 8:1:0 8:1:0 8:1:0 8:1:0 8:1:0 8:1:0 8:1:0 8:1:0 8:1:0 26:1:0 27:1:0 28:1:0 8:1:0",
}
local WIDTH, HEIGHT = 15, 20

-- The `building` (primary) attrs give 0x00 MB_NORMAL for the only primary mids
-- this layout uses (8, 26, 27, 28), so the primary half of the table is all
-- MB_NORMAL. The secondary half is the interesting one.
local PRET_SECONDARY_BEHAVIOR = {
  [659] = 0x96,
  [704] = 0x94, [705] = 0x94,
  [706] = 0x9F, [707] = 0x9F,
  [740] = 0x60, -- MB_CAVE_DOOR        (rear-door exit mat)
  [745] = 0x65, -- MB_SOUTH_ARROW_WARP (front-door exit mats)
  [753] = 0x6C, -- MB_UP_RIGHT_STAIR_WARP (stairs to 2F)
  [761] = 0x9D,
  [763] = 0x84, [764] = 0x84,
}

-- How many secondary mids the engine's exported table actually holds: the
-- secondary entry this pair resolves to carries 24 metatiles, so mids 640..663.
-- Everything above 663 is simply absent -> Collision.behavior() returns nil.
local SECONDARY_MIDS_EXPORTED = 24

-- Editing GRID_ROWS means re-deriving the behaviors above from pret; this pin
-- makes that impossible to forget.
local VERIFIED_MIDS = "8 26 27 28 641 642 643 645 646 647 648 649 651 652 656 "
  .. "657 659 660 668 672 673 680 685 686 687 688 692 694 695 696 697 698 699 "
  .. "700 701 702 703 704 705 706 707 709 710 711 712 713 714 717 718 719 720 "
  .. "721 725 726 727 731 732 733 734 735 739 740 744 745 746 747 748 753 756 "
  .. "760 761 762 763 764 770"

local cells, seenMids = {}, {}
for y = 1, #GRID_ROWS do
  local n = 0
  for token in GRID_ROWS[y]:gmatch("%S+") do
    local mid, coll, elev = token:match("^(%d+):(%d+):(%d+)$")
    assert(mid, "bad grid token " .. token)
    n = n + 1
    cells[(y - 1) * WIDTH + n] = {
      mid = tonumber(mid), coll = tonumber(coll), elev = tonumber(elev),
    }
    seenMids[tonumber(mid)] = true
  end
  T.eq(n, WIDTH, "grid row " .. (y - 1) .. " has the layout width")
end
T.eq(#cells, WIDTH * HEIGHT, "grid has the layout cell count")

local sortedMids = {}
for mid in pairs(seenMids) do sortedMids[#sortedMids + 1] = mid end
table.sort(sortedMids)
T.eq(table.concat(sortedMids, " "), VERIFIED_MIDS,
  "layout mid set matches the pret attrs these behaviors came from")

--- The exported behavior table for this pair.
-- `exported` = what the engine actually has today (secondary attrs stop after
-- 24 metatiles); `pret` = the full 215-metatile secondary attrs, i.e. what the
-- table would hold once the tileset entry is sized correctly.
local function buildBehavior(full)
  local beh = {}
  for mid in pairs(seenMids) do
    if mid < 640 then
      beh[mid] = 0x00 -- MB_NORMAL for every primary mid this layout uses
    elseif full or (mid - 640) < SECONDARY_MIDS_EXPORTED then
      beh[mid] = PRET_SECONDARY_BEHAVIOR[mid] or 0x00
    end
  end
  return beh
end

local EXPORTED_BEHAVIOR = buildBehavior(false)
local PRET_BEHAVIOR = buildBehavior(true)

local PAIR = "celadon_condominiums"
local MAP_ID = "FR_CELADON_CITY_CONDOMINIUMS_1F"

-- pret data/maps/CeladonCity_Condominiums_1F/map.json warp_events in file order.
-- destWarp is pret's dest_warp_id + 1: the extractor stores it 1-based
-- (src/import/gba/extract_map_events.lua:279) because it indexes the
-- *destination* map's own warp list (Collision.resolveDest -> warps[destWarp]).
local WARPS = {
  { x = 11, y = 19, destMap = "FR_CELADON_CITY", destWarp = 4 },
  { x = 12, y = 18, destMap = "FR_CELADON_CITY", destWarp = 4 },
  { x = 13, y = 19, destMap = "FR_CELADON_CITY", destWarp = 4 },
  { x = 4,  y = 2,  destMap = "FR_CELADON_CITY_CONDOMINIUMS_2F", destWarp = 1 },
  { x = 12, y = 2,  destMap = "FR_CELADON_CITY_CONDOMINIUMS_2F", destWarp = 4 },
  { x = 2,  y = 1,  destMap = "FR_CELADON_CITY", destWarp = 12 },
}

local function bind(behavior)
  local translated = {}
  for i, c in ipairs(cells) do
    translated[i] = {
      mid = c.mid,
      coll = ScriptingCollision.fromCell(c.mid, c.coll, behavior[c.mid], "indoor"),
      elev = c.elev,
    }
  end
  local layout = Layout.fromDecoded(
    { width = WIDTH, height = HEIGHT, cells = translated }, MAP_ID, PAIR)
  Interactions.install({ behaviors = { [PAIR] = behavior } })
  Collision.clear()
  Collision.bindMap(nil, MAP_ID, {
    id = MAP_ID,
    kind = "indoor",
    pair = PAIR,
    midLayout = layout,
    warps = WARPS,
  })
  return layout
end

-- CeladonCity has no secondary-tileset entry either, but its exit-side door
-- tiles are primary mids (61 = the front door at (30,11)), which is all this
-- test needs to check the full exit path.
local cityCells = {}
for i = 0, 32 * 32 - 1 do cityCells[i + 1] = { mid = 0, coll = 0x07, elev = 0 } end
cityCells[11 * 32 + 30 + 1] = { mid = 61, coll = 1, elev = 0 }
local cityLayout = Layout.fromDecoded(
  { width = 32, height = 32, cells = cityCells }, "FR_CELADON_CITY",
  "celadon_outdoor")
Doors._layoutCache["CELADON_CITY"] = cityLayout

local GAME = {
  currentMap = MAP_ID,
  data = {
    maps = {
      FR_CELADON_CITY = {
        -- LAYOUT_CELADON_CITY warp_events in ROM order, stored 1-based. The
        -- two this test resolves through: 4 = the front door tile (30,11), the
        -- animated door mid 61; 12 = the rear door tile (30,4), mid 795.
        warps = {
          [1] = { x = 34, y = 21 }, [2] = { x = 11, y = 14 },
          [3] = { x = 15, y = 14 }, [4] = { x = 30, y = 11 },
          [5] = { x = 48, y = 11 }, [6] = { x = 39, y = 20 },
          [7] = { x = 11, y = 30 }, [8] = { x = 37, y = 29 },
          [9] = { x = 41, y = 29 }, [10] = { x = 49, y = 29 },
          [11] = { x = 29, y = 5 }, [12] = { x = 30, y = 4 },
          [13] = { x = 31, y = 5 },
        },
      },
    },
  },
}

-- ---------------------------------------------------------------------------
-- 1. The failure precondition: the exported table cannot answer for the warp
--    cells, which is why the extracted grid leaves them walkable (0x00).
-- ---------------------------------------------------------------------------
bind(EXPORTED_BEHAVIOR)
T.eq(Collision.behavior(12, 18), nil, "the front-door exit mat's behavior is not exported")
T.eq(Collision.behavior(2, 1), nil, "the rear-door exit mat's behavior is not exported")
T.eq(Collision.behavior(4, 2), nil, "the 2F stair's behavior is not exported")
T.eq(Collision.cell(12, 18), 0x00, "the front-door exit mat is walkable")
T.eq(Collision.cell(2, 1), 0x00, "the rear-door exit mat is walkable")
T.eq(Collision.cell(4, 2), 0x00, "the 2F stair is walkable")

-- ---------------------------------------------------------------------------
-- 2. Regression: every header warp on a walkable cell must still be indexed.
-- ---------------------------------------------------------------------------
local front = Collision.warpAt(12, 18)
T.check(front ~= nil, "the front-door exit mat indexes its warp")
T.eq(front and front.destMap, "FR_CELADON_CITY", "the front door exits to the city")
T.eq(front and front.destWarp, 4, "the front door uses CeladonCity warp 4")

local rear = Collision.warpAt(2, 1)
T.check(rear ~= nil, "the rear-door exit mat indexes its warp")
T.eq(rear and rear.destMap, "FR_CELADON_CITY", "the rear door exits to the city")
T.eq(rear and rear.destWarp, 12, "the rear door uses CeladonCity warp 12")

-- (11,19) and (13,19) carry warp events too, but their metatile (mid 641 -- see
-- row y=19) is solid with a *readable* MB_NORMAL behavior. In pret
-- TryStartWarpEventScript rejects a non-warp behavior (field_control_avatar.c:622)
-- and the player can never stand there, so the warp index must stay dropped:
-- reopening it would be the #2297 wall-walk regression, not a fix.
T.eq(Collision.warpAt(11, 19), nil, "the door-side wall (11,19) does not index its warp")
T.eq(Collision.warpAt(13, 19), nil, "the door-side wall (13,19) does not index its warp")
T.eq(Collision.cell(11, 19), 0x07, "the door-side wall stays solid")

local stairs = Collision.warpAt(12, 2)
T.check(stairs ~= nil, "the 2F stair indexes its warp")
T.eq(stairs and stairs.destMap, "FR_CELADON_CITY_CONDOMINIUMS_2F", "the stair goes up to 2F")
T.check(Collision.warpAt(4, 2) ~= nil, "the second 2F stair indexes its warp")

-- The fix must not have turned the mats into door collision -- they stay plain
-- walkable floor, they only gain the warp index.
T.eq(Collision.cell(12, 18), 0x00, "the exit mat stays walkable, not COLL_DOOR")
T.eq(Collision.isWalkable(12, 18), true, "the exit mat is walkable")
T.eq(Collision.warpAt(0, 0), nil, "a cell without a warp event has no warp")

-- ---------------------------------------------------------------------------
-- 3. The two exit paths the player actually uses.
-- ---------------------------------------------------------------------------
-- Front door: pressing down on the mat runs Collision.isExitWarp -> the
-- animated door path, because the outside tile it resolves to is mid 61, a
-- real General-tileset door (Doors.DEFAULT_BY_MID[0x3D]).
local exit = Collision.isExitWarp(GAME, 12, 18)
T.check(exit ~= nil, "pressing down on the front-door mat is an exit warp")
T.eq(exit and exit.destMap, "FR_CELADON_CITY", "the exit lands in CeladonCity")
T.eq(exit and exit.destX, 30, "the front door lands on the city door tile")
T.eq(exit and exit.destY, 11, "the front door lands next to the wall")

-- Rear door: a different route. Its outside tile (30,4) is pret metatile 795 =
-- METATILE_PokemonCenter_Escalator_TopNextRail_Transition2 (0x31C), which has no
-- sDoorGraphics entry and is not a door at all, so isExitWarp is *correctly* nil
-- and pret leaves through the step-based warp instead: input->tookStep ->
-- TryStartStepBasedScript -> TryStartWarpEventScript (field_control_avatar.c:618,
-- :622), the same hook Collision.tryWarpAt serves (src/core/game3/player.lua:658,
-- called from the step callback at :638). That hook fires whenever the cell has
-- an owned warp and its behavior is either unreadable or a live step-warp
-- behavior (src/core/game3/collision.lua:1102).
T.eq(Collision.isExitWarp(GAME, 2, 1), nil, "the rear door is not an animated door exit")

local function stepWarpFires(cx, cy)
  if not Collision.warpAt(cx, cy) then return false end
  local beh = Collision.behavior(cx, cy)
  return beh == nil or Collision.isStepWarpBehavior(beh)
end

T.eq(stepWarpFires(2, 1), true, "stepping onto the rear-door mat triggers the warp out")
T.eq(stepWarpFires(12, 18), true, "stepping onto the front-door mat triggers the warp out")

-- ---------------------------------------------------------------------------
-- 4. With the correctly sized attrs the mats read as warp behaviors instead --
--    the fix and the real data agree on the end state.
-- ---------------------------------------------------------------------------
bind(PRET_BEHAVIOR)
T.eq(Collision.behavior(12, 18), 0x65, "(12,18) is MB_SOUTH_ARROW_WARP in pret")
T.eq(Collision.behavior(2, 1), 0x60, "(2,1) is MB_CAVE_DOOR in pret")
T.eq(Collision.cell(12, 18), 0x72, "a readable warp behavior still seeds a keep-facing warp")
T.eq(Collision.cell(2, 1), 0x72, "the rear mat seeds a keep-facing warp")
T.check(Collision.warpAt(12, 18) ~= nil, "the front-door mat indexes its warp either way")
T.check(Collision.warpAt(2, 1) ~= nil, "the rear-door mat indexes its warp either way")

-- pret agrees with the two exit routes above: MB_CAVE_DOOR (the rear mat) is a
-- step-warp behavior, MB_SOUTH_ARROW_WARP (the front mats) is not -- it is the
-- direction-triggered arrow warp that the down-press path handles.
T.eq(Collision.isStepWarpBehavior(0x60), true, "MB_CAVE_DOOR exits from the step warp path")
T.eq(Collision.isStepWarpBehavior(0x65), false, "MB_SOUTH_ARROW_WARP is not a step warp")

-- ---------------------------------------------------------------------------
-- 5. The #2297 guard is untouched: a *readable* non-warp behavior on a solid
--    wall is still not opened, readable or not.
-- ---------------------------------------------------------------------------
local function bindOneCell(behavior, coll)
  Collision.clear()
  local one = Layout.fromDecoded(
    { width = 1, height = 1, cells = { { mid = 100, coll = coll, elev = 0 } } },
    "TEST", "test")
  Interactions.install({
    behaviors = behavior and { test = { [100] = behavior } } or {},
  })
  Collision.bindMap(nil, "TEST", {
    pair = "test",
    midLayout = one,
    warps = { { x = 0, y = 0, destMap = "FR_CELADON_CITY", destWarp = 1 } },
  })
  return Collision.cell(0, 0), Collision.warpAt(0, 0)
end

local coll, warp = bindOneCell(nil, 0x00)
T.eq(coll, 0x00, "an unreadable behavior leaves the walkable cell alone")
T.check(warp ~= nil, "an unreadable behavior still indexes the warp (#2366)")

coll, warp = bindOneCell(0x00, 0x00)
T.eq(coll, 0x00, "a readable MB_NORMAL cell stays walkable")
T.eq(warp, nil, "a readable MB_NORMAL cell does not index the warp")

coll, warp = bindOneCell(0x00, 0x07)
T.eq(coll, 0x07, "a readable MB_NORMAL wall is not opened by a warp event (#2297)")
T.eq(warp, nil, "a readable MB_NORMAL wall does not index the warp (#2297)")

coll, warp = bindOneCell(nil, 0x07)
T.eq(coll, 0x71, "unreadable attrs still get the walkable-door repair (#2297)")
T.check(warp ~= nil, "unreadable attrs still index the warp (#2297)")

Collision.clear()
T.finish("firered celadon condominiums exit #2366")

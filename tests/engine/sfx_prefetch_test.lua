-- SFX / cry background pre-render (Sound.prefetch*, src/core/sfx_worker.lua).
--   luajit tests/engine/sfx_prefetch_test.lua
-- The worker is driven in-process: the test pops the commands Sound pushed
-- and runs the real Worker.handle + ChipSynth over them, so results are the
-- genuine renders.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq

love = require("tests.love_stub")

local ChipAsm = require("src.audio.ChipAsm")
local ChipSynth = require("src.core.ChipSynth")

-- ---- audio / thread stubs -------------------------------------------------
local sourcesBuilt = 0
local Source = {}
Source.__index = Source
function Source:play() self.playing = true end
function Source:stop() self.playing = false end
function Source:isPlaying() return self.playing end
function Source:setVolume(v) self.volume = v end
function Source:setPitch(v) self.pitch = v end
function Source:getPitch() return self.pitch or 1 end
function Source:getDuration() return 1 end

love.audio = {
  newSource = function(what, mode)
    sourcesBuilt = sourcesBuilt + 1
    return setmetatable({ sd = what, mode = mode }, Source)
  end,
}

local channels = {}
local Channel = {}
Channel.__index = Channel
function Channel:push(msg) self.queue[#self.queue + 1] = msg end
function Channel:pop() return table.remove(self.queue, 1) end
function Channel:clear() self.queue = {} end
function Channel:getCount() return #self.queue end
local function channel(name)
  channels[name] = channels[name] or setmetatable({ queue = {} }, Channel)
  return channels[name]
end

local threadsStarted, threadError = 0, nil
local function installThread()
  love.thread = {
    newThread = function()
      return { start = function() threadsStarted = threadsStarted + 1 end,
               getError = function() return threadError end,
               wait = function() end }
    end,
    getChannel = channel,
  }
end
installThread()

local Worker = require("src.core.sfx_worker")
local wstate = {}
local workerSeen = {} -- key -> last SoundData the worker produced
local renderOrder = {}
local function runWorker()
  local cmdCh, outCh = channel("sfx_cmd"), channel("sfx_out")
  while true do
    local cmd = cmdCh:pop()
    if not cmd then break end
    if cmd.cmd == "render" then renderOrder[#renderOrder + 1] = cmd.key end
    Worker.handle(cmd, wstate, ChipSynth, outCh)
  end
  for _, r in ipairs(outCh.queue) do
    if r.sd then workerSeen[r.key] = r.sd end
  end
end

local ChipAudio = require("src.core.ChipAudio")
local Sound = require("src.core.Sound")

-- ---- data -----------------------------------------------------------------
local function def(octave)
  return ChipAsm.sfx{ channels = { { hw = 1, program = {
    { squareNote = { len = 8, volume = 15, fade = 1,
                     frequency = 0x400 + octave * 0x40 } },
  } } } }
end

local function newData()
  return {
    audio = {
      sfx = { Foo = def(5), Bar = def(4), Baz = def(6), Qux = def(3),
              Filey = "assets/nope.wav" },
      cries = { MON = def(5), DERIVED = { base = "MON", pitch = 3, length = 9 },
                PIKACHU = def(6) },
    },
    moves = { TACKLE = { anim = { sound = "Bar", pitch = 0x20, tempo = 0x90 } } },
  }
end

local function reset()
  Sound.shutdown()
  Sound.invalidate()
  Sound._setNoThreadEnvForTest(nil)
  Sound._setPrefetchLimitsForTest()
  threadError = nil
  channel("sfx_cmd"):clear()
  channel("sfx_out"):clear()
  wstate = {}
  workerSeen, renderOrder = {}, {}
  installThread()
end

local renders = 0
local realRender = ChipSynth.renderEffectData
ChipSynth.renderEffectData = function(...)
  renders = renders + 1
  return realRender(...)
end
local function rendersDuring(fn)
  local before = renders
  fn()
  return renders - before
end

local function sameSamples(a, b)
  if not (a and b) then return false end
  if a:getSampleCount() ~= b:getSampleCount() then return false end
  for i = 0, a:getSampleCount() - 1 do
    if a:getSample(i, 1) ~= b:getSample(i, 1)
        or a:getSample(i, 2) ~= b:getSample(i, 2) then
      return false
    end
  end
  return true
end

-- ---- key parity: a prefetched entry is the one the play call uses ----------
do
  reset()
  local data = newData()
  check(Sound.prefetchSfx(data, "Foo"), "sfx prefetch accepted")
  check(Sound.prefetchCry(data, "MON"), "cry prefetch accepted")
  check(Sound.prefetchCry(data, "DERIVED"), "derived cry prefetch accepted")
  check(Sound.prefetchMove(data, data.moves.TACKLE.anim), "move prefetch accepted")
  check(Sound.prefetchMove(data, { sound = "Baz" }), "default-modifier move accepted")
  check(not Sound.prefetchIdle(), "not idle while requests are pending")
  for _ = 1, 8 do runWorker(); Sound.update() end
  check(Sound.prefetchIdle(), "idle once every result is drained")
  local built = sourcesBuilt

  eq(rendersDuring(function()
    check(Sound.play(data, "Foo") ~= nil, "Foo plays")
    check(Sound.playCry(data, "MON") ~= nil, "cry plays")
    check(Sound.playCry(data, "DERIVED") ~= nil, "derived cry plays")
    Sound.playMove(data, data.moves.TACKLE.anim)
    Sound.playMove(data, { sound = "Baz" })
  end), 0, "first plays after prefetch render nothing (keys match exactly)")
  eq(sourcesBuilt, built, "and build no further Source")
  check(Sound.isPlaying("Foo"), "the prefetched Source is the one that played")

  -- bit-identical to the synchronous render of the same key
  local syncData = newData()
  local syncSfx = ChipAudio.newSfx(syncData, "Foo", nil, nil, syncData.audio.sfx.Foo)
  check(sameSamples(syncSfx.sd, workerSeen["Foo"]), "sfx worker render is bit-identical")
  local resolved = { chip = syncData.audio.cries.MON.chip, pitch = 3, length = 9 }
  local syncCry = ChipAudio.newCry(syncData, "DERIVED", resolved)
  check(sameSamples(syncCry.sd, workerSeen["cry:DERIVED"]), "cry worker render is bit-identical")
  local syncMove = ChipAudio.newSfx(syncData, "Bar", 0x20, 0x90, syncData.audio.sfx.Bar, 0)
  check(sameSamples(syncMove.sd, workerSeen["Bar@2090"]), "move worker render is bit-identical")
end

-- ---- the sync fallback is untouched when the worker is late ---------------
do
  reset()
  local data = newData()
  Sound.prefetchSfx(data, "Foo")
  local src
  eq(rendersDuring(function() src = Sound.play(data, "Foo") end), 1,
    "play before the worker delivers renders synchronously")
  check(src ~= nil, "and still returns a real Source")

  -- the late result must not replace or double-fill
  local built = sourcesBuilt
  runWorker()
  Sound.update()
  eq(sourcesBuilt, built, "late result built no Source")
  check(Sound.play(data, "Foo") == src, "cached Source object is unchanged")
  check(Sound.prefetchIdle(), "the dropped result still retires the request")
end

-- ---- stale epoch ----------------------------------------------------------
do
  reset()
  local data = newData()
  Sound.prefetchSfx(data, "Foo")
  runWorker()                       -- result is sitting in the out channel
  Sound.invalidate()                -- cache flush bumps the epoch
  local built = sourcesBuilt
  Sound.update()
  eq(sourcesBuilt, built, "result from before invalidate is dropped")
  local src
  eq(rendersDuring(function() src = Sound.play(data, "Foo") end), 1,
    "so the play renders synchronously")
  check(src.sd ~= workerSeen["Foo"], "and does not use the stale render")

  -- a mix change re-renders under the new settings instead of filing old audio
  reset()
  data = newData()
  Sound.prefetchSfx(data, "Foo")
  local epoch = Sound.renderEpoch()
  runWorker()
  ChipAudio.setChannelVolume(1, 0.5)
  check(Sound.renderEpoch() > epoch, "channel volume change bumps the epoch")
  local stale = workerSeen["Foo"]
  local built2 = sourcesBuilt
  Sound.update()
  eq(sourcesBuilt, built2, "stale mix result not filed")
  check(not Sound.prefetchIdle(), "the request was re-queued")
  runWorker(); Sound.update()
  check(Sound.prefetchIdle(), "re-rendered result delivered")
  check(Sound.play(data, "Foo").sd ~= stale, "cache holds the post-change render")
  ChipAudio.setChannelVolume(1, 1)
  local e2 = Sound.renderEpoch()
  ChipAudio.setStereo(true); ChipAudio.setStereo(false)
  check(Sound.renderEpoch() > e2, "stereo change bumps the epoch")
  local e3 = Sound.renderEpoch()
  ChipAudio.setChannelPitch(2, 1.5); ChipAudio.setChannelPitch(2, 1)
  check(Sound.renderEpoch() > e3, "channel pitch change bumps the epoch")
  local e4 = Sound.renderEpoch()
  local rate = ChipSynth.SAMPLE_RATE
  ChipAudio.setSampleRate(rate == 22050 and 44100 or 22050)
  check(Sound.renderEpoch() > e4, "sample rate change bumps the epoch")
  ChipAudio.setSampleRate(rate)
end

-- ---- a setter that changes nothing leaves in-flight renders alone ----------
do
  reset()
  local data = newData()
  ChipAudio.setChannelVolumes({ 1, 1, 1, 1 })
  Sound.prefetchSfx(data, "Foo")
  local e = Sound.renderEpoch()
  ChipAudio.setChannelVolumes({ 1, 1, 1, 1 })
  ChipAudio.setChannelVolume(2, 1)
  ChipAudio.setChannelPitches({ 1, 1, 1, 1 })
  ChipAudio.setChannelPitch(3, 1)
  ChipAudio.setNoiseVolume(1)
  eq(Sound.renderEpoch(), e, "re-applying the same mix keeps the epoch")
  runWorker(); Sound.update()
  check(Sound.prefetchIdle() and Sound.play(data, "Foo") ~= nil,
    "so the in-flight render was delivered")
  eq(rendersDuring(function() Sound.play(data, "Foo") end), 0, "and not re-rendered")

  ChipAudio.setChannelVolumes({ 1, 0.5, 1, 1 })
  check(Sound.renderEpoch() > e, "a real volume change bumps the epoch")
  e = Sound.renderEpoch()
  ChipAudio.setChannelVolumes({ 1, 0.5, 1, 1 })
  eq(Sound.renderEpoch(), e, "repeating it does not")
  ChipAudio.setNoiseVolume(0.25)
  check(Sound.renderEpoch() > e, "a noise volume change bumps the epoch")
  e = Sound.renderEpoch()
  ChipAudio.setChannelPitches({ 1, 1.5, 1, 1 })
  check(Sound.renderEpoch() > e, "a real pitch change bumps the epoch")
  ChipAudio.setChannelVolumes({ 1, 1, 1, 1 })
  ChipAudio.setChannelPitches({ 1, 1, 1, 1 })
end

-- ---- never replaces an existing cached Source ------------------------------
do
  reset()
  local data = newData()
  local first = Sound.play(data, "Bar") -- sync fill, nothing prefetched yet
  check(not Sound.prefetchSfx(data, "Bar"), "cached key is not prefetched")
  eq((Sound.prefetchPending()), 0, "nothing queued for a cached key")
  check(Sound.play(data, "Bar") == first, "same object on replay")
end

-- ---- fallbacks ------------------------------------------------------------
do
  reset()
  love.thread = nil
  local data = newData()
  check(not Sound.prefetchSfx(data, "Foo"), "no love.thread: prefetch is a no-op")
  check(Sound.prefetchIdle(), "no love.thread: always idle")
  check(Sound.play(data, "Foo") ~= nil, "no love.thread: sync play still returns a Source")
  Sound.update() -- must not throw

  reset()
  Sound._setNoThreadEnvForTest("1")
  local before = threadsStarted
  check(not Sound.prefetchCry(data, "MON"), "POKEPORT_NO_THREAD=1: no-op")
  eq(threadsStarted, before, "POKEPORT_NO_THREAD=1 never starts the worker")
  check(Sound.playCry(data, "MON") ~= nil, "POKEPORT_NO_THREAD=1: sync cry returns a Source")

  reset()
  love.thread.newThread = function() error("boom") end
  check(not Sound.prefetchSfx(data, "Bar"), "worker start failure: no-op")
  check(Sound.play(data, "Bar") ~= nil, "worker start failure: sync play works")
end

-- ---- worker dies -> back to synchronous -----------------------------------
do
  reset()
  local data = newData()
  Sound.prefetchSfx(data, "Foo")
  threadError = "worker crashed"
  Sound.update()
  check(Sound.prefetchIdle(), "dead worker drops its queue")
  check(not Sound.prefetchSfx(data, "Bar"), "and later prefetches are no-ops")
  check(Sound.play(data, "Foo") ~= nil, "play still works")
  threadError = nil
end

-- ---- skips ----------------------------------------------------------------
do
  reset()
  local data = newData()
  check(not Sound.prefetchSfx(data, "Filey"), "file defs are not prefetched")
  check(not Sound.prefetchSfx(data, "Missing"), "unknown names are not prefetched")
  data.audio.pikaCries = 10
  check(not Sound.prefetchCry(data, "PIKACHU"), "Yellow PCM Pikachu is not prefetched")
  data.audio.pikaCries = nil
  check(Sound.prefetchCry(data, "PIKACHU"), "chip Pikachu is prefetched")
end

-- ---- per-frame drain cap --------------------------------------------------
do
  reset()
  Sound._setPrefetchLimitsForTest(8, 4)
  local data = newData()
  for _, n in ipairs({ "Foo", "Bar", "Baz", "Qux" }) do Sound.prefetchSfx(data, n) end
  Sound.prefetchCry(data, "MON"); Sound.prefetchCry(data, "DERIVED")
  Sound.prefetchCry(data, "PIKACHU")
  Sound.prefetchMove(data, { sound = "Foo", pitch = 4 })
  runWorker()
  eq(channel("sfx_out"):getCount(), 8, "eight results waiting")
  local before = sourcesBuilt
  Sound.update()
  eq(sourcesBuilt - before, 4, "first frame builds at most 4 Sources")
  Sound.update()
  eq(sourcesBuilt - before, 8, "second frame builds the rest")
  check(Sound.prefetchIdle(), "idle after both frames")
end

-- ---- queue order: front overtakes, dedupe ---------------------------------
do
  reset()
  Sound._setPrefetchLimitsForTest(1, 4)
  local data = newData()
  Sound.prefetchSfx(data, "Foo")           -- goes straight to the worker
  Sound.prefetchSfx(data, "Bar")
  Sound.prefetchSfx(data, "Baz")
  Sound.prefetchSfx(data, "Foo")           -- duplicate in flight
  Sound.prefetchSfx(data, "Baz", { front = true }) -- promoted
  local queued, flying = Sound.prefetchPending()
  eq(queued, 2, "duplicates are not queued twice")
  eq(flying, 1, "one request at the worker")
  for _ = 1, 6 do runWorker(); Sound.update() end
  eq(table.concat(renderOrder, ","), "Foo,Baz,Bar", "front request overtakes queued hints")
end

-- ---- worker config: an independent synth renders identically --------------
do
  reset()
  local data = newData()
  local oldRate = ChipSynth.SAMPLE_RATE
  ChipAudio.setSampleRate(22050)
  ChipAudio.setChannelVolumes({ 1, 0.5, 0.8, 0.6 })
  ChipAudio.setChannelPitches({ 1, 1.5, 1, 1 })
  ChipAudio.setStereo(true)

  local function viaWorker(synth, configure, header, options)
    local st, out = {}, channel("sfx_out_iso")
    out:clear()
    if configure then
      local cfg = ChipAudio.effectWorkerConfig(data)
      cfg.cmd, cfg.epoch = "config", 1
      Worker.handle(cfg, st, synth, out)
    else
      st.data, st.epoch = { audio = data.audio }, 1
    end
    Worker.handle({ cmd = "render", epoch = 1, key = "k", header = header,
                    options = options }, st, synth, out)
    return out.queue[1] and out.queue[1].sd
  end
  local function sfxArgs()
    return ChipAudio.sfxRenderArgs(data, "Foo", 0x20, 0x90, data.audio.sfx.Foo, 0)
  end
  local sync = ChipAudio.newSfx(data, "Foo", 0x20, 0x90, data.audio.sfx.Foo, 0).sd
  local h, o = sfxArgs()
  local configured = viaWorker(dofile("src/core/ChipSynth.lua"), true, h, o)
  check(sameSamples(sync, configured),
    "fresh synth + config renders bit-identical at 22050 with custom mix/pan")
  h, o = sfxArgs()
  local control = viaWorker(dofile("src/core/ChipSynth.lua"), false, h, o)
  check(not sameSamples(sync, control),
    "control: an unconfigured synth renders differently")

  local resolved = { chip = data.audio.cries.MON.chip, pitch = 3, length = 9 }
  local syncCry = ChipAudio.newCry(data, "DERIVED", resolved).sd
  local ch, co = ChipAudio.cryRenderArgs(data, "DERIVED", resolved)
  local cryW = viaWorker(dofile("src/core/ChipSynth.lua"), true, ch, co)
  check(sameSamples(syncCry, cryW), "cry: configured synth is bit-identical")

  ChipAudio.setStereo(false)
  ChipAudio.setChannelVolumes({ 1, 1, 1, 1 })
  ChipAudio.setChannelPitches({ 1, 1, 1, 1 })
  ChipAudio.setSampleRate(oldRate)
end

-- ---- worker fatal error -> sync fallback ----------------------------------
do
  reset()
  local data = newData()
  Sound.prefetchSfx(data, "Foo")
  channel("sfx_out"):push({ fatal = "boom in loop" })
  Sound.update()
  check(Sound.prefetchIdle(), "fatal message drops the queue")
  check(not Sound.prefetchSfx(data, "Bar"), "and turns prefetch off")
  local quit = false
  for _, c in ipairs(channel("sfx_cmd").queue) do if c.cmd == "quit" then quit = true end end
  check(quit, "failWorker asks the thread to quit")
  check(Sound.play(data, "Foo") ~= nil, "play still renders synchronously")
end

-- ---- cmd channel hygiene ---------------------------------------------------
do
  reset()
  Sound._setPrefetchLimitsForTest(4, 4)
  local data = newData()
  Sound.prefetchSfx(data, "Foo"); Sound.prefetchSfx(data, "Bar")
  check(channel("sfx_cmd"):getCount() >= 3, "config + renders are queued")
  ChipAudio.setChannelVolume(1, 0.7)
  eq(channel("sfx_cmd"):getCount(), 0, "an epoch bump clears the worker inbox")
  Sound.update() -- re-send
  eq(channel("sfx_cmd").queue[1].cmd, "config", "config is re-sent before any render")
  ChipAudio.setChannelVolume(1, 1)
  Sound.update()
  Sound.prefetchSfx(data, "Baz")
  Sound.shutdown()
  eq(channel("sfx_cmd"):getCount(), 1, "shutdown clears pending work")
  eq(channel("sfx_cmd").queue[1].cmd, "quit", "and leaves only quit")
end

-- ---- battle prefetch jumps ahead of older high-priority hints --------------
do
  reset()
  Sound._setPrefetchLimitsForTest(1, 4)
  local data = newData()
  Sound.prefetchSfx(data, "Foo")                    -- at the worker
  Sound.prefetchSfx(data, "Qux", { front = true })  -- old battle's leftover
  Sound.prefetchBattle(data, { { species = "DERIVED", moves = { { id = "TACKLE" } } } },
    { { species = "MON" } }, { species = "MON" },
    { species = "DERIVED", moves = { { id = "TACKLE" } } })
  for _ = 1, 12 do runWorker(); Sound.update() end
  local order = {}
  for i, k in ipairs(renderOrder) do order[k] = i end
  check(order["cry:MON"] and order["cry:DERIVED"] and order["Qux"],
    "all requested keys rendered")
  check(order["cry:MON"] < order["Qux"] and order["cry:DERIVED"] < order["Qux"],
    "leads' cries overtake the old leftovers")
  eq(renderOrder[2], "cry:MON", "enemy lead cry goes first")
  eq(renderOrder[3], "cry:DERIVED", "then the player lead cry")
end

Sound.shutdown()
T.finish()

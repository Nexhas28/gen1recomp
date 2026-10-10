-- SFX / cry pre-render worker (love.thread).  Runs ChipSynth.renderEffectData
-- off the main thread so the FIRST play of a sound effect or Pokémon cry does
-- not synthesize on the render thread (a cry or jingle is 20-100ms of Lua on a
-- desktop and ~10x that on a low-power handheld).  A separate thread from
-- chip_worker on purpose: a long effect render must never delay music buffers.
--
-- Protocol -- main thread (src/core/Sound.lua) pushes onto "sfx_cmd" and
-- drains "sfx_out":
--   cmd = "config" { epoch, audio, sampleRate, volumes, pitches, stereo }
--                    sets the synth up to render like the main thread does;
--                    sent before the first request and whenever the epoch
--                    (cache invalidation / rate / mix / pan) changes
--   cmd = "render" { epoch, key, header, options }
--                    one effect; options are exactly what ChipAudio's
--                    sfxRenderArgs/cryRenderArgs build for the sync path
--   cmd = "quit"     end the thread
-- out:
--   { key, epoch, sd = SoundData }   rendered
--   { fatal = msg }                  the worker loop errored and exited
--   { key, epoch, failed = msg }     render error or too-short effect (the
--                                    main thread leaves the slot empty so the
--                                    sync path reproduces and logs it)
--
-- Worker.handle holds all the command handling so tests can drive a round trip
-- in-process by requiring this file.

local Worker = {}

-- handle(cmd, state, synth, out) -> true when the thread should end.
-- state: { epoch, data }.  out: object with :push(msg).
function Worker.handle(cmd, state, synth, out)
  if cmd.cmd == "config" then
    state.data = { audio = cmd.audio }
    if cmd.sampleRate ~= nil then synth.setSampleRate(cmd.sampleRate) end
    if cmd.volumes ~= nil then synth.setChannelVolumes(cmd.volumes) end
    if cmd.pitches ~= nil then synth.setChannelPitches(cmd.pitches) end
    if cmd.stereo ~= nil then synth.setStereo(cmd.stereo) end
    -- a mod / hot reload may have swapped programs.bin under the bank cache
    synth.invalidateBanks()
    state.epoch = cmd.epoch
  elseif cmd.cmd == "render" then
    -- a request from before the last config is obsolete: render nothing
    if cmd.epoch ~= state.epoch or not state.data then return false end
    local ok, sd = pcall(synth.renderEffectData, state.data, cmd.header,
                         cmd.options)
    if ok and sd then
      out:push({ key = cmd.key, epoch = cmd.epoch, sd = sd })
    else
      out:push({ key = cmd.key, epoch = cmd.epoch,
                 failed = ok and "no sound" or tostring(sd) })
    end
  elseif cmd.cmd == "quit" then
    return true
  end
  return false
end

-- required as a module (tests): hand back the handler instead of running the
-- loop.  A love.thread entry is started with no arguments, so `...` is empty.
if select("#", ...) > 0 then return Worker end

-- Any error must end the loop by RETURNING (a raised thread error would hit
-- love.threaderror on the main thread, which this game does not handle):
-- report it through the out channel and let Sound fall back to sync.
local function run()
  require("love.thread")
  require("love.timer")
  require("love.sound")
  require("love.filesystem")

  -- a fresh thread Lua state does not necessarily carry the package searcher
  local ChipSynth = assert(love.filesystem.load("src/core/ChipSynth.lua"))()

  local cmdCh = love.thread.getChannel("sfx_cmd")
  local state = { epoch = nil, data = nil }
  local outCh = love.thread.getChannel("sfx_out")
  while true do
    local cmd = cmdCh:demand()
    if Worker.handle(cmd, state, ChipSynth, outCh) then break end
  end
end

local ok, err = pcall(run)
if not ok then
  pcall(function()
    love.thread.getChannel("sfx_out"):push({ fatal = tostring(err) })
  end)
end

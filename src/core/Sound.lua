-- Sound effects and cries synthesized from compact ROM channel programs,
-- from def-local chip programs (ChipAsm), or loaded from file definitions --
-- the branch is chosen per definition, not by a global import flag. Sources
-- are cached; a definition that fails to load caches as `false` so it is
-- logged once and skipped, never disabling the rest of the audio. Headless
-- use is a safe no-op.

local Assets = require("src.render.Assets")
local Logger = require("src.core.Logger")
local WorkerLane = require("src.core.WorkerLane")
local Runtime = require("src.mods.Runtime")
local bit = require("bit")

local Sound = {}

local cache = {}
-- port addition: 0-7 SFX volume from save.options.sfxVol (OptionsMenu),
-- scaling the 0.8 base every source gets
local BASE_VOLUME = 0.8
local volumeScale = 1
-- port addition (Yellow only): 0-7 trim from save.options.pikaVol on top of
-- the SFX level, for Pikachu's voice clips alone.  Yellow voices every
-- Pikachu cry with PCM samples that are far louder and far more frequent
-- than the chip cries around them (the follower alone talks on every
-- interaction), so this is the one source players want to pull down
-- without muting the rest of the SFX bus.  7 = untouched, 0 = silent.
local pikaScale = 1

-- cache keys whose volume the Pikachu trim applies to: the PCM clips, plus
-- the chip PIKACHU cry that a Yellow cache without extracted clips falls
-- back to (playCry).  Red/Blue never reach the second branch, so a shared
-- options.lua carrying a low pikaVol cannot quiet their Pikachu.
local function isPikaKey(key)
  if type(key) ~= "string" then return false end
  if key:sub(1, 8) == "pikacry:" then return true end
  return key == "cry:PIKACHU"
    and require("src.core.GameVersion").isYellow()
end

local function volumeFor(key)
  local scale = volumeScale
  if isPikaKey(key) then scale = scale * pikaScale end
  return BASE_VOLUME * scale
end

-- Fanfares occupy the music's tone channels on the Game Boy: their sfx
-- headers claim channels 5-7 (= hardware channels 1-3), silencing the
-- song until they finish (audio/headers/sfxheaders*.asm; the game also
-- blocks on them via PlaySoundWaitForCurrent/WaitForSoundToFinish).
-- The Poké Flute even issues SFX_STOP_ALL_MUSIC first
-- (engine/items/item_effects.asm).  Music.lua pauses the current song
-- while one of these plays and resumes it afterwards.  Ordinary short
-- SFX (menu beeps, hits, cries) stay overlaid.
-- data.audio.fanfares supersedes this; the copy stays as the fallback for
-- caches built before the importer wrote the table, and a def may claim the
-- behavior for itself with fanfare = true.
local FANFARES = {
  Level_Up = true,
  Caught_Mon = true,
  Get_Item1 = true,
  Get_Item2 = true,
  Get_Key_Item = true,
  Pokedex_Rating = true,
  Dex_Page_Added = true,
  Pokeflute = true,
}

-- which mod put this key in the registry, for attributed failure logs
local function owner(data, kind, key)
  local owners = data and data.audio and data.audio._owners
  local map = owners and owners[kind]
  return map and map[key] or "base"
end

-- one log line, plus an entry in the loader's error feed when a mod owns the
-- def, so the manager's errors screen can flag that mod
local function reportBadDef(kind, key, who, err)
  Logger.warn("audio: bad %s def %q (mod %s): %s", kind, key, who, tostring(err))
  Runtime.reportError(who,
    ("audio: bad %s def %q: %s"):format(kind, key, tostring(err)))
end

local function isChipDef(def)
  return type(def) == "table" and (def.chip ~= nil or def.address ~= nil)
end

-- OpenAL only spatializes 1-channel Sources, and one left at the default
-- (0,0,0) position sits on top of the listener, which OpenAL renders as an
-- ambient sound spread over every output channel the device has: on an
-- interface with more than two outputs the SFX also came out of outputs 5+6
-- while the 2-channel music stayed on 1+2 (#626).  A Source cannot change its
-- channel count after the fact, so a mono file def is re-decoded and its
-- sample duplicated into a stereo buffer, which OpenAL never spatializes.
-- Chip SFX and cries are already stereo at the source (ChipSynth
-- renderEffectData); this covers file defs, i.e. Yellow's 8-bit mono PCM
-- Pikachu clips (RomExtractor extractPikachuCries) and mod-supplied wav/ogg
-- SFX.
--
-- Decode the FILE (not Source:getChannelCount): love-nx/audren has reported
-- channel counts that skip this widen silently, and preserving 8-bit depth
-- into a stereo buffer also sounds wrong on that backend.  Always emit
-- 16-bit stereo like ChipSynth.  Failure keeps the original Source and logs.
local function widenMono(source, file)
  if type(file) ~= "string" then return source end
  if not (love.sound and love.sound.newSoundData and love.audio
      and love.audio.newSource) then
    return source
  end
  -- Quiet skip when the path is unreadable (headless stub SFX keys, missing
  -- files).  On NX, overlay-wrapped getInfo makes the yellow|blue copy visible
  -- at the bare assets/generated path so the widen still runs.
  local fs = love.filesystem
  if not (fs and fs.getInfo and fs.getInfo(file)) then
    return source
  end
  local built, widened = pcall(function()
    local mono = love.sound.newSoundData(file)
    if mono:getChannelCount() ~= 1 then return source end
    local frames = mono:getSampleCount()
    local stereo = love.sound.newSoundData(frames, mono:getSampleRate(), 16, 2)
    for index = 0, frames - 1 do
      local value = mono:getSample(index)
      stereo:setSample(index, 1, value)
      stereo:setSample(index, 2, value)
    end
    return love.audio.newSource(stereo, "static")
  end)
  if built and widened and widened ~= source then return widened end
  if not built then
    Logger.warn("sound: widenMono failed for %s: %s", file, tostring(widened))
  end
  return source
end

-- a file def carries an optional playback rate; a bare string is shorthand
-- for { file = <string> }
local function newFileSource(def)
  local file = type(def) == "table" and def.file or def
  if type(file) ~= "string" then return nil, "no chip program and no file" end
  local ok, s = pcall(love.audio.newSource, file, "static")
  if not ok or not s then return nil, ok and "no source" or tostring(s) end
  s = widenMono(s, file) -- keep mono defs off the surround channels (#626)
  if type(def) == "table" and def.pitch then pcall(s.setPitch, s, def.pitch) end
  return s
end

local function newSfxSource(data, key, def, pitch, tempo, plain)
  if isChipDef(def) then
    local ok, s = pcall(require("src.core.ChipAudio").newSfx,
      data, key:match("^([^@]+)") or key, pitch, tempo, def, plain)
    if not ok then return nil, tostring(s) end
    if not s then return nil, "no source" end
    return s
  end
  return newFileSource(def)
end

local function deviceSuspended()
  local ChipAudio = package.loaded["src.core.ChipAudio"]
  return ChipAudio ~= nil and ChipAudio.isSuspended()
end

-- Optional one-shot playback rate (Source:setPitch multiplier), capped the
-- way the cart's audio engine clamps under frame-skip (home/vblank.asm:58-72).
-- GAME SPEED does NOT drive this: the port keeps SFX at natural pitch at
-- every multiplier (#1990/#1991/#1997).  Callers may still set it for tests
-- or a future opt-in; SessionLifecycle resets it on teardown.
local FF_PITCH_MAX = 4
local rate = 1

function Sound.setRate(n)
  n = tonumber(n)
  if n and n == n and n > 0 then
    rate = math.min(n, FF_PITCH_MAX)
  else
    rate = 1
  end
end

function Sound.rate() return rate end

local function applyRate(src, base)
  if not src then return src end
  pcall(src.setPitch, src, (base or 1) * rate)
  return src
end

-- WaitForSoundToFinish budget in 60 Hz frames (home/delay.asm:14).
function Sound.waitFrames(src, fallback)
  if not src then return 0 end
  local okd, dur = pcall(src.getDuration, src)
  if not okd or type(dur) ~= "number" or dur ~= dur or dur <= 0 then
    return fallback or 180
  end
  local okp, pitch = pcall(src.getPitch, src)
  if okp and type(pitch) == "number" and pitch > 0 then dur = dur / pitch end
  return math.ceil(dur * 60 * rate) + 2
end

local function playPath(data, key, def, pitch, tempo, plain)
  if not love.audio or not def then return nil end
  if deviceSuspended() then return nil end
  local src = cache[key]
  if src == false then return nil end -- known bad, already logged
  if not src then
    local s, err = newSfxSource(data, key, def, pitch, tempo, plain)
    if not s then
      cache[key] = false
      reportBadDef("sfx", key, owner(data, "sfx", key), err)
      return nil
    end
    pcall(s.setVolume, s, volumeFor(key))
    cache[key] = s
    src = s
  end
  pcall(src.stop, src)
  applyRate(src, type(def) == "table" and def.pitch or 1)
  pcall(src.play, src)
  return src
end

-- A Gen 2 sfx header declares how many of the four sfx channels it wants
-- (`channel_count N` in audio/sfx.asm), and sfx channel N takes hardware
-- channel N over from the music channel with the same number for as long as
-- it sounds.  So a FOUR-channel sfx silences the song outright -- that is what
-- the cart does with every jingle: Sfx_RegisterPhoneNumber, Sfx_GetTm,
-- Sfx_GetBadge, Sfx_GetEgg, Sfx_Item, Sfx_CaughtMon, the eight dex fanfares.
-- The port's fanfare table was six hardcoded names, so the phone-number jingle
-- (and a dozen others) played OVER the music instead of replacing it.
--
-- Three-channel sfx are NOT ducked even though they too silence three quarters
-- of the song: most of them are battle move sounds (Psychic, Hyper Beam, Surf)
-- that fire several times a second, and pausing/resuming the song under each
-- one would stutter far worse than letting them overlay.  The handful of
-- three-channel JINGLES are named below instead.
local GEN2_JINGLES = {
  Sfx_Fanfare = true, Sfx_Fanfare2 = true,
  Sfx_3rdPlace = true, Sfx_TrainArrived = true,
}
local FULL_BAND = 4
local channelCounts = {} -- per sfx name; the header read is not free

local function claimsEveryChannel(data, name, def)
  if type(def) ~= "table" or not def.address then return false end
  -- Gen 2 only.  Gen 1's fanfare set is already listed by name and its sfx
  -- headers count channels differently; widening the rule there would change
  -- Red/Blue behaviour for no reported reason.
  if def.generation ~= 2 then return false end
  local known = channelCounts[name]
  if known == nil then
    local ok, channels = pcall(
      require("src.core.ChipSynth").effectChannels, data, def)
    -- effectChannels answers nil for "not knowable HERE" -- a file def, or the
    -- program banks not readable yet (src/core/ChipSynth.lua effectChannels).
    -- That is a "not yet", not a channel count: memoizing it as zero would
    -- stamp a four-channel jingle as non-ducking for the rest of the session,
    -- so it plays over the map music until the next launch.  Only a header
    -- that actually read is cached; a failed read is retried on the next play.
    if not (ok and channels) then return false end
    known = #channels
    channelCounts[name] = known
  end
  return known >= FULL_BAND
end

local function ducks(data, name, def)
  if type(def) == "table" and def.fanfare then return true end
  local fanfares = data.audio and data.audio.fanfares or FANFARES
  if fanfares[name] then return true end
  if GEN2_JINGLES[name] then return true end
  return claimsEveryChannel(data, name, def)
end

-- Does playing this sfx stop the song?  Exposed so a test can assert the rule
-- without an audio device.
function Sound.ducksMusic(data, name)
  local sfx = data and data.audio and data.audio.sfx
  name = Sound.resolve(data, name)
  return ducks(data or {}, name, sfx and sfx[name])
end

local function played(kind, name, species)
  if not Runtime.wants("sound.played") then return end
  Runtime.emit("sound.played", { kind = kind, name = name, species = species })
end

-- The shared UI names its sounds the way pokered does; Gen 2's sfx table is
-- keyed by pokegold's own labels, so a Gold session asking for "Press_AB"
-- finds nothing and the menu goes silent -- which is exactly what happened to
-- the A-press beep on every Gold dialogue.  Only the shared modules a Gold
-- session actually enters need a row here, and today that is src/render/
-- TextBox.lua and src/ui/ChoiceBox.lua, both playing "Press_AB": the cart
-- sounds SFX_READ_TEXT_2 at both of those moments (home/joypad.asm
-- PromptButton for the textbox wait, home/menu.asm PlayClickSFX for a menu
-- pick).  Every other shared player of a pokered sfx name sits in a module
-- Gold replaces under src/world/gen2 or src/ui/gen2, and those name their
-- sounds in pokegold's labels directly.  So a row belongs here only once a
-- shared module is reachable from Gold, and its target is whatever the cart
-- plays at that same moment -- not the nearest-sounding Gen 2 label.
Sound.GEN2_ALIASES = {
  Press_AB = "Sfx_ReadText2",
}

-- The hop Sound.resolve took for a raw name, so the argument-only entry points
-- (stop, isPlaying) can reach a source Sound.play cached under the resolved
-- key without a data table of their own.
local aliased = {}

function Sound.resolve(data, name)
  local sfx = data and data.audio and data.audio.sfx
  if not sfx then return name end
  if sfx[name] then return name end
  local alias = Sound.GEN2_ALIASES[name]
  if alias and sfx[alias] then
    aliased[name] = alias
    return alias
  end
  return name
end

-- the source a raw name plays through, whichever key it ended up cached under
local function cached(name)
  local src = cache[name]
  if src == nil then
    local key = aliased[name]
    if key then src = cache[key] end
  end
  return src
end

-- Gen 2's overworld/menu entry point is a PRIORITY GATE, not a bare play
-- (home/audio.asm PlaySFX).  It asks CheckSFX whether any of the four sfx
-- channels is still sounding, and when one is it compares the id that owns
-- them: `ld a, [wCurSFX] / cp e / jr c, .done` DROPS the new sound outright
-- while the playing id is numerically lower (constants/sfx_constants.asm
-- orders the table highest priority first).  Only an id at or below wCurSFX
-- falls through, and _PlaySFX turns off and re-zeroes ch5-ch8 before it loads
-- the new header (audio/engine.asm _PlaySFX), cutting the old sound dead.
-- Either way sfx NEVER layer here.  SproutTower3FRivalScene is the plain
-- case: `playsound SFX_TACKLE` ($41) then `playsound SFX_ELEVATOR` ($6e) one
-- command later, with the two-note tackle still sounding, so the cart never
-- plays the elevator rumble at all -- the pillar sways to the thud alone.
--
-- Battle ANIMATION sounds are a different entry point and must not come
-- through here: anim_sound reaches PlayStereoSFX (engine/battle_anims/
-- anim_commands.asm), which has no gate at all and, with stereo on, does not
-- even clear the channels another sfx holds.  That is Sound.playStereo below.
local sfxIds  -- { label -> SFX_* id }, derived from data.audio.sfxOrder
local curSfx  -- { src, id } of the last gated sfx that started, i.e. wCurSFX

local function sfxIdFor(data, name)
  local order = data and data.audio and data.audio.sfxOrder
  if not order then return nil end
  if not sfxIds then
    sfxIds = {}
    -- sfxOrder is audio/sfx_pointers.asm in table order, so id = index - 1
    -- (RomExtractorGen2 extractAudio writes it from constants.sfxOrder).
    for index, label in ipairs(order) do sfxIds[label] = index - 1 end
  end
  return sfxIds[name]
end

-- Would PlaySFX start this sound now?  Answers false for `jr c, .done`, which
-- the caller honours by dropping the request whole: a discarded sfx neither
-- sounds nor ducks the music.  The second return is the id to remember as
-- wCurSFX once the sound actually starts.
local function sfxPriorityGate(data, name, def)
  -- Gen 1 keeps today's behaviour: pokered's PlaySound arbitrates by channel
  -- rather than by a single wCurSFX, and Sound.playMove already ports that.
  if type(def) ~= "table" or def.generation ~= 2 then return true end
  local id = sfxIdFor(data, name)
  if not id then return true end
  if curSfx then
    local ok, playing = pcall(curSfx.src.isPlaying, curSfx.src)
    if not (ok and playing) then
      curSfx = nil -- CheckSFX returns no carry; wCurSFX stops mattering
    elseif curSfx.id < id then
      return false -- the sound already going outranks this one
    else
      pcall(curSfx.src.stop, curSfx.src) -- _PlaySFX zeroes ch5-ch8 first
      curSfx = nil
    end
  end
  return true, id
end

-- CheckSFX (home/audio.asm): is a gated sfx still sounding on ch5-ch8?  This
-- is the state WaitSFX blocks on, and it is the gate's OWN wCurSFX rather
-- than whatever the caller last held a source for, so a sound started
-- somewhere else entirely (the A-press beep a textbox plays) still answers
-- busy here.  Phone_StartRinging (engine/phone/phone.asm:564) is the caller
-- that needs it: SFX_CALL is $6a, low enough that any louder sound still on
-- the channels makes sfxPriorityGate DROP the ring outright, where the cart
-- merely waits for it.
function Sound.sfxBusy()
  if not curSfx then return false end
  local ok, playing = pcall(curSfx.src.isPlaying, curSfx.src)
  if not (ok and playing) then
    curSfx = nil -- CheckSFX returns no carry; wCurSFX stops mattering
    return false
  end
  return true
end

-- home/audio.asm:225
function Sound.sfxRemaining()
  if not curSfx then return 0 end
  local ok, playing = pcall(curSfx.src.isPlaying, curSfx.src)
  if not (ok and playing) then
    curSfx = nil
    return 0
  end
  local okd, dur = pcall(curSfx.src.getDuration, curSfx.src)
  local okt, pos = pcall(curSfx.src.tell, curSfx.src)
  if not (okd and okt) then return nil end
  if type(dur) ~= "number" or type(pos) ~= "number" then return nil end
  return math.max(0, dur - pos)
end

-- home/joypad.asm:292
function Sound.playPress(data)
  local src = Sound.play(data, "Press_AB")
  if src and curSfx and curSfx.src == src then curSfx.press = true end
  return src
end

function Sound.dropPressSfx()
  if not (curSfx and curSfx.press) then return end
  pcall(curSfx.src.stop, curSfx.src)
  curSfx = nil
end

-- WaitSFX (home/audio.asm), the drain above GiveItemScript's `specialsound`
-- (engine/overworld/scripting.asm:445), so ch5-ch8 are free for it (#1483).
function Sound.waitSfxDone()
  if not curSfx then return end
  pcall(curSfx.src.stop, curSfx.src)
  curSfx = nil
end

-- SFXChannelsOff (home/audio.asm:545)
function Sound.sfxChannelsOff()
  if not curSfx then return end
  pcall(curSfx.src.stop, curSfx.src)
  curSfx = nil
end

local function startSfx(data, name, def)
  local src = playPath(data, name, def)
  if not src then return end
  if ducks(data, name, def) then
    require("src.core.Music").duckForFanfare(src)
  end
  played("sfx", name)
  return src
end

-- returns the started source (nil headless, when the def failed to load, or
-- when the priority gate dropped the sound) so callers that block on a
-- fanfare like the original's PlaySoundWaitForCurrent -> WaitForSoundToFinish
-- can poll it
function Sound.play(data, name)
  local sfx = data.audio and data.audio.sfx
  name = Sound.resolve(data, name)
  local def = sfx and sfx[name]
  local allowed, id = sfxPriorityGate(data, name, def)
  if not allowed then return end
  local src = startSfx(data, name, def)
  if src and id then curSfx = { src = src, id = id } end
  return src
end

-- PlayStereoSFX (audio/engine.asm), the battle animation path: same sound,
-- same fanfare duck, but no CheckSFX/wCurSFX gate, and it never writes
-- wCurSFX either -- so an animation sound can neither be dropped by, nor
-- become, the priority the overworld path compares against.
function Sound.playStereo(data, name)
  local sfx = data.audio and data.audio.sfx
  name = Sound.resolve(data, name)
  return startSfx(data, name, sfx and sfx[name])
end

-- Play a move's sound with its MoveSoundTable pitch/tempo modifiers
-- (data/moves/sfx.asm; GetMoveSound loads them into wFrequencyModifier/
-- wTempoModifier and the battle sound engine applies them to every
-- battle SFX -- audio/engine_2.asm Audio2_ApplyFrequencyModifier/
-- Audio2_SetSfxTempo).  The extractor pre-synthesizes one WAV per
-- distinct (sfx, pitch, tempo) as "<name>@<pitch><tempo>" keys in the
-- sfx table; older audio.lua builds without the variants fall back to
-- the unmodified sound.
-- anim: a moves.lua anim table { sound, pitch, tempo }.
--
-- Whether a row sound is heard at all is Audio2_PlaySound's channel gate
-- (audio/engine_2.asm .playSfx/.sfxChannelLoop): for every channel the new
-- sfx wants, a channel still busy with a LOWER sound id aborts the whole
-- request (`cp [hl] / jr z,.playChannel / jr c,.playChannel / ret`), while
-- an equal or lower id takes those channels over.  A sound id is
-- (header address - SFX_Headers_1) / 3 (constants/music_constants.asm
-- music_const), so a def's header address orders ids inside one engine
-- bank.  Blizzard's animation is two rows, BLIZZARD then HYDRO_PUMP
-- (data/moves/animations.asm BlizzardAnim), and SFX_BATTLE_29 (CHAN5+8) is
-- still sounding when the second row starts, so the original never plays
-- SFX_BATTLE_2A (CHAN5+6+8) at all -- unguarded, its tail is heard running
-- past the end of the animation (#844).
local moveSfxChannels = {} -- software channel (5-8) -> { src, address, engine }

local function sourceAlive(entry)
  local ok, playing = pcall(entry.src.isPlaying, entry.src)
  return ok and playing
end

local function pruneMoveSfx()
  for ch, cur in pairs(moveSfxChannels) do
    if not sourceAlive(cur) then moveSfxChannels[ch] = nil end
  end
end

-- would PlaySound start this def now?  Taking a channel over also stops the
-- sound that held it, the way .playChannel resets the channel.
local function sfxChannelGate(data, def)
  pruneMoveSfx()
  -- an unrankable def (file asset, or another engine's bank) has no
  -- comparable sound id: leave it to the mixer, as before
  if type(def) ~= "table" or not def.address then return true end
  local channels = require("src.core.ChipSynth").effectChannels(data, def)
  if not channels then return true end
  local takeover
  for _, ch in ipairs(channels) do
    local cur = moveSfxChannels[ch]
    if cur and cur.engine == def.engine then
      if def.address > cur.address then return false end
      takeover = takeover or {}
      takeover[cur.src] = true
    end
  end
  if takeover then
    for ch, cur in pairs(moveSfxChannels) do
      if takeover[cur.src] then moveSfxChannels[ch] = nil end
    end
  end
  return true, takeover
end

local function noteMoveSfx(data, def, src)
  if not src or type(def) ~= "table" or not def.address then
    moveSfxChannels = {}
    return
  end
  local channels = require("src.core.ChipSynth").effectChannels(data, def)
  if not channels then
    moveSfxChannels = {}
    return
  end
  local entry = { src = src, address = def.address, engine = def.engine }
  for _, ch in ipairs(channels) do moveSfxChannels[ch] = entry end
end

-- constants/music_constants.asm:4
local function sfxHeaderId(def)
  if type(def) ~= "table" or not def.address then return nil end
  local rel = def.address - 0x4000
  if rel <= 0 or rel % 3 ~= 0 then return nil end
  return rel / 3
end

local function remainingFrames(src)
  local ok, dur = pcall(src.getDuration, src, "seconds")
  if not ok or type(dur) ~= "number" then return nil end
  local pos
  ok, pos = pcall(src.tell, src, "seconds")
  if not ok or type(pos) ~= "number" then return nil end
  return math.max(0, math.ceil((dur - pos) * 60))
end

-- home/delay.asm:15 WaitForSoundToFinish polls CHAN5/CHAN6/CHAN8
function Sound.moveSfxBusy()
  pruneMoveSfx()
  for _ in pairs(moveSfxChannels) do return true end
  return false
end

function Sound.moveSfxWaitFrames()
  pruneMoveSfx()
  local worst = 0
  for _, cur in pairs(moveSfxChannels) do
    local n = remainingFrames(cur.src)
    if n then
      local okp, pitch = pcall(cur.src.getPitch, cur.src)
      if okp and type(pitch) == "number" and pitch > 0 then
        n = math.ceil(n / pitch * rate)
      end
      n = n + 2
    else
      n = Sound.waitFrames(cur.src, 0)
    end
    if n > worst then worst = n end
  end
  return worst
end

-- audio/engine_2.asm:1077-1096, :991-1013, :1015-1033
local function plainMoveFrames(data, def, channels)
  local id = sfxHeaderId(def)
  local sfx = data.audio and data.audio.sfx
  if not (id and sfx and channels) then return 0 end
  local first = sfxHeaderId(sfx.Peck)            -- constants/music_constants.asm:178
  local last = sfxHeaderId(sfx.Trainer_Appeared) -- constants/music_constants.asm:228
  if not (first and last) then return 0 end
  local claimed = {}
  for _, ch in ipairs(channels) do claimed[ch] = true end
  local base = (claimed[5] or claimed[8]) and id or 0
  local others = {}
  for _, ch in ipairs({ 5, 8 }) do
    local cur = (not claimed[ch]) and moveSfxChannels[ch] or nil
    if cur and cur.engine == def.engine and sourceAlive(cur) then
      local otherId = sfxHeaderId(cur)
      local rem = remainingFrames(cur.src)
      if otherId and rem and rem > 0 then
        others[#others + 1] = { id = otherId, rem = rem }
      end
    end
  end
  table.sort(others, function(a, b) return a.rem < b.rem end)
  local plain = 0
  for drop = 0, #others do
    local combined = base
    for i = drop + 1, #others do
      combined = bit.bor(combined, others[i].id)
    end
    if combined >= first and combined <= last then return plain end
    if drop < #others then plain = others[drop + 1].rem end
  end
  return plain
end

-- the cache key a move sound lives under; playMove and prefetchMove share it
-- so a prefetched entry is exactly the one the play call looks up
local function moveKey(name, pitch, tempo, plain)
  local key = ("%s@%02x%02x"):format(name, pitch, tempo)
  if plain and plain > 0 then key = ("%s~%d"):format(key, plain) end
  return key
end

function Sound.playMove(data, anim)
  if not anim or not anim.sound then return end
  local sfx = data.audio and data.audio.sfx
  if not sfx then return end
  local name = anim.sound
  local pitch, tempo = anim.pitch or 0, anim.tempo or 0x80
  local def = sfx[name]
  local allowed, superseded = sfxChannelGate(data, def)
  if not allowed then return end
  local src
  -- a chip program synthesizes the modified variant on demand; a file def
  -- can only reach for a pre-rendered one
  if isChipDef(def) then
    local plain = 0
    if pitch ~= 0 or tempo ~= 0x80 then
      local channels = require("src.core.ChipSynth").effectChannels(data, def)
      plain = plainMoveFrames(data, def, channels)
    end
    local key = moveKey(name, pitch, tempo, plain)
    src = playPath(data, key, def, pitch, tempo, plain)
  else
    local key = moveKey(name, pitch, tempo)
    if (pitch ~= 0 or tempo ~= 0x80) and sfx[key] then
      src = playPath(data, key, sfx[key])
    else
      src = playPath(data, name, def)
    end
  end
  -- audio/engine_2.asm:1537
  if superseded then
    for old in pairs(superseded) do
      if old ~= src then pcall(old.stop, old) end
    end
  end
  if src then
    played("move", name)
    noteMoveSfx(data, def, src)
  end
end

-- A derived cry ({ base = "RHYDON", pitch, length }) borrows another
-- species' program and applies its own modifiers, so a new species needs no
-- assets at all.  Chains are followed; the modifiers nearest the caller win.
local function resolveCry(data, def, depth)
  if type(def) ~= "table" or not def.base then return def end
  if depth > 8 then return nil, "cry base chain too deep" end
  local cries = data.audio and data.audio.cries
  local baseDef = cries and cries[def.base]
  if not baseDef then
    return nil, "unknown base cry " .. tostring(def.base)
  end
  local resolved, err = resolveCry(data, baseDef, depth + 1)
  if not resolved then return nil, err end
  if type(resolved) ~= "table" or not (resolved.header or resolved.chip) then
    return nil, "base cry " .. tostring(def.base) .. " is not a chip program"
  end
  return {
    header = resolved.header, chip = resolved.chip,
    pitch = def.pitch or resolved.pitch,
    length = def.length or resolved.length,
  }
end

local function newCrySource(data, species, def)
  local resolved, err = resolveCry(data, def, 0)
  if not resolved then return nil, err end
  if type(resolved) == "table" and (resolved.header or resolved.chip) then
    local ok, s = pcall(
      require("src.core.ChipAudio").newCry, data, species, resolved)
    if not ok then return nil, tostring(s) end
    if not s then return nil, "no source" end
    return s
  end
  return newFileSource(resolved)
end

-- Yellow's voiced Pikachu clips (audio/pikachu_pcm.asm
-- PlayPikachuSoundClip): 1-bit PCM decoded to WAVs at import
-- (data.audio.pikaCries = clip count).  Returns the source, nil when the
-- cache carries no clips (Red/Blue) or headless.
function Sound.playPikaCry(data, n)
  if not love.audio then return nil end
  if deviceSuspended() then return nil end
  local count = data.audio and data.audio.pikaCries
  if not count then return nil end
  n = math.max(1, math.min(count, n or 1))
  local key = "pikacry:" .. n
  local src = cache[key]
  if src == false then return nil end
  if not src then
    local path = ("assets/generated/audio/pika_cries/cry_%02d.wav"):format(n)
    local ok, s = pcall(love.audio.newSource, path, "static")
    if not ok or not s then
      cache[key] = false
      return nil
    end
    -- importer historically wrote these as 8-bit mono (RomExtractor
    -- extractPikachuCries); widenMono re-decodes to 16-bit stereo so they
    -- stay off surround outputs (#626).  Fresh extracts are already stereo.
    s = widenMono(s, path)
    pcall(s.setVolume, s, volumeFor(key))
    cache[key] = s
    src = s
  end
  pcall(src.stop, src)
  applyRate(src, 1)
  pcall(src.play, src)
  played("cry", "PIKACHU_PCM_" .. n, "PIKACHU")
  return src
end

-- returns the source (nil headless) so callers that block on the cry
-- like the original's PlayCry -> WaitForSoundToFinish can poll it
function Sound.playCry(data, species, pikaClip)
  if not love.audio then return nil end
  if deviceSuspended() then return nil end
  -- Yellow voices every Pikachu cry with the PCM clips (the chip cry is
  -- never used for the species there).  Which clip is a property of the
  -- call site in the original -- every caller of PlayPikachuSoundClip sets
  -- its own `ldpikacry e, PikachuCryN` -- so pikaClip carries that choice
  -- in; it is ignored for every other species.  Clip 1 is the LONG
  -- title-screen "Pikachuuu" (engine/movie/title.asm:146), kept as the
  -- default only for the sites that have not been given their own clip
  -- yet; battle entrances pass 11/37 (#837).
  if species == "PIKACHU" then
    local src = Sound.playPikaCry(data, pikaClip or 1)
    if src then return src end
  end
  local cries = data.audio and data.audio.cries
  local def = cries and cries[species]
  if not def then return nil end
  local key = "cry:" .. tostring(species)
  local src = cache[key]
  if src == false then return nil end
  if not src then
    local s, err = newCrySource(data, species, def)
    if not s then
      cache[key] = false
      reportBadDef("cry", tostring(species),
        owner(data, "cries", species), err)
      return nil
    end
    pcall(s.setVolume, s, volumeFor(key))
    cache[key] = s
    src = s
  end
  pcall(src.stop, src)
  applyRate(src, 1)
  pcall(src.play, src)
  played("cry", species, species)
  return src
end

-- GROWL/ROAR are the only two moves that play a cry (IsCryMove checks
-- wAnimationID); GetMoveSound still adds their own MoveSoundTable pitch/
-- tempo bytes on top of the cry's species modifiers before the tempo
-- register is set (Audio2_SetSfxTempo: tempo9bit = wTempoModifier+$80).
-- $80 is the table's "no extra shift" tempo byte (every other move's
-- entry defaults to it), so the two moves' own bytes -- Growl's $c0,
-- Roar's $40 -- are the *extra* shift on top of whatever the species'
-- cry already sounds like. The generated cry source already includes the
-- species' pitch/tempo, so layer the move's extra shift on with
-- Source:setPitch (pitch mod is left unmodeled: both moves set it $00).
function Sound.playMoveCry(data, species, tempoMod)
  local src = Sound.playCry(data, species)
  if src and tempoMod and tempoMod ~= 0x80 then
    applyRate(src, 256 / (128 + tempoMod))
  end
  return src
end

-- is a previously played one-shot still sounding?  (ShakeElevator's
-- .musicLoop polls wChannelSoundIDs+CHAN5 until SFX_SAFARI_ZONE_PA
-- ends.)  Headless / never-played names read as silent.
function Sound.isPlaying(name)
  local src = cached(name)
  if not src then return false end
  local ok, playing = pcall(src.isPlaying, src)
  return ok and playing or false
end

-- home/delay.asm:14
function Sound.waitFramesFor(name, fallback)
  local src = cached(name)
  if not src then return 0 end
  return Sound.waitFrames(src, fallback)
end

-- cut a one-shot short (the SFX_STOP_ALL_MUSIC beats around the
-- elevator shake stop the last collision thud mid-ring)
function Sound.stop(name)
  local src = cached(name)
  if src then pcall(src.stop, src) end
end

-- Looping sources (the low-health alarm): started/stopped by game
-- states. ChipAudio generates the two-tone siren used by runtime imports;
-- legacy data can still provide a looping static source.
local loopCache = {}
local looping = {}

function Sound.startLoop(data, name)
  if looping[name] then return end
  if not love.audio then return end
  local sfx = data.audio and data.audio.sfx
  local def = sfx and sfx[name]
  local alarm = not def and name == "Low_Health_Alarm"
  if not def and not alarm then return end
  local src = loopCache[name]
  if src == false then return end
  if not src then
    local s, err
    if alarm then
      -- the synthesized siren is the default, not the rule: a registered
      -- Low_Health_Alarm def of any shape replaces it
      local ok, generated = pcall(require("src.core.ChipAudio").newLowHealthAlarm)
      if ok then s = generated else err = tostring(generated) end
    else
      s, err = newSfxSource(data, name, def)
    end
    if not s then
      loopCache[name] = false
      reportBadDef("sfx", name, owner(data, "sfx", name), err or "no source")
      return
    end
    pcall(s.setLooping, s, true)
    pcall(s.setVolume, s, volumeFor(name))
    loopCache[name] = s
    src = s
  end
  pcall(src.play, src)
  looping[name] = src
end

function Sound.stopLoop(name)
  local src = looping[name]
  if src then
    pcall(src.stop, src)
    looping[name] = nil
  end
end

-- is a looping source currently sounding? (drivers assert on this)
function Sound.isLooping(name)
  return looping[name] ~= nil
end

-- 0-7 SFX volume level (0 mutes); cached sources (menu beeps, cries,
-- the low-health alarm loop) update immediately so the change is heard
-- on the next play
local function reapplyVolumes()
  for key, src in pairs(cache) do
    if src then pcall(src.setVolume, src, volumeFor(key)) end
  end
  for key, src in pairs(loopCache) do
    if src then pcall(src.setVolume, src, volumeFor(key)) end
  end
end

function Sound.setVolumeLevel(level)
  volumeScale = math.max(0, math.min(7, level or 7)) / 7
  reapplyVolumes()
end

-- 0-7 Pikachu-voice trim on top of the SFX level (7 = no trim, 0 mutes the
-- clips while the rest of the SFX bus keeps its level).  Yellow only: on
-- Red/Blue no cached key answers isPikaKey, so this is inert there.
function Sound.setPikaVolumeLevel(level)
  pikaScale = math.max(0, math.min(7, level or 7)) / 7
  reapplyVolumes()
end

-- ---------------------------------------------------------------------------
-- Background pre-render (prefetch)
--
-- The first play of a chip SFX / cry synthesizes it on the calling thread
-- (ChipAudio.newSfx/newCry).  prefetch* asks src/core/sfx_worker.lua to render
-- the SoundData ahead of time; Sound.update (60 Hz, from Music.update) turns the
-- finished SoundData into a Source and files it in `cache` ONLY when that slot
-- is still empty.  A play that arrives first just renders synchronously as it
-- always did, so a play call never returns nil where it returned a Source, and
-- a Source already in the cache (tracked by curSfx / moveSfxChannels / callers
-- timing on it) is never replaced.
--
-- Without love.thread, with POKEPORT_NO_THREAD=1, or if the worker fails to
-- start, every prefetch* is a no-op and nothing changes.
--
-- Worker, queues, epoch and shutdown come from src/core/WorkerLane.lua: at
-- most one lane's in-flight budget of requests sits in the worker at once, so
-- a front-of-queue request overtakes everything not yet sent.
-- ---------------------------------------------------------------------------
local PREFETCH_DRAIN_CAP = 4  -- Sources built per Sound.update

local badKeys = {}            -- keys that failed to render this epoch
local audioRef                -- data.audio the queue was built from
local sentEpoch, sentAudio    -- what the worker was last configured with
local sentMix                 -- the mix / stereo / rate of that configuration

-- A separate thread from the music worker (chip_worker): a long effect render
-- must never delay music buffers.
local fxWorker = WorkerLane.newWorker({
  name = "sfx", script = "src/core/sfx_worker.lua",
  cmd = "sfx_cmd", out = "sfx_out",
  capable = function() return love.audio and love.audio.newSource end,
  onStop = function()
    sentEpoch, sentAudio, audioRef, sentMix = nil, nil, nil, nil
    badKeys = {}
  end,
})
local fxLane = fxWorker:newLane({ inflight = 2 })

-- A render finished (or still running) for the old epoch is discarded when it
-- arrives.  requeue: keep the not-yet-delivered requests and send them again
-- under the new epoch (a mix/rate change); otherwise drop every hint (the
-- cache was invalidated, so the hints may name defs that no longer exist).
local function bumpEpoch(requeue)
  badKeys = {}
  -- renders still waiting in the worker's inbox are obsolete (Lane:bump
  -- clears it); sentEpoch is invalidated so the next request re-sends config
  -- before any render
  sentEpoch, sentMix = nil, nil
  fxLane:bump(requeue)
end

-- ChipAudio calls this when the sample rate, pan or channel mix changes: audio
-- rendered under the old settings must not be filed, but nothing already cached
-- is evicted (it never was).
function Sound.bumpRenderEpoch()
  -- never configured: nothing rendered, so nothing can be stale.  Configured
  -- with exactly the current mix (a setter re-applying the same values, as the
  -- options screen does on every load): in-flight renders are still right.
  local m = sentMix
  if not m then return end
  local ChipSynth = require("src.core.ChipSynth")
  local vols, pits = ChipSynth.getChannelVolumes(), ChipSynth.getChannelPitches()
  local same = m.stereo == ChipSynth.getStereo()
    and m.sampleRate == ChipSynth.SAMPLE_RATE
  for hw = 1, 4 do
    if m.volumes[hw] ~= vols[hw] or m.pitches[hw] ~= pits[hw] then same = false end
  end
  if same then return end
  bumpEpoch(true)
end

function Sound.renderEpoch() return fxLane.epoch end

local function sendRender(entry)
  if cache[entry.key] ~= nil then return false end -- a sync play filled it
  local epoch = fxLane.epoch
  if sentEpoch ~= epoch or sentAudio ~= entry.audio then
    local config = require("src.core.ChipAudio").effectWorkerConfig(entry.data)
    config.cmd, config.epoch = "config", epoch
    if not fxWorker:push(config) then
      fxWorker:fail("config not transferable")
      return false
    end
    sentEpoch, sentAudio = epoch, entry.audio
    sentMix = { volumes = config.volumes, pitches = config.pitches,
                stereo = config.stereo, sampleRate = config.sampleRate }
  end
  if fxWorker:push({
    cmd = "render", epoch = epoch, key = entry.key,
    header = entry.header, options = entry.options,
  }) then
    return true
  end
  badKeys[entry.key] = true -- e.g. a def carrying a function
  return false
end

-- Hand queued entries to the worker, keeping the in-flight budget full.
local function pump()
  fxLane:pump(sendRender)
end

-- A top-level metatable is dropped when a table crosses the channel, so copy
-- the visible (pairs) fields first.  This cannot flatten __index proxies whose
-- fields are not reachable through pairs; such a def would arrive empty and
-- fail to render, leaving the sync path to handle it.
local function plainDef(def)
  if getmetatable(def) == nil then return def end
  local copy = {}
  for k, v in pairs(def) do copy[k] = v end
  return copy
end

-- header/options come from ChipAudio's shared builders, so the worker renders
-- with exactly the arguments the synchronous path would use.
local function enqueue(data, key, header, options, front)
  if not (love.audio and fxWorker:ensure()) then return false end
  if cache[key] ~= nil or badKeys[key] then return false end
  if fxLane.inflight[key] then return true end
  local audio = data.audio
  if audioRef and audioRef ~= audio then bumpEpoch(false) end -- other dataset
  audioRef = audio
  if fxLane:promote(key, front) then return true end -- queued: maybe promoted
  fxLane:push(key, { header = plainDef(header), options = options,
                     data = data, audio = audio }, front)
  pump()
  return true
end

-- Pre-render a chip SFX by name.  opts.front puts it ahead of queued hints.
-- Returns true when a request is pending (queued or newly queued).
function Sound.prefetchSfx(data, name, opts)
  local sfx = data and data.audio and data.audio.sfx
  if not sfx then return false end
  name = Sound.resolve(data, name)
  local def = sfx[name]
  if not isChipDef(def) then return false end -- file defs are already cheap
  local header, options = require("src.core.ChipAudio").sfxRenderArgs(
    data, name, nil, nil, def, nil)
  return enqueue(data, name, header, options, opts and opts.front)
end

-- Pre-render a move sound (anim = { sound, pitch, tempo }).  Only the
-- unmodified-by-channel-overlap key (plain == 0) can be known ahead of time:
-- plainMoveFrames depends on OTHER move sounds still playing on software
-- channels 5/8 when the play call happens (moveSfxChannels), and then `plain`
-- is their remaining frame count -- a timing-dependent number, a different
-- '~N' key (and render) on nearly every overlap.  Not on the battle song, so
-- there is nothing to compute once the music is known.  Measured over real
-- battles (6 wild fights): 81 move plays, 8 sync renders, 6 of them '~N'
-- overlaps (N = 3..20 frames), 2 plain keys the worker had not delivered yet.
-- Overlaps are the minority, so prefetching the plain key is kept; the '~N'
-- variants cannot be predicted and are left to the sync path.
function Sound.prefetchMove(data, anim, opts)
  if not anim or not anim.sound then return false end
  local sfx = data and data.audio and data.audio.sfx
  local def = sfx and sfx[anim.sound]
  if not isChipDef(def) then return false end
  local pitch, tempo = anim.pitch or 0, anim.tempo or 0x80
  local header, options = require("src.core.ChipAudio").sfxRenderArgs(
    data, anim.sound, pitch, tempo, def, 0)
  return enqueue(data, moveKey(anim.sound, pitch, tempo), header, options,
    opts and opts.front)
end

-- Pre-render a species' chip cry.
function Sound.prefetchCry(data, species, opts)
  local audio = data and data.audio
  local cries = audio and audio.cries
  local def = cries and cries[species]
  if not def then return false end
  -- Yellow voices Pikachu with PCM clips; the chip cry is never used there
  if species == "PIKACHU" and audio.pikaCries then return false end
  local resolved = resolveCry(data, def, 0)
  if type(resolved) ~= "table" or not (resolved.header or resolved.chip) then
    return false
  end
  local header, options = require("src.core.ChipAudio").cryRenderArgs(
    data, species, resolved)
  return enqueue(data, "cry:" .. tostring(species), header, options,
    opts and opts.front)
end

-- Cries (and optionally their moves' sounds) for a list of party mons.
function Sound.prefetchMons(data, mons, opts)
  if not mons then return end
  for _, mon in ipairs(mons) do
    if type(mon) == "table" and mon.species then
      Sound.prefetchCry(data, mon.species, opts)
    end
  end
  if not (opts and opts.moves) then return end
  local moves = data and data.moves
  for _, mon in ipairs(mons) do
    for _, move in ipairs(type(mon) == "table" and mon.moves or {}) do
      local mdef = moves and moves[type(move) == "table" and move.id or move]
      if mdef then Sound.prefetchMove(data, mdef.anim, opts) end
    end
  end
end

-- sounds menus and the overworld play first and most often (Gen 1 names, then
-- Gen 2's pokecrystal labels; a name the dataset lacks is skipped)
Sound.COMMON_SFX = {
  "Press_AB", "Start_Menu", "Collision", "Save", "Go_Inside", "Go_Outside",
  "Heal_HP", "Get_Item1", "Get_Item2", "Level_Up", "Tink", "Ledge_Jump",
  "Withdraw_Deposit", "Ball_Toss", "Ball_Poof", "Faint_Fall", "Faint_Thud",
  "Run", "Caught_Mon",
  "Sfx_ReadText2", "Sfx_Wrong", "Sfx_SwitchPokemon", "Sfx_Transaction",
  "Sfx_Potion", "Sfx_CaughtMon",
}

-- sounds a battle plays that are not tied to a mon
Sound.BATTLE_SFX = {
  "Level_Up", "Faint_Fall", "Faint_Thud", "Ball_Toss", "Ball_Poof", "Run",
  "Caught_Mon",
}
-- PlayApplyingAttackSound (engine/battle/core.asm); same pitch bytes as
-- src/battle/EffectRegistry.lua, which plays them through Sound.playMove
Sound.BATTLE_HIT_SOUNDS = {
  { sound = "Damage", pitch = 0x20 },
  { sound = "Super_Effective", pitch = 0xe0 },
  { sound = "Not_Very_Effective", pitch = 0x50 },
}

-- Shortly after a game loads: the common SFX at low priority, then the
-- party's cries.
function Sound.prefetchCommon(data, party)
  Sound.prefetchMons(data, party)
  for _, name in ipairs(Sound.COMMON_SFX) do Sound.prefetchSfx(data, name) end
end

-- A battle was just created, before its transition.  Everything is queued
-- ahead of the boot hints, in the order the battle needs it (a slow device
-- will not finish it all inside the transition): the two leads' cries, the
-- leads' move sounds, the hit sounds, then the rest of both parties (cries,
-- then moves) and the generic battle SFX.  enemyLead / playerLead are the
-- mons that open the battle; the party lists may include them again (dedupe).
function Sound.prefetchBattle(data, playerParty, enemyParty, enemyLead,
                              playerLead)
  -- an earlier battle's leftovers must not delay this one's leads
  fxLane:demoteAll()
  local front = { front = true }
  local movesToo = { front = true, moves = true }
  local leads = {}
  if enemyLead then leads[#leads + 1] = enemyLead end
  if playerLead then leads[#leads + 1] = playerLead end
  Sound.prefetchMons(data, leads, front)
  Sound.prefetchMons(data, leads, movesToo)
  for _, anim in ipairs(Sound.BATTLE_HIT_SOUNDS) do
    Sound.prefetchMove(data, anim, front)
  end
  Sound.prefetchMons(data, enemyParty, front)
  Sound.prefetchMons(data, playerParty, front)
  Sound.prefetchMons(data, enemyParty, movesToo)
  Sound.prefetchMons(data, playerParty, movesToo)
  for _, name in ipairs(Sound.BATTLE_SFX) do
    Sound.prefetchSfx(data, name, front)
  end
end

-- nothing queued, nothing out at the worker (always true without a thread)
function Sound.prefetchIdle()
  if not fxWorker.state then return true end
  return fxLane:idle()
end

-- test/debug: how many requests are waiting or at the worker
function Sound.prefetchPending()
  return fxLane:pending()
end

-- Per-frame drain, called from Music.update (both Game and Game2 tick it at
-- 60 Hz).  Fills EMPTY cache slots only.
function Sound.update()
  if not fxWorker.state then return end
  if deviceSuspended() then return end
  local drained = fxWorker:drain(PREFETCH_DRAIN_CAP, function(result)
    local key = result.key
    -- a result is current only if it answers the request still in flight
    -- under this epoch; anything else (invalidated, superseded) is dropped
    if not fxLane:complete(key, result.epoch) then return false end
    if result.sd and cache[key] == nil then
      local ok, src = pcall(love.audio.newSource, result.sd, "static")
      if ok and src then
        pcall(src.setVolume, src, volumeFor(key))
        cache[key] = src
        return true -- only Sources actually built count against the cap
      end
    elseif not result.sd then
      badKeys[key] = true -- the sync path will reproduce and log it
    end
    return false
  end)
  if drained then pump() end
end

-- End the worker thread (LOVE waits for live threads at exit).  Safe to call
-- repeatedly; the next prefetch starts a fresh worker.  (Also registered with
-- SessionLifecycle by WorkerLane.)
function Sound.shutdown()
  fxWorker:shutdown()
end

function Sound._setNoThreadEnvForTest(value)
  fxWorker.noThread = value
  fxWorker.state = nil -- test reset: also clears a fatal "off"
end

function Sound._setPrefetchLimitsForTest(inflightMax, drainCap)
  fxLane.inflightMax = inflightMax or 2
  PREFETCH_DRAIN_CAP = drainCap or 4
end

-- hot reload / jukebox A-B: drop one key's sources (its pitch-tempo
-- variants included) or all of them, so the next play re-resolves the def
function Sound.invalidate(name)
  bumpEpoch(false) -- in-flight renders were built from the old defs
  moveSfxChannels = {} -- their sources are about to be dropped or stopped
  -- Same for wCurSFX, and a reloaded table can repoint the id order.
  curSfx = nil
  sfxIds = nil
  -- A replaced def may claim a different set of channels.
  if name then channelCounts[name] = nil else channelCounts = {} end
  -- A mod that registers the raw name outright ends the alias hop, so the
  -- memo has to be re-derived from the reloaded sfx table too.
  if name then aliased[name] = nil else aliased = {} end
  local function evict(store, key)
    local src = store[key]
    if src then pcall(src.stop, src) end
    store[key] = nil
  end
  for _, store in ipairs({ cache, loopCache }) do
    for key in pairs(store) do
      if not name or key == name or key:sub(1, #name + 1) == name .. "@" then
        evict(store, key)
      end
    end
  end
  for key, src in pairs(looping) do
    if not name or key == name then
      pcall(src.stop, src)
      looping[key] = nil
    end
  end
end

-- the flush fan-out calls with no key, dropping everything, so an edited
-- def is re-resolved on the next play (20 §2 cache contract, audio row)
Assets.register(Sound.invalidate)

function Sound.onDeviceReset()
  Sound.invalidate()
end

-- re-apply persisted audio options (Game calls this on boot and after
-- loading a save)
function Sound.applyOptions(opts)
  Sound.setVolumeLevel(opts and opts.sfxVol or 7)
  Sound.setPikaVolumeLevel(opts and opts.pikaVol or 7)
end

return Sound

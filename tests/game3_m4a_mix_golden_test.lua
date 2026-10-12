package.path = "./?.lua;./?/init.lua;" .. package.path

-- Golden checksums for the software mixer. Optional arg[1]: module name to test.
local T = require("tests.harness")
local Mix = require(arg and arg[1] or "src.core.game3.m4a_mix")

local function pcm_bytes(n, mul, add)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.char((i * mul + add + (i * i) % 7) % 256) end
  return table.concat(t)
end

local function build()
  local loopPcm = pcm_bytes(300, 37, 5)
  local onePcm = pcm_bytes(5000, 11, 90)
  local ds1 = Mix.newDsVoice(loopPcm, { size = 300, loopStart = 40 }, { loop = true, rate = 13379, volL = 0.7, volR = 0.3 })
  local ds2 = Mix.newDsVoice(onePcm, { size = 5000 }, { rate = 1.9 * Mix.SAMPLE_RATE, volL = 0.4, volR = 0.6 })
  ds2.step = 1.9
  local pulse = Mix.newCgbPulse({ key = 60, duty = 1, cgbChan = 1, tone = { pan = 0x11 } })
  pulse.envVol = 12
  local pulseL = Mix.newCgbPulse({ key = 67, duty = 0, cgbChan = 2 })
  pulseL.routeR = false
  pulseL.envVol = 9
  local wave = {}
  for i = 1, 32 do wave[i] = (i * 5) % 16 end
  local w = Mix.newCgbWave({ wave = wave, key = 55 })
  w.envVol = 15
  local noise = Mix.newCgbNoise({ key = 70, tone = { wavParam = 1 } })
  noise.envVol = 11
  noise.lengthRemaining = 6000
  return { ds1, ds2, pulse, pulseL, w, noise }
end

local function run()
  local voices = build()
  local reverb = Mix.newReverb(70)
  Mix._hpfCapL, Mix._hpfCapR = 0, 0
  local sumL, sumR, wsum, count, alive = 0, 0, 0, 0, 0
  for block = 1, 20 do
    local L, R, al = Mix.render(voices, 735, { raw = true, reverbState = reverb })
    T.check(al == voices, "raw: alive is the compacted input list")
    for i = 1, 735 do
      local idx = (block - 1) * 735 + i
      sumL = sumL + L[i]
      sumR = sumR + R[i]
      wsum = wsum + (L[i] - 0.5 * R[i]) * (idx % 97 + 1)
    end
    count = count + 735
    alive = #al
  end
  return string.format("%.9f %.9f %.9f", sumL, sumR, wsum), alive, count
end

local EXPECTED = { 377.670885062, 327.892068347, 9754.786721130 }
local EXPECTED_ALIVE = 3
local TOL = 1e-6

local got, alive = run()
print(got, alive)
local nums = {}
for tok in got:gmatch("%S+") do nums[#nums + 1] = tonumber(tok) end
T.eq(#nums, 3, "golden: three checksums")
for k = 1, 3 do
  T.check(nums[k] ~= nil and math.abs(nums[k] - EXPECTED[k]) < TOL,
    "golden checksum " .. k .. " got " .. tostring(nums[k]) .. " expected " .. EXPECTED[k])
end
T.eq(alive, EXPECTED_ALIVE, "golden: alive count")
-- Second run must be reproducible (no state leaking through scratch buffers).
local again, alive2 = run()
T.eq(again, got, "golden: second run reproducible")
T.eq(alive2, alive, "golden: second run alive count")

-- Non-raw render (scratch buffers + SoundData) must match raw sample-for-sample.
local function clip(x) if x > 1 then return 1 elseif x < -1 then return -1 end return x end
local sizes = { 735, 300, 735 }

local function raw_blocks()
  local voices, reverb = build(), Mix.newReverb(70)
  Mix._hpfCapL, Mix._hpfCapR = 0, 0
  local out = {}
  for b, n in ipairs(sizes) do
    local L, R = Mix.render(voices, n, { raw = true, reverbState = reverb })
    out[b] = { L = L, R = R, n = n }
  end
  return out
end

local function soundData_blocks()
  local voices, reverb = build(), Mix.newReverb(70)
  Mix._hpfCapL, Mix._hpfCapR = 0, 0
  local out, n_alive = {}, nil
  for b, n in ipairs(sizes) do
    local sd, al = Mix.render(voices, n, { reverbState = reverb })
    out[b] = sd
    n_alive = al
    T.check(al == voices, "non-raw: alive is the compacted input list")
  end
  return out, n_alive, voices
end

local saved_love = love
love = { sound = { newSoundData = function(n, rate, bits, ch)
  local sd = { n = n, rate = rate, bits = bits, ch = ch, s = {} }
  function sd:setSample(i, a, b)
    if b == nil then self.s[i] = { a, a } -- mono form: (index, value)
    else
      self.s[i] = self.s[i] or {}
      self.s[i][a] = b
    end
  end
  return sd
end } }
local rawOut = raw_blocks()
local sdOut, nrAlive, nrVoices = soundData_blocks()
love = saved_love

local worst = 0
for b, blk in ipairs(rawOut) do
  local sd = sdOut[b]
  T.eq(sd.n, blk.n, "non-raw block " .. b .. " length")
  T.eq(sd.ch, 2, "non-raw block " .. b .. " channels")
  for i = 1, blk.n do
    local e = sd.s[i - 1]
    worst = math.max(worst, math.abs(e[1] - clip(blk.L[i])), math.abs(e[2] - clip(blk.R[i])))
  end
end
T.check(worst < TOL, "non-raw matches raw (worst diff " .. worst .. ")")
T.eq(#nrAlive, #nrVoices, "non-raw: list length matches alive")
for _, v in ipairs(nrVoices) do T.check(v.alive, "non-raw: only live voices remain") end

-- Raw mode compacts the caller's list in place, same as non-raw.
do
  local dead = { kind = "cgb_pulse", alive = false }
  local live = Mix.newCgbPulse({ key = 60, duty = 1, cgbChan = 1 })
  live.envVol = 10
  local voices = { dead, live }
  local _, _, al = Mix.render(voices, 64, { raw = true })
  T.check(al == voices, "raw: returns the same list")
  T.eq(#voices, 1, "raw: dead voice compacted out in place")
  T.check(voices[1] == live, "raw: live voice kept")
end

-- Player.renderSlot adopts the compacted list as slot.voices.
do
  local okp, Player = pcall(require, "src.core.game3.m4a_player")
  if not okp then
    print("SKIP renderSlot test: " .. tostring(Player))
  else
    for _, raw in ipairs({ true, false }) do
      local dead = { kind = "cgb_pulse", alive = false }
      local live = Mix.newCgbPulse({ key = 60, duty = 1, cgbChan = 1 })
      live.envVol = 10
      local list = { dead, live }
      local slot = { voices = list, seq = { voices = list } }
      Player.renderSlot(slot, 64, { raw = raw })
      local tag = raw and "raw" or "non-raw"
      T.check(slot.voices == list, "renderSlot " .. tag .. ": slot.voices is the compacted list")
      T.eq(#slot.voices, 1, "renderSlot " .. tag .. ": dead voice removed")
      T.check(slot.seq.voices == slot.voices, "renderSlot " .. tag .. ": seq.voices still the same list")
    end
  end
end

-- Sweep voice that dies mid-block: phase must still be written back.
do
  local v = Mix.newCgbPulse({ key = 60, duty = 2, cgbChan = 1 })
  v.envVol = 10
  v.sweepEnabled = true
  v.sweepNr10 = 0x11 -- time 1, add, shift 1
  v.sweepShadow = 2000 -- 2000 + 1000 > 2047
  v.sweepTimer = 1
  v.sweepAcc = 0
  v.phase = 0.25
  Mix._hpfCapL, Mix._hpfCapR = 0, 0
  local _, _, al = Mix.render({ v }, 735, { raw = true })
  T.eq(v.alive, false, "sweep overflow kills the voice")
  T.eq(#al, 0, "sweep death: not in alive list")
  T.check(v.phase ~= 0.25 and v.phase >= 0 and v.phase < 1, "sweep death: phase written back")
end

-- Exhausted length with unset kind-specific fields must not error.
do
  local pulse = { kind = "cgb_pulse", alive = true, lengthRemaining = 0 }
  local wave = { kind = "cgb_wave", alive = true, lengthRemaining = 0 }
  local noise = { kind = "cgb_noise", alive = true, lengthRemaining = 0 }
  local okc, err = pcall(Mix.render, { pulse, wave, noise }, 64, { raw = true })
  T.check(okc, "lengthRemaining = 0 with nil fields: " .. tostring(err))
  T.eq(pulse.alive, false, "exhausted pulse dies")
  T.eq(wave.alive, false, "exhausted wave dies")
  T.eq(noise.alive, false, "exhausted noise dies")
end

T.finish("game3_m4a_mix_golden_test")

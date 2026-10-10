-- In-game frame-time profiler + overlay (F3), and a headless bench mode.
--
-- Presentation/diagnostics only: it reads a clock and writes to its own
-- tables.  It never touches game state, RNG or FixedStep, so it cannot
-- affect determinism.  Everything is a near-free early return unless the
-- overlay is shown (F3 / POKEPORT_GAME_PROF_OVERLAY=1) or bench mode is on
-- (POKEPORT_GAME_PROF=<frames>).
--
-- Pure Lua: no top-level love requires, so it loads under plain luajit.

local FrameProfiler = {}

FrameProfiler.WINDOW = 120   -- rolling frames kept per section
FrameProfiler.WARMUP = 60    -- frames dropped before bench recording starts
FrameProfiler.enabled = false  -- overlay visible (and recording)
FrameProfiler.clock = nil      -- seconds; defaults lazily to love.timer.getTime
FrameProfiler.out = nil        -- bench writer; defaults to io.stderr
FrameProfiler.SPIKE_MS = 16.7  -- frames over this are spike candidates
FrameProfiler.SPIKE_KEEP = 10  -- worst spikes retained
FrameProfiler.ALL_CAP = 200000 -- window for POKEPORT_GAME_PROF=all
FrameProfiler.context = nil    -- optional fn() -> short label for a spike

local benchTarget = nil   -- frames to record in bench mode, or nil
local benchSeen = 0       -- frames seen (including warmup)
local benchDone = false
local benchAll = false
local recorded = 0       -- recorded (post-warmup) frames
local spikes = {}
local over16, over33 = 0, 0
local inited = false

local inFrame = false
local frameStart = 0
local cur = {}            -- name -> ms accumulated this frame
local depth = {}          -- name -> nesting depth
local starts = {}         -- name -> start time of outermost push
local order = {}          -- section names in first-seen order
local rings = {}          -- name -> ring
local frameRing
local lastEnd = nil
local intervalRing
local luaRing, drawRing, texRing
local gcProbe = false      -- POKEPORT_GC_PROBE=1: per-frame Lua heap growth
local allocRing, heapStart = nil, 0
local heapMin, heapMax = math.huge, 0
local gfx = { drawcalls = 0, canvasswitches = 0, texturememory = 0 }
local overlayText, overlayAt = "", -1

local function newRing(cap)
  return { cap = cap, n = 0, pos = 0, v = {} }
end

local function ringAdd(r, x)
  r.pos = r.pos % r.cap + 1
  r.v[r.pos] = x
  if r.n < r.cap then r.n = r.n + 1 end
end

local function ringStats(r)
  if not r or r.n == 0 then return { mean = 0, p95 = 0, worst = 0 } end
  local a, sum, worst = {}, 0, 0
  for i = 1, r.n do
    local x = r.v[i]
    a[i] = x
    sum = sum + x
    if x > worst then worst = x end
  end
  table.sort(a)
  local idx = math.ceil(0.95 * r.n)
  if idx < 1 then idx = 1 end
  return { mean = sum / r.n, p95 = a[idx], worst = worst }
end

local function window()
  return benchTarget or FrameProfiler.WINDOW
end

local function resetData()
  cur, depth, starts, order, rings = {}, {}, {}, {}, {}
  local cap = window()
  frameRing = newRing(cap)
  intervalRing = newRing(cap)
  luaRing, drawRing, texRing = newRing(cap), newRing(cap), newRing(cap)
  allocRing = newRing(cap)
  heapMin, heapMax = math.huge, 0
  lastEnd = nil
  inFrame = false
  recorded, spikes, over16, over33 = 0, {}, 0, 0
  overlayText, overlayAt = "", -1
end

local function now()
  local c = FrameProfiler.clock
  if not c then
    c = love.timer.getTime
    FrameProfiler.clock = c
  end
  return c()
end

-- Reads env (or the supplied getenv) and resets all recorded data.
function FrameProfiler.init(getenv)
  getenv = getenv or os.getenv
  inited = true
  benchTarget, benchSeen, benchDone, benchAll = nil, 0, false, false
  local pv = getenv("POKEPORT_GAME_PROF")
  if pv == "all" then
    benchAll, benchTarget = true, FrameProfiler.ALL_CAP
  else
    local n = tonumber(pv)
    if n and n >= 1 then benchTarget = math.floor(n) end
  end
  gcProbe = getenv("POKEPORT_GC_PROBE") == "1"
  local ov = getenv("POKEPORT_GAME_PROF_OVERLAY")
  FrameProfiler.enabled = (ov ~= nil and ov ~= "" and ov ~= "0") or false
  resetData()
end

function FrameProfiler.setEnabled(b)
  if not inited then FrameProfiler.init() end
  -- hiding the F3 box logs its numbers first (see finish)
  if not b and FrameProfiler.enabled then FrameProfiler.finish() end
  FrameProfiler.enabled = b and true or false
  if FrameProfiler.enabled then
    -- fresh window so stale numbers from before the toggle don't linger
    if not benchTarget then resetData() end
  end
end

function FrameProfiler.toggle()
  if not inited then FrameProfiler.init() end
  FrameProfiler.setEnabled(not FrameProfiler.enabled)
end

-- F3 gate + dispatch.  The key is always delivered to game:keypressed first
-- (raw-key capture states, mod key hooks and player bindings see it), and the
-- overlay toggles only if nothing wanted it: no state on top of the game's
-- stack owns raw keys (onKeyPressed) and F3 is not bound to an action.
-- `input` is the Input module (keyBindings); both lookups are pcall-guarded so
-- a Gen 1/2/3 game without the field simply counts as "free".
function FrameProfiler.keypressed(key, game, input) -- key is "f3"
  local free = true
  local okTop, top = pcall(function()
    local stack = game and game.stack
    return stack and stack:top() or nil
  end)
  if okTop and top and top.onKeyPressed then free = false end
  local okBind, bound = pcall(function()
    local kb = input and input.keyBindings
    return kb and kb.f3 ~= nil
  end)
  if okBind and bound then free = false end
  if game then game:keypressed(key) end
  if free then FrameProfiler.toggle() end
  return free
end

-- True when the overlay should be drawn this frame.
function FrameProfiler.visible()
  return FrameProfiler.enabled and inFrame
end

local function active()
  return FrameProfiler.enabled or (benchTarget ~= nil and not benchDone)
end

-- `gameActive` is false in the launcher/editors: those never record.
function FrameProfiler.beginFrame(gameActive)
  if not inited then FrameProfiler.init() end
  inFrame = false
  if gameActive == false or not active() then
    lastEnd = nil -- a gap (launcher, inactive) must not become a frame interval
    return
  end
  inFrame = true
  for k in pairs(cur) do cur[k] = 0 end
  for k in pairs(depth) do depth[k] = 0 end
  frameStart = now()
  if gcProbe then heapStart = collectgarbage("count") end
end

function FrameProfiler.push(name)
  if not inFrame then return end
  local d = depth[name] or 0
  depth[name] = d + 1
  if d == 0 then starts[name] = now() end
end

function FrameProfiler.pop(name)
  if not inFrame then return end
  local d = depth[name] or 0
  if d <= 0 then return end
  depth[name] = d - 1
  if d == 1 then
    local ms = (now() - starts[name]) * 1000
    if cur[name] == nil then
      order[#order + 1] = name
      rings[name] = newRing(window())
    end
    cur[name] = (cur[name] or 0) + ms
  end
end

-- love.graphics.getStats() resets on present, so sample before it.
function FrameProfiler.sampleGfx()
  if not inFrame then return end
  local g = love and love.graphics
  if g and g.getStats then
    local s = g.getStats()
    gfx.drawcalls = s.drawcalls or 0
    gfx.canvasswitches = s.canvasswitches or 0
    gfx.texturememory = s.texturememory or 0
  end
end

function FrameProfiler.stats(name)
  if name == "frame" then return ringStats(frameRing) end
  return ringStats(rings[name])
end

function FrameProfiler.sections()
  return order
end

function FrameProfiler.fps()
  local r = intervalRing
  if not r or r.n == 0 then return 0 end
  local sum = 0
  for i = 1, r.n do sum = sum + r.v[i] end
  if sum <= 0 then return 0 end
  return r.n / sum
end

local function mean(r)
  return ringStats(r).mean
end

local function emitBench()
  local w = FrameProfiler.out or function(s) io.stderr:write(s) end
  local lines = {}
  for _, name in ipairs(order) do
    local s = ringStats(rings[name])
    lines[#lines + 1] = ("PROF %s mean=%.3fms p95=%.3fms worst=%.3fms")
      :format(name, s.mean, s.p95, s.worst)
  end
  local f = ringStats(frameRing)
  lines[#lines + 1] = ("PROF frame mean=%.3fms p95=%.3fms worst=%.3fms")
    :format(f.mean, f.p95, f.worst)
  lines[#lines + 1] = ("PROF fps=%.1f"):format(FrameProfiler.fps())
  lines[#lines + 1] = ("PROF lua_kb=%.0f drawcalls=%.0f texture_mb=%.1f")
    :format(mean(luaRing), mean(drawRing), mean(texRing) / (1024 * 1024))
  if gcProbe then
    -- end - start clamped at 0: a collection inside the frame hides garbage,
    -- so this underestimates allocation
    local a = ringStats(allocRing)
    lines[#lines + 1] = ("PROF alloc_kb mean=%.1f p95=%.1f worst=%.1f (underestimate: GC inside a frame is clamped to 0)")
      :format(a.mean, a.p95, a.worst)
    lines[#lines + 1] = ("PROF heap_kb min=%.0f max=%.0f"):format(
      heapMin == math.huge and 0 or heapMin, heapMax)
  end
  lines[#lines + 1] = ("PROF spikes over16=%d over33=%d"):format(over16, over33)
  for i, sp in ipairs(spikes) do
    local parts = {}
    for _, e in ipairs(sp.secs) do
      parts[#parts + 1] = ("%s=%.1fms"):format(e[1], e[2])
    end
    lines[#lines + 1] = ("PROF spike #%d frame=%d total=%.1fms %s ctx=%s"):format(
      i, sp.frame, sp.total, table.concat(parts, " "), sp.ctx)
  end
  w(table.concat(lines, "\n") .. "\n")
end

function FrameProfiler.spikeList() return spikes end
function FrameProfiler.spikeCounts() return over16, over33 end

local function recordSpike(total)
  local secs = {}
  for _, name in ipairs(order) do
    local ms = cur[name] or 0
    if ms > 0.5 then secs[#secs + 1] = { name, ms } end
  end
  local ctx = "?"
  if FrameProfiler.context then
    local ok, r = pcall(FrameProfiler.context)
    if ok and r then ctx = tostring(r) end
  end
  spikes[#spikes + 1] = { frame = recorded, total = total, secs = secs, ctx = ctx }
  table.sort(spikes, function(a, b) return a.total > b.total end)
  while #spikes > FrameProfiler.SPIKE_KEEP do spikes[#spikes] = nil end
end

-- Emit the bench summary now if bench mode is on and not yet emitted
-- (love.quit, so `all` mode and early exits still report).  No quit call.
function FrameProfiler.finish()
  if not benchTarget then
    -- overlay session: one line of what the F3 box showed (last WINDOW
    -- frames); handheld builds log stderr to the launch-failure log.txt
    if FrameProfiler.enabled and frameRing and frameRing.n > 0 then
      local f = ringStats(frameRing)
      local w = FrameProfiler.out or function(s) io.stderr:write(s) end
      w(("PROF overlay fps=%.1f frame mean=%.3fms p95=%.3fms worst=%.3fms over16=%d over33=%d\n")
        :format(FrameProfiler.fps(), f.mean, f.p95, f.worst, over16, over33))
    end
    return
  end
  if benchDone or recorded == 0 then return end
  benchDone = true
  emitBench()
end

function FrameProfiler.endFrame()
  if not inFrame then return end
  inFrame = false
  local t = now()
  local total = (t - frameStart) * 1000
  local interval = lastEnd and (t - lastEnd) or nil
  lastEnd = t

  if benchTarget then
    benchSeen = benchSeen + 1
    if benchSeen <= FrameProfiler.WARMUP then return end
  end

  recorded = recorded + 1
  if total > 33.3 then over33 = over33 + 1 end
  if total > 16.7 then over16 = over16 + 1 end
  if total > FrameProfiler.SPIKE_MS then recordSpike(total) end
  ringAdd(frameRing, total)
  if interval then ringAdd(intervalRing, interval) end
  for _, name in ipairs(order) do
    ringAdd(rings[name], cur[name] or 0)
  end
  local kb = collectgarbage("count")
  ringAdd(luaRing, kb)
  if gcProbe then
    ringAdd(allocRing, math.max(0, kb - heapStart))
    if kb < heapMin then heapMin = kb end
    if kb > heapMax then heapMax = kb end
  end
  ringAdd(drawRing, gfx.drawcalls)
  ringAdd(texRing, gfx.texturememory)

  if benchTarget and not benchAll and not benchDone and recorded >= benchTarget then
    benchDone = true
    emitBench()
    if love and love.event and love.event.quit then love.event.quit() end
  end
end

-- Compact overlay, top-left, screen space.  Text is rebuilt ~4x/sec.
function FrameProfiler.draw()
  if not FrameProfiler.enabled then return end
  local g = love.graphics
  local t = now()
  if t - overlayAt >= 0.25 then
    overlayAt = t
    local f = ringStats(frameRing)
    local lines = {
      ("FPS %.0f"):format(FrameProfiler.fps()),
      ("frame %.2f / %.2f / %.2f ms"):format(f.mean, f.p95, f.worst),
    }
    for _, name in ipairs(order) do
      local s = ringStats(rings[name])
      lines[#lines + 1] = ("%s %.2f / %.2f"):format(name, s.mean, s.p95)
    end
    lines[#lines + 1] = ("lua %.0f KB"):format(collectgarbage("count"))
    lines[#lines + 1] = ("draws %d  canvas %d"):format(gfx.drawcalls, gfx.canvasswitches)
    lines[#lines + 1] = ("tex %.1f MB"):format(gfx.texturememory / (1024 * 1024))
    lines[#lines + 1] = ("spikes >16ms: %d  >33ms: %d"):format(over16, over33)
    overlayText = table.concat(lines, "\n")
  end
  g.push("all")
  g.origin()
  g.setColor(0, 0, 0, 0.6)
  g.rectangle("fill", 4, 4, 190, 14 * (select(2, overlayText:gsub("\n", "")) + 1) + 8)
  g.setColor(1, 1, 1, 1)
  g.print(overlayText, 8, 8)
  g.pop()
end

return FrameProfiler

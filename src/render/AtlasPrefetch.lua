-- Background pre-bake of RED++ tileset atlases (see TileRenderer's
-- getGbcAtlas, src/render/AtlasBake.lua, src/render/atlas_worker.lua).
--
-- A map's first TileRenderer under COLORS = RED++ recolors its whole atlas
-- pixel by pixel.  Done inside a seam crossing or a warp that is a visible
-- hitch on a handheld, so the overworld asks for the atlases it is about to
-- need (the maps one crossing away, a warp's destination) and the worker bakes
-- them ahead of time.  The finished ImageData waits in a bounded "ready" store
-- until getGbcAtlas turns it into an Image (newImage stays on the main thread,
-- lazily, so draining costs no GPU work).  A request that has not finished by
-- the time its map is built is simply baked synchronously as it always was,
-- and the late result is then dropped because the slot is filled.
--
-- Without love.thread, with POKEPORT_NO_THREAD=1, or if the worker fails to
-- start or dies, request() is a no-op and nothing changes.
--
-- Queueing lives on this side (a Channel cannot reorder or drop): at most
-- INFLIGHT bakes sit in the worker at once, so a front-of-queue request
-- overtakes everything not yet sent.  Every request is a closure that builds
-- its payload (source ImageData, per-tile colours) only when it is sent, so
-- queued hints cost nothing until their turn.

local Logger = require("src.core.Logger")

local AtlasPrefetch = {}

local READY_CAP = 24      -- finished ImageData kept for getGbcAtlas
local DRAIN_CAP = 2       -- results accepted per update
local SEND_CAP = 1        -- payloads built (and sent) per update
local INFLIGHT = 2        -- bakes handed to the worker at a time

-- Image FILE decodes share the worker (Assets.image / Assets.imageData read
-- the result): their own queues and in-flight budget, so a bake never sits
-- behind a long run of decodes (each is a short job) and vice versa.
local DEC_READY_CAP = 64  -- decoded ImageData kept, keyed by resolved path
local DEC_INFLIGHT = 4    -- decodes handed to the worker at a time
local DEC_SEND_CAP = 4    -- decode commands sent per update
local DEC_EXAMINE_CAP = 8 -- queued entries looked at per update (each resolves)

local epoch = 0
local dqHigh, dqLow, dByKey = {}, {}, {}  -- queued decodes, not yet sent
local dInflight, dInflightCount = {}, 0
local dready, dreadySeq = {}, 0           -- path -> { data, seq }
local qHigh, qLow, byKey = {}, {}, {}  -- queued entries, not yet sent
local inflight, inflightCount = {}, 0  -- key -> entry at the worker
local ready, readySeq = {}, 0          -- key -> { data, seq }
local sources = {}                     -- image path -> source ImageData
local noThreadEnv = os.getenv("POKEPORT_NO_THREAD")
local worker, cmdCh, outCh
local state                            -- nil = untried, true = running, false = off

-- Set by TileRenderer: true while the key already has a gbcAtlasCache slot.
AtlasPrefetch.isFilled = function() return false end

local function ensureWorker()
  if state ~= nil then return state end
  state = false
  if noThreadEnv == "1" then return false end
  if not (love.thread and love.thread.newThread and love.thread.getChannel
      and love.image and love.image.newImageData) then
    return false
  end
  local ok, thread = pcall(love.thread.newThread, "src/render/atlas_worker.lua")
  if not ok or not thread then return false end
  cmdCh = love.thread.getChannel("atlas_cmd")
  outCh = love.thread.getChannel("atlas_out")
  -- channels are process-global: drop anything a previous run left behind
  pcall(cmdCh.clear, cmdCh)
  pcall(outCh.clear, outCh)
  if not pcall(function() thread:start() end) then return false end
  worker = thread
  state = true
  return true
end

local function clearQueues()
  qHigh, qLow, byKey = {}, {}, {}
  inflight, inflightCount = {}, 0
  dqHigh, dqLow, dByKey = {}, {}, {}
  dInflight, dInflightCount = {}, 0
end

local function failWorker(reason)
  if reason then Logger.warn("atlas worker off: %s", tostring(reason)) end
  if cmdCh then pcall(cmdCh.push, cmdCh, { cmd = "quit" }) end
  state = false
  worker, cmdCh, outCh = nil, nil, nil
  clearQueues()
  ready, sources, dready = {}, {}, {}
end

-- Everything pending or finished is obsolete (assets / palette mode / mod
-- state changed).  A bake still running is discarded when it arrives.
function AtlasPrefetch.bump()
  epoch = epoch + 1
  clearQueues()
  ready, sources, dready = {}, {}, {}
  -- bakes still waiting in the worker's inbox are obsolete too
  if cmdCh then pcall(cmdCh.clear, cmdCh) end
end

function AtlasPrefetch.epoch() return epoch end

-- true when a bake for `key` is already at the worker or finished (a merely
-- queued one is not "known": request() promotes it when asked for the front)
function AtlasPrefetch.known(key)
  return inflight[key] ~= nil or ready[key] ~= nil
end

-- Source ImageData for an image path, decoded once per epoch.  loader is
-- Assets.imageData; the object is only read afterwards (the worker shares it).
function AtlasPrefetch.source(path, loader)
  local src = sources[path]
  if not src then
    src = loader(path)
    sources[path] = src
  end
  return src
end

-- true when a worker is (or can be) running; callers skip building hints
-- otherwise (no love.thread, POKEPORT_NO_THREAD=1, start failure, dead worker)
function AtlasPrefetch.available()
  return ensureWorker()
end

-- Queue a bake.  make() -> payload { src, perRow, tileColors, aliases } or
-- nil to skip; it runs when the request is sent.  front puts it ahead of
-- queued hints (and promotes a hint already queued).  Returns true when a
-- request is pending.
function AtlasPrefetch.request(key, make, front)
  if not ensureWorker() then return false end
  if ready[key] or inflight[key] then return true end
  local entry = byKey[key]
  if entry then
    if front then
      for i, e in ipairs(qLow) do
        if e == entry then table.remove(qLow, i) table.insert(qHigh, entry) break end
      end
    end
    return true
  end
  entry = { key = key, make = make }
  byKey[key] = entry
  table.insert(front and qHigh or qLow, entry)
  return true
end

-- Hand a finished ImageData to getGbcAtlas (removes it from the store).
function AtlasPrefetch.take(key)
  local r = ready[key]
  if not r then return nil end
  ready[key] = nil
  return r.data
end

-- The slot was filled another way (sync bake): nothing queued or finished
-- for it is needed any more.  A bake already at the worker is dropped on
-- arrival (isFilled).
function AtlasPrefetch.forget(key)
  ready[key] = nil
  local entry = byKey[key]
  if entry then
    byKey[key] = nil
    entry.dead = true
  end
end

-- Set by Assets: resolveDecodable(path) -> resolved path of a plain PNG, or
-- nil; imageCached(resolved) -> true when Assets already holds its Image.
-- Resolution (a filesystem lookup per mod) is deferred to the send, so queueing
-- a hint costs the crossing nothing.
AtlasPrefetch.resolveDecodable = function(path) return path end
AtlasPrefetch.imageCached = function() return false end
-- Set by Assets: the path the worker must open (NX overlay mapping)
AtlasPrefetch.workerPath = function(resolved) return resolved end

-- drop a stored decode (its Image is uploaded and nothing else re-reads it)
function AtlasPrefetch.dropDecoded(path) dready[path] = nil end

-- Queue a PNG decode of an asset path (the store is keyed by what
-- Assets.resolve makes of it).  front: ahead of queued hints.  skipCached:
-- drop the request at send time when Assets already holds the Image.  Returns
-- true when a request is pending.
function AtlasPrefetch.requestDecode(path, front, skipCached)
  if not ensureWorker() then return false end
  local entry = dByKey[path]
  if entry then
    if front then
      for i, e in ipairs(dqLow) do
        if e == entry then table.remove(dqLow, i) table.insert(dqHigh, entry) break end
      end
    end
    return true
  end
  entry = { key = path, skipCached = skipCached }
  dByKey[path] = entry
  table.insert(front and dqHigh or dqLow, entry)
  return true
end

-- The decoded ImageData for a resolved path, or nil.  It STAYS in the store
-- (LRU) and is shared: a caller that mutates it must clone() first.
function AtlasPrefetch.peekDecoded(path)
  local r = dready[path]
  if not r then return nil end
  dreadySeq = dreadySeq + 1
  r.seq = dreadySeq
  return r.data
end

function AtlasPrefetch.decodedCount()
  local n = 0
  for _ in pairs(dready) do n = n + 1 end
  return n
end

function AtlasPrefetch.decodePending()
  local queued = 0
  for _ in pairs(dByKey) do queued = queued + 1 end
  return queued, dInflightCount
end

local function storeDecoded(key, data)
  dreadySeq = dreadySeq + 1
  dready[key] = { data = data, seq = dreadySeq }
  local n = 0
  for _ in pairs(dready) do n = n + 1 end
  while n > DEC_READY_CAP do
    local oldK, oldS
    for k, r in pairs(dready) do
      if not oldS or r.seq < oldS then oldK, oldS = k, r.seq end
    end
    dready[oldK] = nil
    n = n - 1
  end
end

local function store(key, data)
  readySeq = readySeq + 1
  ready[key] = { data = data, seq = readySeq }
  local n = 0
  for _ in pairs(ready) do n = n + 1 end
  while n > READY_CAP do
    local oldK, oldS
    for k, r in pairs(ready) do
      if not oldS or r.seq < oldS then oldK, oldS = k, r.seq end
    end
    ready[oldK] = nil
    n = n - 1
  end
end

local function pumpDecodes()
  local sent, examined = 0, 0
  while state and dInflightCount < DEC_INFLIGHT and sent < DEC_SEND_CAP
        and examined < DEC_EXAMINE_CAP do
    local entry = table.remove(dqHigh, 1) or table.remove(dqLow, 1)
    if not entry then return end
    examined = examined + 1
    dByKey[entry.key] = nil
    local ok, resolved = pcall(AtlasPrefetch.resolveDecodable, entry.key)
    if ok and resolved and not dready[resolved] and not dInflight[resolved]
       and not (entry.skipCached and AtlasPrefetch.imageCached(resolved)) then
      local okp, path = pcall(AtlasPrefetch.workerPath, resolved)
      if okp and path and pcall(cmdCh.push, cmdCh,
          { cmd = "decode", epoch = epoch, key = resolved, path = path }) then
        dInflight[resolved] = entry
        dInflightCount = dInflightCount + 1
        sent = sent + 1
      end
    end
  end
end

local function pump()
  pumpDecodes()
  local sent = 0
  while state and inflightCount < INFLIGHT and sent < SEND_CAP do
    local entry = table.remove(qHigh, 1) or table.remove(qLow, 1)
    if not entry then return end
    if not entry.dead then
      byKey[entry.key] = nil
      if not AtlasPrefetch.isFilled(entry.key) then
        local ok, payload = pcall(entry.make)
        if ok and payload then
          local pushed = pcall(cmdCh.push, cmdCh, {
            cmd = "bake", epoch = epoch, key = entry.key, src = payload.src,
            srcPath = payload.srcPath,
            perRow = payload.perRow, tileColors = payload.tileColors,
            aliases = payload.aliases,
          })
          if pushed then
            inflight[entry.key] = entry
            inflightCount = inflightCount + 1
            sent = sent + 1
          end
        end
      end
    end
  end
end

-- Per-frame drain (Game:update).  Moves finished ImageData into the ready
-- store; never touches the GPU.
function AtlasPrefetch.update()
  if not state then return end
  if worker then
    local err = worker:getError()
    if err then return failWorker(err) end
  end
  local got = 0
  while got < DRAIN_CAP do
    local result = outCh:pop()
    if not result then break end
    if result.fatal then return failWorker(result.fatal) end
    local key = result.key
    if result.decode then
      if dInflight[key] and result.epoch == epoch then
        dInflight[key] = nil
        dInflightCount = dInflightCount - 1
        if result.data then storeDecoded(key, result.data) end
      end
      goto continue
    end
    got = got + 1
    local entry = inflight[key]
    -- current only if it answers the request in flight under this epoch
    if entry and result.epoch == epoch then
      inflight[key] = nil
      inflightCount = inflightCount - 1
      if result.data and not AtlasPrefetch.isFilled(key) then
        store(key, result.data)
      end
    end
    ::continue::
  end
  pump()
end

-- nothing queued, nothing at the worker (always true without a thread)
function AtlasPrefetch.idle()
  if not state then return true end
  return inflightCount == 0 and next(byKey) == nil
     and dInflightCount == 0 and next(dByKey) == nil
end

function AtlasPrefetch.pending()
  local queued = 0
  for _ in pairs(byKey) do queued = queued + 1 end
  return queued, inflightCount
end

function AtlasPrefetch.readyCount()
  local n = 0
  for _ in pairs(ready) do n = n + 1 end
  return n
end

-- End the worker thread (LOVE waits for live threads at exit).  Safe to call
-- repeatedly; the next request starts a fresh worker.
function AtlasPrefetch.shutdown()
  if state and cmdCh then
    pcall(cmdCh.clear, cmdCh) -- do not make quit wait behind queued bakes
    pcall(cmdCh.push, cmdCh, { cmd = "quit" })
  end
  if worker then pcall(function() worker:wait() end) end
  worker, cmdCh, outCh = nil, nil, nil
  state = nil
  clearQueues()
  ready, sources, dready = {}, {}, {}
end

function AtlasPrefetch._setNoThreadEnvForTest(value) noThreadEnv = value end

function AtlasPrefetch._setDecodeLimitsForTest(inflightMax, sendCap, readyCap)
  DEC_INFLIGHT = inflightMax or 4
  DEC_SEND_CAP = sendCap or 4
  DEC_READY_CAP = readyCap or 64
end

function AtlasPrefetch._setLimitsForTest(inflightMax, drainCap, sendCap, readyCap)
  INFLIGHT = inflightMax or 2
  DRAIN_CAP = drainCap or 2
  SEND_CAP = sendCap or 1
  READY_CAP = readyCap or 24
end

require("src.core.SessionLifecycle").registerProcessShutdown(AtlasPrefetch.shutdown)

return AtlasPrefetch

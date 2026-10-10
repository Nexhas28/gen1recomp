-- Shared helpers for the perf_*_gen1 drivers (timing wrappers that can be
-- undone, TOUR/PHASE step printing).  Load with
--   local P = dofile("tests/drivers/perf_util.lua")
local P = {}

local now = love.timer.getTime
P.now = now

-- A set of monkeypatches that can all be undone.  patch:replace(tbl, name, fn)
-- swaps in fn(orig, ...) semantics via a wrapper factory; patch:timed(...)
-- adds elapsed ms to sink(label, ms).  patch:restore() puts every original
-- back (reverse order) and is safe to call twice.
function P.patches()
  local set = { list = {} }
  function set:replace(tbl, name, make)
    local orig = tbl[name]
    tbl[name] = make(orig)
    self.list[#self.list + 1] = function() tbl[name] = orig end
  end
  -- timing wrapper; returns up to 4 values like the originals needed
  function set:timed(tbl, name, label, sink)
    self:replace(tbl, name, function(f)
      return function(...)
        local t0 = now()
        local a, b, c, d = f(...)
        sink(label, (now() - t0) * 1000)
        return a, b, c, d
      end
    end)
  end
  function set:restore()
    for i = #self.list, 1, -1 do self.list[i]() end
    self.list = {}
  end
  return set
end

-- TOUR output (perf_tour_gen1): times fn(), prints the TOUR line, then lets
-- `settle` frames run.
function P.tour(name, ms)
  print(("TOUR %s call=%.2fms"):format(name, ms))
end

function P.step(U, name, fn, settle)
  local t0 = now()
  local ok, err = pcall(fn)
  P.tour(name, (now() - t0) * 1000)
  if not ok then print("TOUR " .. name .. " ERROR " .. tostring(err)) end
  U.wait(settle or 60)
end

-- PHASE output (perf_session_gen1); frameNo() supplies the frame counter.
function P.phase(name, fn, frameNo)
  print(("PHASE %s start frame=%d"):format(name, frameNo()))
  local ok, err = pcall(fn)
  if not ok then print("PHASE " .. name .. " ERROR " .. tostring(err)) end
  print(("PHASE %s end frame=%d"):format(name, frameNo()))
end

return P

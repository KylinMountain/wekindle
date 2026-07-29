local ForegroundTime = require("foreground_time")

local clock = 100
local values = {}
local flushes = 0
local settings = {
    get = function(_self, key, default)
        return values[key] == nil and default or values[key]
    end,
    set = function(_self, key, value) values[key] = value end,
    flush = function() flushes = flushes + 1 end,
}

local tracker = ForegroundTime:new{
    settings = settings,
    now = function() return clock end,
}
tracker:enter("book")
clock = 112.8
assert(tracker:checkpoint(10) == 12)
clock = 120.2
tracker:suspend()
clock = 200
assert(tracker:checkpoint(1) == 20, "suspended time must not accrue")
tracker:resume()
clock = 205
assert(tracker:checkpoint(1) == 25)
tracker:acknowledge(20)
assert(math.floor(tracker.pending_seconds) == 5)
clock = 1000
tracker:discard_unobserved_gap()
clock = 1003
assert(math.floor(tracker:checkpoint(1)) == 8,
    "unobserved suspend gap must be discarded")
tracker:close()
assert(values.standalone_pending_read_seconds.book >= 8)
assert(flushes >= 4)

local restored = ForegroundTime:new{
    settings = settings,
    now = function() return clock end,
}
restored:enter("book")
assert(math.floor(restored.pending_seconds) == 8)
clock = 1005
restored:enter("other")
assert(values.standalone_pending_read_seconds.book >= 10)

print("foreground time: 10 checks, 0 failures")

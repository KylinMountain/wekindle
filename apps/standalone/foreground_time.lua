-- Tracks reportable reading seconds from actual foreground intervals.
-- Pending time is persisted and only removed after the server acknowledges it.

local ForegroundTime = {}
ForegroundTime.__index = ForegroundTime

local PENDING_KEY = "standalone_pending_read_seconds"

function ForegroundTime:new(options)
    options = options or {}
    assert(type(options.settings) == "table",
        "foreground_time: settings required")
    assert(type(options.now) == "function",
        "foreground_time: monotonic clock required")
    return setmetatable({
        settings = options.settings,
        now = options.now,
        pending_key = options.pending_key or PENDING_KEY,
        book_id = nil,
        active = false,
        started_at = nil,
        pending_seconds = 0,
    }, self)
end

function ForegroundTime:_load(book_id)
    local values = self.settings:get(self.pending_key, {})
    local value = type(values) == "table" and values[tostring(book_id)] or 0
    return math.max(0, tonumber(value) or 0)
end

function ForegroundTime:_persist()
    if not self.book_id then return end
    local values = self.settings:get(self.pending_key, {})
    if type(values) ~= "table" then values = {} end
    values[tostring(self.book_id)] = self.pending_seconds
    self.settings:set(self.pending_key, values)
    self.settings:flush()
end

function ForegroundTime:_accrue()
    if not self.active or not self.started_at then return end
    local current = self.now()
    local elapsed = math.max(0, current - self.started_at)
    self.pending_seconds = self.pending_seconds + elapsed
    self.started_at = current
end

function ForegroundTime:enter(book_id)
    book_id = tostring(book_id or "")
    assert(book_id ~= "", "foreground_time: book id required")
    if self.book_id ~= book_id then
        if self.book_id then
            self:_accrue()
            self:_persist()
        end
        self.book_id = book_id
        self.pending_seconds = self:_load(book_id)
    end
    if not self.active then
        self.active = true
        self.started_at = self.now()
    end
end

function ForegroundTime:suspend()
    if self.active then
        self:_accrue()
        self.active = false
        self.started_at = nil
        self:_persist()
    end
end

function ForegroundTime:resume()
    if self.book_id and not self.active then
        self.active = true
        self.started_at = self.now()
    end
end

-- Called after a monotonic-clock jump when the process could not observe the
-- suspend transition (for example, Linux froze the process first). Pending
-- time already accumulated is retained, but the unobservable gap is excluded.
function ForegroundTime:discard_unobserved_gap()
    if self.active and self.book_id then
        self.started_at = self.now()
    end
end

function ForegroundTime:checkpoint(minimum_seconds)
    self:_accrue()
    self:_persist()
    local seconds = math.floor(self.pending_seconds)
    if seconds < (tonumber(minimum_seconds) or 0) then
        return nil
    end
    return seconds
end

function ForegroundTime:acknowledge(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    self:_accrue()
    self.pending_seconds = math.max(0, self.pending_seconds - seconds)
    self:_persist()
    return self.pending_seconds
end

function ForegroundTime:close()
    self:suspend()
end

return ForegroundTime

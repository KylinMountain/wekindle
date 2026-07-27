-- Unit tests for the standalone SQLite KV store.

local SqliteStore = require("sqlite_store")

local failures, checks = 0, 0

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
    end
end

local function ok(cond, label)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local PATH = "/tmp/weread-sqlite-spec.db"
os.remove(PATH)

-- 1. Round-trip of all value shapes; fresh tables per read.
do
    local store = SqliteStore:new{ path = PATH }
    store:saveSetting("s", "text")
    store:saveSetting("n", 42)
    store:saveSetting("b", true)
    store:saveSetting("t", { nested = { 1, 2, 3 }, flag = false })
    store:saveSetting("utf8", "微信读书")
    store:flush()
    eq(store:readSetting("s", ""), "text", "string")
    eq(store:readSetting("n", 0), 42, "number")
    eq(store:readSetting("b", false), true, "boolean")
    eq(store:readSetting("t", {}).nested[2], 2, "nested table")
    eq(store:readSetting("utf8", ""), "微信读书", "utf-8")
    local t = store:readSetting("t", {})
    t.nested[1] = 99
    eq(store:readSetting("t", {}).nested[1], 1, "fresh table per read")
    store:close()
end

-- 2. Durability across connections; delete; overwrite.
do
    local store = SqliteStore:new{ path = PATH }
    eq(store:readSetting("s", ""), "text", "durable across connections")
    store:saveSetting("s", "changed")
    store:delSetting("n")
    store:flush()
    store:close()
    local store2 = SqliteStore:new{ path = PATH }
    eq(store2:readSetting("s", ""), "changed", "overwrite durable")
    eq(store2:readSetting("n", "gone"), "gone", "delete durable")
    store2:close()
end

-- 3. Concurrent writers: busy_timeout absorbs a briefly-held write lock.
do
    -- Child holds a write transaction for ~1.5s, then commits.
    local child = io.open("/tmp/weread-sqlite-child.lua", "w")
    child:write([[
package.path = "./platform/standalone/?.lua;./third_party/?.lua;" .. package.path
local SqliteStore = require("sqlite_store")
local store = SqliteStore:new{ path = "/tmp/weread-sqlite-spec.db" }
store:saveSetting("child", "held")
os.execute("sleep 1.5")
store:flush()
store:close()
]])
    child:close()
    os.execute("luajit /tmp/weread-sqlite-child.lua &")
    os.execute("sleep 0.3")  -- let the child take the lock first
    local store = SqliteStore:new{ path = PATH }
    store:saveSetting("main", "waits")   -- must wait, then succeed (<=3s)
    store:flush()
    eq(store:readSetting("main", ""), "waits", "write survived short lock contention")
    store:close()
    os.execute("wait 2>/dev/null; sleep 1.5")
    local verify = SqliteStore:new{ path = PATH }
    eq(verify:readSetting("child", ""), "held", "child write also committed")
    verify:close()
    os.remove("/tmp/weread-sqlite-child.lua")
end

-- 4. journal_mode defaults to delete (vfat-safe).
do
    local store = SqliteStore:new{ path = PATH }
    -- read the pragma back via sqlite3 CLI-free check: no wal files should
    -- exist after writes
    store:saveSetting("jm", "x")
    store:flush()
    store:close()
    local wal = io.open(PATH .. "-wal", "rb")
    eq(wal, nil, "no WAL sidecar in delete mode")
end

os.remove(PATH)
print(string.format("sqlite_store_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end

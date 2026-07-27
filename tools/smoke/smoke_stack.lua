-- End-to-end smoke test: real libcurl + real SQLite + real weread-core
-- against the local stub server. No real WeRead account involved.
--
-- Usage: LUA_PATH=... luajit tools/smoke/smoke_stack.lua [port]

local port = arg[1] or os.getenv("WEREADER_SMOKE_PORT") or "8321"
local base = "http://127.0.0.1:" .. port

local Client = require("weread.lib.client")
local Settings = require("weread.lib.settings")
local SqliteStore = require("sqlite_store")
local CurlTransport = require("curl_transport")

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

local db_path = "/tmp/weread-smoke.db"
os.remove(db_path)

local store = SqliteStore:new{ path = db_path }
local settings = Settings:new{
    store = store,
    data_dir = "/tmp/weread-smoke-data",
    ensure_dir = function() end,
}
settings:update_auth{
    cookies = { wr_gid = "initial-gid-123", wr_vid = "424242" },
    api_key = "smoke-api-key",
}

local transport = CurlTransport:new{
    allow_insecure_http_for_testing = true,
    base_url_override = {
        { from = "https://weread.qq.com", to = base },
        { from = "https://i.weread.qq.com", to = base },
    },
}
local client = Client:new(settings, transport)

-- 1. Gateway call over real HTTP: bearer auth, signed envelope, JSON decode.
local info = client:get_book_info("smoke-book-1")
eq(info.title, "冒烟测试之书", "gateway /book/info round-trip")
eq(info.author, "测试作者", "utf-8 payload intact")

-- 2. Cookie renewal over real HTTP; new cookie persisted into SQLite.
client:renew_cookie()
eq(settings:get("cookies").wr_gid, "renewed-gid-123", "renewal cookie stored in settings")

local store2 = SqliteStore:new{ path = db_path }
local persisted = store2:readSetting("cookies", {})
eq(persisted.wr_gid, "renewed-gid-123", "cookie durable in SQLite (fresh connection)")
store2:close()

-- 3. Authenticated GET: stub requires the Cookie header, proving it was sent.
local progress = client:get_web_progress("smoke-book-1")
eq(progress.progress, 42, "cookie-authenticated request accepted by stub")

-- 4. Gateway without bearer is rejected (negative path over real HTTP).
local unauthorized = Client:new(Settings:new{
    store = SqliteStore:new{ path = "/tmp/weread-smoke-empty.db" },
    data_dir = "/tmp/weread-smoke-data2",
    ensure_dir = function() end,
}, transport)
local ok_no_key = pcall(function()
    -- bypass the api_key check by seeding an empty key then calling post_json
    return unauthorized:post_json(base .. "/api/agent/gateway", { api_name = "/x" })
end)
eq(ok_no_key, false, "stub rejects missing bearer")
os.remove("/tmp/weread-smoke-empty.db")

-- 5. Settings survive a full rebuild (durability across "restarts").
local settings2 = Settings:new{
    store = SqliteStore:new{ path = db_path },
    data_dir = "/tmp/weread-smoke-data",
    ensure_dir = function() end,
}
eq(settings2:get("api_key"), "smoke-api-key", "api_key durable")
eq(settings2:is_cookie_configured(), true, "login state durable")

os.remove(db_path)
print(string.format("smoke_stack: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end

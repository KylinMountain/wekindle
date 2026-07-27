-- Unit tests for weread-core settings repository over an in-memory KV store.

local Settings = require("weread.lib.settings")

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

local function mem_store(seed)
    local data = seed or {}
    return {
        flush_count = 0,
        readSetting = function(_self, key, default)
            local v = data[key]
            if v == nil then return default end
            return v
        end,
        saveSetting = function(_self, key, value) data[key] = value end,
        delSetting = function(_self, key) data[key] = nil end,
        flush = function(self) self.flush_count = self.flush_count + 1 end,
        _data = data,
    }
end

local function new_settings(store)
    return Settings:new{
        store = store,
        data_dir = "/tmp/weread-settings-test",
        ensure_dir = function() end,
    }
end

-- 1. Defaults resolve; nested defaults are deep-copied per read.
do
    local s = new_settings(mem_store())
    eq(s:get("api_key"), "", "api_key default empty")
    eq(s:get("sync").ask_on_conflict, true, "nested default")
    eq(s:get("cache").edge_tap_ratio, 0.20, "cache default")
    local sync = s:get("sync")
    sync.ask_on_conflict = false
    eq(s:get("sync").ask_on_conflict, true, "defaults not polluted by mutation")
    eq(s:get_download_dir(), "/tmp/weread-settings-test/cache", "default cache dir")
end

-- 2. update_auth merges cookies by default, replaces on demand.
do
    local store = mem_store{ auth_schema_version = Settings.AUTH_SCHEMA_VERSION }
    local s = new_settings(store)
    s:update_auth{ cookies = { wr_a = "1", wr_b = "2" } }
    s:update_auth{ cookies = { wr_b = "3" } }
    eq(s:get("cookies").wr_a, "1", "merge keeps old key")
    eq(s:get("cookies").wr_b, "3", "merge overwrites same key")
    s:update_auth({ cookies = { wr_c = "9" } }, { replace_cookies = true })
    eq(s:get("cookies").wr_a, nil, "replace drops old keys")
    eq(s:get("cookies").wr_c, "9", "replace stores new set")
    s:update_auth{ api_key = "k1", wr_ticket = "t1" }
    eq(s:get("api_key"), "k1", "api_key stored")
    eq(s:get("wr_ticket"), "t1", "wr_ticket stored")
    ok(store.flush_count > 0, "auth updates flushed")
end

-- 3. merge_set_cookie filters to weread cookie names only.
do
    local s = new_settings(mem_store{ auth_schema_version = Settings.AUTH_SCHEMA_VERSION })
    s:merge_set_cookie("wr_abc=token123; Path=/; HttpOnly, unrelated=no; Path=/")
    eq(s:get("cookies").wr_abc, "token123", "wr_ cookie captured")
    eq(s:get("cookies").unrelated, nil, "foreign cookie dropped")
end

-- 4. Legacy auth schema is invalidated: credentials cleared, version bumped.
do
    local store = mem_store{
        auth_schema_version = 0,
        api_key = "legacy-key",
        cookies = { wr_old = "x" },
        wr_ticket = "legacy-ticket",
        books = { b1 = { v = 1 } },
        curl_payload = "should-be-removed",
    }
    local s = new_settings(store)
    eq(s:get("api_key"), "", "legacy api_key cleared")
    eq(s:get("cookies").wr_old, nil, "legacy cookies cleared")
    eq(s:get("wr_ticket"), "", "legacy ticket cleared")
    eq(store._data.auth_schema_version, Settings.AUTH_SCHEMA_VERSION, "schema version bumped")
    eq(store._data.curl_payload, nil, "legacy key removed")
    ok(store._data.books.b1 ~= nil, "books survive auth invalidation")
end

-- 5. Download dir override and reset.
do
    local s = new_settings(mem_store{ auth_schema_version = Settings.AUTH_SCHEMA_VERSION })
    s:set_download_dir("/mnt/us/weread-books")
    eq(s:get_download_dir(), "/mnt/us/weread-books", "custom dir active")
    eq(s.store:readSetting("download_dir", ""), "/mnt/us/weread-books", "dir persisted")
    s:set_download_dir("")
    eq(s:get_download_dir(), "/tmp/weread-settings-test/cache", "reset to default")
end

-- 6. Login-state helpers.
do
    local s = new_settings(mem_store{ auth_schema_version = Settings.AUTH_SCHEMA_VERSION })
    eq(s:is_cookie_configured(), false, "no cookies yet")
    eq(s:is_api_configured(), false, "no api key yet")
    s:update_auth{ cookies = { wr_gid = "gid-12345" }, api_key = "k" }
    eq(s:is_cookie_configured(), true, "wr_gid counts as login cookie")
    eq(s:is_api_configured(), true, "api key configured")
    s:reset_account()
    eq(s:is_cookie_configured(), false, "reset clears cookies")
    eq(s:is_api_configured(), false, "reset clears api key")
end

print(string.format("settings_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end

-- Unit tests for weread-core client (IHttpClient port injection).
-- Covers cookie attachment/persistence, redirect credential scoping,
-- gateway auth, and cookie renewal — all without a real network.

local Client = require("weread.lib.client")
local MockTransport = require("mock_transport")

local failures, checks = 0, 0

local function ok(cond, label)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
    end
end

local function header(req, name)
    for key, value in pairs(req.headers or {}) do
        if key:lower() == name:lower() then
            return value
        end
    end
    return nil
end

local function fake_settings(initial)
    local values = initial or {}
    return {
        get = function(_self, key, default)
            local v = values[key]
            if v == nil then return default end
            return v
        end,
        set = function(_self, key, value) values[key] = value end,
        merge_set_cookie = function(_self, set_cookie)
            local Cookie = require("weread.lib.cookie")
            values.cookies = Cookie.merge_set_cookie(values.cookies or {}, set_cookie)
        end,
        update_auth = function(_self, updates, _opts)
            for k, v in pairs(updates) do
                values[k] = v
            end
        end,
        _values = values,
    }
end

-- 1. Cookie attached for weread URLs; skipped for skip_cookie / foreign URLs.
do
    local transport = MockTransport:new{
        { url_contains = "weread.qq.com", body = "{}" },
    }
    local settings = fake_settings{ cookies = { wr_skey = "abc", wr_vid = "42" } }
    local client = Client:new(settings, transport)

    client:request{ url = "https://weread.qq.com/web/book/info", method = "GET" }
    eq(header(transport:last_request(), "Cookie"), "wr_skey=abc; wr_vid=42", "cookie attached")

    client:request{ url = "https://weread.qq.com/web/book/info", method = "GET", skip_cookie = true }
    eq(header(transport:last_request(), "Cookie"), nil, "skip_cookie honored")

    local ok_foreign = pcall(function()
        client:request{ url = "https://example.com/x", method = "GET" }
    end)
    eq(ok_foreign, false, "no route for foreign host (and no cookie leak attempt)")
    eq(header(transport:last_request(), "Cookie"), nil, "no cookie for foreign URL")
end

-- 2. set-cookie persisted by default; suppressible.
do
    local transport = MockTransport:new{
        { url_contains = "weread.qq.com", body = "{}",
          headers = { ["set-cookie"] = "wr_skey=newvalue; Path=/; HttpOnly" } },
    }
    local settings = fake_settings{ cookies = { wr_skey = "old" } }
    local client = Client:new(settings, transport)

    client:request{ url = "https://weread.qq.com/web/x", method = "GET" }
    eq(settings._values.cookies.wr_skey, "newvalue", "set-cookie persisted")

    client:request{ url = "https://weread.qq.com/web/x", method = "GET",
                    persist_response_cookies = false }
    eq(settings._values.cookies.wr_skey, "newvalue", "persist skipped when opted out")
end

-- 3. Cross-origin redirect clears credentials; 302 POST becomes GET.
do
    local transport = MockTransport:new{
        { url_contains = "weread.qq.com/start", code = 302,
          headers = { location = "https://cdn.example.com/file" } },
        { url_contains = "cdn.example.com", body = "payload" },
    }
    local settings = fake_settings{ cookies = { wr_skey = "abc" } }
    local client = Client:new(settings, transport)

    local text = client:request_follow{
        url = "https://weread.qq.com/start",
        method = "POST",
        body = "x=1",
        headers = { Authorization = "Bearer k", Origin = "https://weread.qq.com" },
    }
    eq(text, "payload", "redirect followed")
    local final = transport:last_request()
    eq(final.method, "GET", "302 POST downgraded to GET")
    eq(header(final, "Authorization"), nil, "Authorization cleared cross-origin")
    eq(header(final, "Origin"), nil, "Origin cleared cross-origin")
    eq(header(final, "Cookie"), nil, "Cookie cleared cross-origin")
end

-- 4. Gateway sends Bearer auth and api_name/skill_version envelope.
do
    local transport = MockTransport:new{
        { url_contains = "i.weread.qq.com", body = '{"data": 1}' },
    }
    local settings = fake_settings{ api_key = "wrk-test" }
    local client = Client:new(settings, transport)

    local result = client:gateway("/book/info", { bookId = "b1" })
    eq(result.data, 1, "gateway decoded")
    local req = transport:last_request()
    eq(header(req, "Authorization"), "Bearer wrk-test", "bearer header")
    local payload = client:json_decode(req.body)
    eq(payload.api_name, "/book/info", "api_name in payload")
    ok(payload.skill_version ~= nil, "skill_version in payload")
    eq(payload.bookId, "b1", "params at top level")
end

-- 5. Renewal persists cookies only on succ=1.
do
    local transport = MockTransport:new{
        { url_contains = "renewal", body = '{"succ": 1}',
          headers = { ["set-cookie"] = "wr_skey=renewed; Path=/",
                      ["x-wr-ticket"] = "ticket1" } },
    }
    local settings = fake_settings{ cookies = { wr_skey = "old" } }
    local client = Client:new(settings, transport)

    client:renew_cookie()
    eq(settings._values.cookies.wr_skey, "renewed", "renewal cookie stored")
    eq(settings._values.wr_ticket, "ticket1", "wr_ticket stored")

    local failing = MockTransport:new{
        { url_contains = "renewal", body = '{"succ": 0}',
          headers = { ["set-cookie"] = "wr_skey=poison; Path=/" } },
    }
    local client2 = Client:new(settings, failing)
    local ok_fail = pcall(function() client2:renew_cookie() end)
    eq(ok_fail, false, "failed renewal raises")
    eq(settings._values.cookies.wr_skey, "renewed", "failed renewal leaves credentials intact")
end

print(string.format("client_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end

-- Unit tests for the KOReader SocketTransport adapter, with LuaSocket
-- stubbed via package.preload so the real adapter code runs in pure Lua.
-- Guards the pcall(http.request) return-unpacking contract:
-- LuaSocket with a sink returns 1, code, headers, status on success.

local captured_request
local socket_behavior = { mode = "success" }

package.preload["socket.http"] = function()
    return {
        request = function(req)
            captured_request = req
            if socket_behavior.mode == "success" then
                -- drain the sink like LuaSocket does
                req.sink("response-body")
                return 1, 200, { ["set-cookie"] = "a=b", ["content-type"] = "application/json" },
                    "HTTP/1.1 200 OK"
            elseif socket_behavior.mode == "fail_nil" then
                return nil, socket_behavior.err or "connection refused"
            elseif socket_behavior.mode == "raise" then
                error("socket exploded")
            end
        end,
    }
end

package.preload["socketutil"] = function()
    return {
        set_timeout = function(_self, _block, _total) end,
        reset_timeout = function(_self) end,
        table_sink = function(t)
            return function(chunk)
                if chunk then
                    t[#t + 1] = chunk
                end
                return 1
            end
        end,
    }
end

package.preload["ltn12"] = function()
    return {
        source = {
            string = function(s)
                return function()
                    local v = s
                    s = nil
                    return v
                end
            end,
        },
    }
end

local SocketTransport = require("weread.adapter.socket_transport")

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

local transport = SocketTransport:new()

-- 1. Success: code/headers/status unpack at the right positions.
socket_behavior.mode = "success"
local body, code, headers, status = transport:roundtrip{
    url = "https://weread.qq.com/web/x",
    method = "GET",
    headers = {},
}
eq(body, "response-body", "body drained from sink")
eq(code, 200, "code is the HTTP status, not the LuaSocket 1")
eq(headers["content-type"], "application/json", "headers table intact")
eq(status, "HTTP/1.1 200 OK", "status line passthrough")
eq(captured_request.redirect, false, "redirects disabled at socket level")

-- 2. POST with body: Content-Length computed; caller variant not duplicated.
transport:roundtrip{
    url = "https://weread.qq.com/web/y",
    method = "POST",
    headers = { ["content-length"] = "999", ["Content-Type"] = "application/json" },
    body = "abcd",
}
eq(captured_request.method, "POST", "method passthrough")
eq(captured_request.headers["content-length"], "999", "caller content-length respected")
eq(captured_request.headers["Content-Length"], nil, "no duplicate Content-Length added")

transport:roundtrip{
    url = "https://weread.qq.com/web/z",
    method = "POST",
    headers = {},
    body = "abcd",
}
eq(captured_request.headers["Content-Length"], "4", "Content-Length computed from body")

-- 3. Transport failure (nil, err): err string reachable via status.
socket_behavior.mode = "fail_nil"
socket_behavior.err = "timeout"
local fbody, fcode, _fheaders, fstatus = transport:roundtrip{
    url = "https://weread.qq.com/web/x",
    method = "GET",
}
eq(fbody, "", "failure body empty")
eq(fcode, nil, "failure code nil")
eq(fstatus, "timeout", "err string surfaces as status (timeout detection path)")

-- 4. Hard raise propagates as Lua error.
socket_behavior.mode = "raise"
local ok_raise = pcall(function()
    transport:roundtrip{ url = "https://weread.qq.com/web/x", method = "GET" }
end)
eq(ok_raise, false, "socket raise propagates")

socket_behavior.mode = "success"
print(string.format("socket_transport_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end

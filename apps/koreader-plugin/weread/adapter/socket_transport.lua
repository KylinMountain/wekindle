-- KOReader IHttpClient adapter: single HTTP round trip over LuaSocket.
--
-- Implements the transport port consumed by weread-core's weread.lib.client:
--   transport:roundtrip{ method, url, headers, body, timeout }
--     -> body_string, code, resp_headers, status
--   transport.sleep(seconds)   -- optional cooperative sleep
--
-- Redirects are NOT followed here; weread.lib.client handles them explicitly
-- so credentials are rebuilt per destination (see core/contracts/ports.md).

local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local http = require("socket.http")
local http_request = http.request

local DEFAULT_TIMEOUT_SECONDS = 15

local SocketTransport = {}
SocketTransport.__index = SocketTransport

function SocketTransport:new()
    return setmetatable({}, self)
end

function SocketTransport:roundtrip(req)
    local body = req.body
    local headers = {}
    local has_content_length = false
    for key, value in pairs(req.headers or {}) do
        if tostring(key):lower() == "content-length" then
            has_content_length = true
        end
        headers[key] = value
    end
    if body and not has_content_length then
        headers["Content-Length"] = tostring(#body)
    end

    local block_timeout = DEFAULT_TIMEOUT_SECONDS
    local total_timeout = -1
    local timeout = req.timeout
    if type(timeout) == "table" and timeout[1] then
        block_timeout = timeout[1]
        total_timeout = timeout[2] or block_timeout
    elseif type(timeout) == "number" then
        block_timeout = timeout
    end
    socketutil:set_timeout(block_timeout, total_timeout)

    local response = {}
    local req_opts = {
        url = req.url,
        method = req.method or (body and "POST" or "GET"),
        source = body and ltn12.source.string(body) or nil,
        sink = socketutil.table_sink(response),
        headers = headers,
        redirect = false,
    }

    local results = { pcall(http_request, req_opts) }
    socketutil:reset_timeout()
    if not results[1] then
        error(results[2])
    end
    -- LuaSocket with a sink returns 1, code, headers, status on success:
    -- results[2] is the literal 1 and must be discarded.
    local _, raw_code, resp_headers, status = results[2], results[3], results[4], results[5]
    if status == nil and type(raw_code) == "string" then
        status = raw_code
    end

    return table.concat(response), tonumber(raw_code), resp_headers or {}, status
end

function SocketTransport.sleep(seconds)
    local socket_ok, socket = pcall(require, "socket")
    if socket_ok and socket.sleep then
        socket.sleep(seconds)
    end
end

return SocketTransport

-- Mock IHttpClient transport for weread-core tests.
--
-- Routes are matched in order against { method, url_contains }; the first
-- match wins. Every request is recorded for assertions.

local MockTransport = {}
MockTransport.__index = MockTransport

function MockTransport:new(routes)
    local self = setmetatable({
        routes = routes or {},
        requests = {},
        sleeps = {},
    }, MockTransport)
    -- bound per-instance so client code can call it as a plain function
    self.sleep = function(seconds)
        self.sleeps[#self.sleeps + 1] = seconds
    end
    return self
end

function MockTransport:roundtrip(req)
    self.requests[#self.requests + 1] = req
    for _, route in ipairs(self.routes) do
        local method_ok = not route.method or route.method == (req.method or "GET")
        local url_ok = not route.url_contains
            or (req.url and req.url:find(route.url_contains, 1, true) ~= nil)
        if method_ok and url_ok then
            return route.body or "", route.code or 200, route.headers or {}, route.status
        end
    end
    error("MockTransport: no route for " .. tostring(req.method) .. " " .. tostring(req.url))
end

function MockTransport:last_request()
    return self.requests[#self.requests]
end

return MockTransport

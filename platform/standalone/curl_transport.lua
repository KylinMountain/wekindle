-- Standalone IHttpClient adapter: single HTTP round trip over libcurl,
-- via LuaJIT FFI. Implements the transport port consumed by
-- weread.lib.client (see core/contracts/ports.md):
--
--   transport:roundtrip{ method, url, headers, body, timeout }
--     -> body_string, code, resp_headers, status
--
-- Redirects are NOT followed here (core client handles them explicitly so
-- credentials are rebuilt per destination). HTTPS is enforced unless the
-- instance was created with allow_insecure_http_for_testing = true, which
-- exists solely for the local stub-server smoke test.

local ffi = require("ffi")

ffi.cdef[[
typedef void CURL;
typedef struct curl_slist {
    char *data;
    struct curl_slist *next;
} curl_slist;

void curl_global_init(long flags);
CURL *curl_easy_init(void);
void curl_easy_cleanup(CURL *curl);
int curl_easy_perform(CURL *curl);
const char *curl_easy_strerror(int code);
struct curl_slist *curl_slist_append(struct curl_slist *list, const char *data);
void curl_slist_free_all(struct curl_slist *list);

/* curl_easy_setopt / curl_easy_getinfo are variadic. Declare them as such:
   the FFI then emits calls with the correct variadic ABI (fixed-arity
   aliases via asm() break on Darwin arm64, where variadic args go on the
   stack but a fixed-arity call would pass them in registers). */
int curl_easy_setopt(CURL *curl, int option, ...);
int curl_easy_getinfo(CURL *curl, int info, ...);

unsigned int usleep(unsigned int usec);
]]

-- Load OUR libcurl: on Kindle the rootfs ships a broken /usr/lib/libcurl.so
-- that gets picked up by ffi.load("curl") (its easy_cleanup segfaults), so
-- the explicit path wins when provided.
local curl_path = os.getenv("CURL_TRANSPORT_PATH") or "curl"
local C = ffi.load(curl_path)

-- CURLOPT constants (CURLOPTTYPE_LONG = 0, OBJECTPOINT = 10000,
-- FUNCTIONPOINT = 20000). CURLINFO_RESPONSE_CODE = CURLINFO_LONG + 2.
local CURLOPT = {
    WRITEDATA = 10001,
    URL = 10002,
    WRITEFUNCTION = 20011,
    HTTPHEADER = 10023,
    CUSTOMREQUEST = 10036,
    FOLLOWLOCATION = 52,
    POSTFIELDSIZE = 60,
    SSL_VERIFYPEER = 64,
    SSL_VERIFYHOST = 81,
    NOSIGNAL = 99,
    POSTFIELDS = 10015,
    HEADERDATA = 10029,  -- a.k.a. WRITEHEADER
    TIMEOUT_MS = 155,
    CONNECTTIMEOUT_MS = 156,
    HEADERFUNCTION = 20079,
}
local CURLINFO_RESPONSE_CODE = 0x200002

C.curl_global_init(3)  -- CURL_GLOBAL_ALL: without SSL init, easy_cleanup dereferences NULL TLS state and segfaults

-- Pending request collectors, keyed by an integer handle id. The write and
-- header callbacks cannot carry Lua upvalues across the C boundary portably,
-- so they look up their collector here. Entries are removed after each
-- request; requests on one transport are serialized by the caller.
local pending_bodies = {}
local pending_headers = {}
local next_handle_id = 0

local write_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
    function(ptr, size, nmemb, userdata)
        local id = tonumber(ffi.cast("intptr_t", userdata))
        local buf = pending_bodies[id]
        if buf then
            buf[#buf + 1] = ffi.string(ptr, size * nmemb)
        end
        return size * nmemb
    end)

local header_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
    function(ptr, size, nmemb, userdata)
        local id = tonumber(ffi.cast("intptr_t", userdata))
        local headers = pending_headers[id]
        if headers then
            local line = ffi.string(ptr, size * nmemb)
            local name, value = line:match("^([%w%-]+)%s*:%s*(.-)%s*$")
            if name then
                local key = name:lower()
                local existing = headers[key]
                if existing == nil then
                    headers[key] = value
                elseif type(existing) == "table" then
                    existing[#existing + 1] = value
                else
                    headers[key] = { existing, value }
                end
            end
        end
        return size * nmemb
    end)

local CurlTransport = {}
CurlTransport.__index = CurlTransport

-- opts.allow_insecure_http_for_testing: permits http:// URLs, solely for the
-- local stub-server smoke test. Never set this in production paths.
-- opts.base_url_override: list of { from = "https://weread.qq.com",
--                                   to = "http://127.0.0.1:8321" } (testing only)
function CurlTransport:new(opts)
    opts = opts or {}
    return setmetatable({
        allow_insecure_http_for_testing = opts.allow_insecure_http_for_testing == true,
        base_url_override = opts.base_url_override,
    }, self)
end

function CurlTransport:_rewrite_url(url)
    if type(url) ~= "string" then
        return url
    end
    for _i, o in ipairs(self.base_url_override or {}) do
        if url:sub(1, #o.from) == o.from then
            return o.to .. url:sub(#o.from + 1)
        end
    end
    return url
end

function CurlTransport:roundtrip(req)
    local url = self:_rewrite_url(req.url)
    if url:match("^http://") and not self.allow_insecure_http_for_testing then
        error("curl_transport: plain HTTP is not allowed")
    end

    local curl = C.curl_easy_init()
    if curl == nil then
        error("curl_easy_init failed")
    end

    next_handle_id = next_handle_id + 1
    local id = next_handle_id
    local body_chunks = {}
    local resp_headers = {}
    pending_bodies[id] = body_chunks
    pending_headers[id] = resp_headers
    local id_ptr = ffi.cast("void*", ffi.cast("intptr_t", id))

    local slist = nil
    local ok, err = pcall(function()
        C.curl_easy_setopt(curl, CURLOPT.URL, url)
        C.curl_easy_setopt(curl, CURLOPT.WRITEFUNCTION, ffi.cast("void*", write_cb))
        C.curl_easy_setopt(curl, CURLOPT.HEADERFUNCTION, ffi.cast("void*", header_cb))
        C.curl_easy_setopt(curl, CURLOPT.WRITEDATA, id_ptr)
        C.curl_easy_setopt(curl, CURLOPT.HEADERDATA, id_ptr)
        C.curl_easy_setopt(curl, CURLOPT.FOLLOWLOCATION, ffi.cast("long", 0))
        C.curl_easy_setopt(curl, CURLOPT.SSL_VERIFYPEER, ffi.cast("long", 1))
        C.curl_easy_setopt(curl, CURLOPT.SSL_VERIFYHOST, ffi.cast("long", 2))
        local ca_bundle = os.getenv("CURL_CA_BUNDLE")
        if ca_bundle and ca_bundle ~= "" then
            C.curl_easy_setopt(curl, 10065 --[[CURLOPT_CAINFO]], ca_bundle)
        end
        C.curl_easy_setopt(curl, CURLOPT.NOSIGNAL, ffi.cast("long", 1))

        local timeout = req.timeout
        local connect_ms, total_ms = 15000, 0
        if type(timeout) == "table" then
            connect_ms = math.floor((timeout[1] or 15) * 1000)
            total_ms = math.floor((timeout[2] or 0) * 1000)
        elseif type(timeout) == "number" then
            connect_ms = math.floor(timeout * 1000)
        end
        C.curl_easy_setopt(curl, CURLOPT.CONNECTTIMEOUT_MS, ffi.cast("long", connect_ms))
        if total_ms > 0 then
            C.curl_easy_setopt(curl, CURLOPT.TIMEOUT_MS, ffi.cast("long", total_ms))
        end

        local method = req.method or "GET"
        if method ~= "GET" then
            C.curl_easy_setopt(curl, CURLOPT.CUSTOMREQUEST, method)
        end
        if req.body then
            C.curl_easy_setopt(curl, CURLOPT.POSTFIELDS, req.body)
            C.curl_easy_setopt(curl, CURLOPT.POSTFIELDSIZE, ffi.cast("long", #req.body))
        end

        for key, value in pairs(req.headers or {}) do
            slist = C.curl_slist_append(slist, tostring(key) .. ": " .. tostring(value))
        end
        if slist ~= nil then
            C.curl_easy_setopt(curl, CURLOPT.HTTPHEADER, slist)
        end

        io.stderr:write("[ct] performing... ", tostring(req.method or "GET"), " ", url, "\n")
        local rc = C.curl_easy_perform(curl)
        io.stderr:write("[ct] performed rc=", tostring(rc), "\n")
        if rc ~= 0 then
            error(ffi.string(C.curl_easy_strerror(rc)))
        end
    end)

    local code = 0
    if ok then
        io.stderr:write("[ct] getinfo...\n")
        local out = ffi.new("long[1]")
        C.curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, out)
        code = tonumber(out[0])
        io.stderr:write("[ct] code=", tostring(code), "\n")
    end

    if slist ~= nil then
        io.stderr:write("[ct] free slist\n")
        C.curl_slist_free_all(slist)
    end
    io.stderr:write("[ct] cleanup h=", tostring(curl), "\n")
    C.curl_easy_cleanup(curl)
    io.stderr:write("[ct] done\n")
    pending_bodies[id] = nil
    pending_headers[id] = nil

    if not ok then
        error(err)
    end

    return table.concat(body_chunks), code, resp_headers, "HTTP " .. tostring(code)
end

function CurlTransport.sleep(seconds)
    ffi.C.usleep(math.floor(seconds * 1000000))
end

return CurlTransport

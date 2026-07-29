-- Standalone bootstrap: wires weread-core to standalone adapters
-- (libcurl transport, SQLite settings store, pure-Lua ZIP writer,
-- console UI ports). Shared by cli.lua and, later, the LVGL app.

local Client = require("weread.lib.client")
local Settings = require("weread.lib.settings")
local Downloader = require("weread.lib.downloader")
local Content = require("weread.lib.content")
local SqliteStore = require("sqlite_store")
local SecretStore = require("secret_store")
local CurlTransport = require("curl_transport")
local ZipWriter = require("zip_writer")

local M = {}

local function default_data_dir()
    if os.getenv("WEREADER_PLATFORM") == "kindle" then
        return os.getenv("WEREADER_DATA_DIR")
            or "/mnt/us/extensions/wereader/data"
    end
    local home = os.getenv("HOME") or "."
    return home .. "/.wereader"
end

-- Monotonic clock via FFI (os.clock() measures CPU time, which stalls
-- during blocking I/O and would corrupt download perf telemetry).
local ffi = require("ffi")
ffi.cdef("unsigned int usleep(unsigned int usec);")
local now_ms
if ffi.os == "OSX" then
    ffi.cdef[[
uint64_t mach_absolute_time(void);
typedef struct { uint32_t numer; uint32_t denom; } mach_timebase_info_data_t;
int mach_timebase_info(mach_timebase_info_data_t *info);
]]
    local info = ffi.new("mach_timebase_info_data_t[1]")
    ffi.C.mach_timebase_info(info)
    local numer, denom = tonumber(info[0].numer), tonumber(info[0].denom)
    now_ms = function()
        return tonumber(ffi.C.mach_absolute_time()) * numer / denom / 1e6
    end
else
    ffi.cdef[[
typedef long time_t;
typedef struct { time_t tv_sec; long tv_nsec; } timespec;
int clock_gettime(int clk_id, timespec *tp);
]]
    local CLOCK_MONOTONIC = 1
    local tp = ffi.new("timespec[1]")
    now_ms = function()
        ffi.C.clock_gettime(CLOCK_MONOTONIC, tp)
        return tonumber(tp[0].tv_sec) * 1000 + tonumber(tp[0].tv_nsec) / 1e6
    end
end

-- FIFO trampoline for the downloader scheduler: schedule() never runs the
-- step inline (deep chapter counts would overflow the Lua stack via
-- recursive _step -> schedule chains), and delays are honored by sleeping
-- before the queued step runs.
local function make_scheduler()
    local queue = {}
    local scheduler = function(delay, fn)
        queue[#queue + 1] = { delay = delay or 0, fn = fn }
    end
    local function drain()
        while #queue > 0 do
            local item = table.remove(queue, 1)
            if item.delay > 0 then
                ffi.C.usleep(math.floor(item.delay * 1000000))
            end
            item.fn()
        end
    end
    return scheduler, drain
end

-- Console implementations of the downloader UI ports.
local console = {}

function console.dialog()
    return {
        show = function() end,
        close = function() end,
        setTitle = function(_self, text) io.stdout:write("\27[K" .. text .. "\r") end,
        reportProgress = function() end,
    }
end

-- opts.data_dir    -- defaults to ~/.wereader
-- opts.verbose     -- print stage lines during downloads
function M.init(opts)
    opts = opts or {}
    local data_dir = opts.data_dir or default_data_dir()
    os.execute("mkdir -p " .. string.format("%q", data_dir))
    local device = opts.device
    if not device and os.getenv("WEREADER_PLATFORM") == "kindle" then
        device = require("kindle.device"):new{
            userstore = "/mnt/us",
        }
    end

    Content.set_zip_writer_factory(function()
        return ZipWriter:new()
    end)

    local store = SqliteStore:new{
        path = data_dir .. "/wereader.db",
        -- Kindle user storage is vfat; WAL is intentionally forbidden there.
        journal_mode = "delete",
    }
    local is_kindle = os.getenv("WEREADER_PLATFORM") == "kindle"
    local secret_dir
    if is_kindle then
        secret_dir = os.getenv("WEREADER_SECRET_DIR")
            or "/var/local/wereader/secrets"
    else
        secret_dir = data_dir .. "/secrets"
    end
    local secret_store = SecretStore:new{
        dir = secret_dir,
        key_material = opts.secret_key_material,
        device_key_path = is_kindle and "/proc/usid" or nil,
        require_device_key = is_kindle,
        forbid_userstore = is_kindle,
    }
    local settings = Settings:new{
        store = store,
        data_dir = data_dir,
        secret_store = secret_store,
    }

    local transport = CurlTransport:new()
    local client = Client:new(settings, transport)

    local schedule, drain = make_scheduler()

    local downloader = Downloader:new{
        client = client,
        settings = settings,
        schedule = schedule,
        prevent_standby = function(reason)
            if device then
                return device:prevent_suspend(reason)
            end
        end,
        allow_standby = function(reason)
            if device then
                return device:allow_suspend(reason)
            end
        end,
        now_ms = now_ms,
        show_info = function(text) print(text) end,
        show_transient = function(text) print(text) end,
        refresh_ui = function() end,
        refresh_shelf = function() end,
        open_file = function(path) print("open: " .. tostring(path)) end,
        safe_callback = function(_label, fn) return fn end,
        require_login = function()
            return settings:is_cookie_configured()
        end,
        run_online_task = function(_label, fn)
            fn()
            return true
        end,
        new_progress_dialog = function() return console.dialog() end,
        show_confirm = function(o) print(o.text) end,
    }

    local app = {
        data_dir = data_dir,
        settings = settings,
        client = client,
        transport = transport,
        downloader = downloader,
        device = device,
        now_ms = now_ms,
        drain_tasks = drain,
    }
    function app:close()
        if self._closed then
            return
        end
        self._closed = true
        if self.device then
            self.device:release_all_suspend_guards()
        end
        store:close()
    end
    return app
end

return M

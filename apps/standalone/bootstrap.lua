-- Standalone bootstrap: wires weread-core to the desktop adapters
-- (libcurl transport, SQLite settings store, pure-Lua ZIP writer,
-- console UI ports). Shared by cli.lua and, later, the LVGL app.

local Client = require("weread.lib.client")
local Settings = require("weread.lib.settings")
local Downloader = require("weread.lib.downloader")
local Content = require("weread.lib.content")
local SqliteStore = require("sqlite_store")
local CurlTransport = require("curl_transport")
local ZipWriter = require("zip_writer")

local M = {}

local function default_data_dir()
    local home = os.getenv("HOME") or "."
    return home .. "/.wereader"
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

    Content.set_zip_writer_factory(function()
        return ZipWriter:new()
    end)

    local settings = Settings:new{
        store = SqliteStore:new{ path = data_dir .. "/wereader.db" },
        data_dir = data_dir,
    }

    local transport = CurlTransport:new()
    local client = Client:new(settings, transport)

    local downloader = Downloader:new{
        client = client,
        settings = settings,
        schedule = function(_delay, fn) fn() end,
        prevent_standby = function() end,
        allow_standby = function() end,
        now_ms = function() return os.clock() * 1000 end,
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

    return {
        data_dir = data_dir,
        settings = settings,
        client = client,
        downloader = downloader,
    }
end

return M

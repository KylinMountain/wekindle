-- KOReader host adapter for weread-core's download engine.
--
-- Binds the platform ports (IScheduler / IDevice / progress dialog / confirm
-- dialog / translation) to KOReader facilities and returns a fully-wired
-- weread.lib.downloader instance.

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")

local DownloadDialog = require("weread.ui.download_dialog")
local PluginUtil = require("weread.lib.plugin_util")
local Downloader = require("weread.lib.downloader")

-- Wall clock for perf logging. KOReader's ui/time TimeValue is monotonic,
-- but the perf numbers are diagnostic-only, so socket.gettime is fine.
local ok_socket, socket = pcall(require, "socket")

local function now_ms()
    if ok_socket and socket.gettime then
        return socket.gettime() * 1000
    end
    return os.clock() * 1000
end

-- Block OS-level standby (Kindle powerd, Kobo lid/menu-suspend, etc.)
local function preventOsStandby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = true
    end
end

local function allowOsStandby()
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    if Device:isCervantes() or Device:isKobo() then
        PluginShare.pause_auto_suspend = false
    end
end

local M = {}

-- o carries the plugin-level callbacks (client, settings, show_info,
-- show_transient, refresh_ui, refresh_shelf, open_file, safe_callback,
-- require_login, run_online_task). Platform ports are bound here and can be
-- overridden in tests by passing them explicitly.
function M.new(o)
    o = o or {}
    if o.schedule == nil then
        o.schedule = function(delay, fn)
            -- KOReader deadlocks on scheduleIn(0); clamp to 0.1s minimum.
            UIManager:scheduleIn(math.max(delay or 0.1, 0.1), fn)
        end
    end
    if o.prevent_standby == nil then
        o.prevent_standby = function(_reason)
            UIManager:preventStandby()
            preventOsStandby()
        end
    end
    if o.allow_standby == nil then
        o.allow_standby = function(_reason)
            UIManager:allowStandby()
            allowOsStandby()
        end
    end
    o.now_ms = o.now_ms or now_ms
    if o.new_progress_dialog == nil then
        o.new_progress_dialog = function(opts)
            return DownloadDialog:new(opts)
        end
    end
    if o.show_confirm == nil then
        o.show_confirm = function(opts)
            UIManager:show(ConfirmBox:new(opts))
        end
    end
    o.tr = o.tr or PluginUtil.tr
    return Downloader:new(o)
end

return M

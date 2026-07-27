-- Focused tests for automatic opening after a progress-target chapter download.
-- Run from the repo root with:
--   lua spec/downloader_completion_spec.lua

package.path = "./?.lua;" .. package.path

local shown = {}
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        preventStandby = function() end,
        allowStandby = function() end,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.content"] = function()
    return {
        save_chapter_epub = function()
            return "/cache/book/chapter-22.epub"
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
    }
end

local Downloader = require("weread.lib.downloader")

local failures, checks = 0, 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

local stored_books
local opened
local completion_count = 0
local completion_ok
local completion_path
local settings = {
    get = function(_self, key)
        return key == "books" and {} or nil
    end,
    set = function(_self, key, value)
        if key == "books" then stored_books = value end
    end,
    flush = function() end,
}
local downloader = Downloader:new{
    settings = settings,
    client = {},
    refresh_shelf = function() end,
    open_file = function(path) opened = path end,
    show_info = function() end,
}
local chapter = { chapterUid = 22, title = "Target" }
local download = {
    book = { book_id = "book", title = "Book" },
    chapters = { chapter },
    selected = { chapter },
    bodies = { ["22"] = "<p>body</p>" },
    assets = {},
    state = { css = "" },
    suffix = "chapter",
    index = 2,
    total = 1,
    failed = {},
    annotation_failed_batches = 0,
    single_chapter = true,
    open_on_complete = true,
    started_at = 999,
    on_complete = function(ok, path)
        completion_count = completion_count + 1
        completion_ok = ok
        completion_path = path
    end,
}

downloader:_step(download)

eq(completion_count, 1, "completion callback count")
eq(completion_ok, true, "completion success")
eq(completion_path, "/cache/book/chapter-22.epub", "completion path")
eq(opened, "/cache/book/chapter-22.epub", "automatically opened path")
eq(#shown, 0, "no redundant read-now dialog")
eq(stored_books.book.cached_chapters["22"],
    "/cache/book/chapter-22.epub", "target chapter persisted")

print(string.format(
    "downloader_completion_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)

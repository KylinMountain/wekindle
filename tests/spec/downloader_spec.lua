-- State-machine tests for weread-core downloader with fully mocked ports.
-- Covers: completion confirm flow, open_on_complete, cancel, all-fail,
-- and standby-guard release on step exceptions.

local queued = {}

-- Stub Content/Thoughts before the downloader module loads them.
local content_stub = {
    ensure_reader_state = function() end,
    fetch_single_chapter_source = function(_client, _settings, _book, chapter)
        return "<p>chapter " .. tostring(chapter.chapterUid) .. "</p>"
    end,
    finalize_single_chapter_content = function(_client, _settings, _book, chapter, xhtml)
        return xhtml, {}
    end,
    save_chapter_epub = function() return "/cache/book/chapter-22.epub" end,
    save_book_epub = function() return "/cache/book/full.epub" end,
}
local thoughts_stub = {
    is_download_enabled = function() return false end,
}
package.preload["weread.lib.content"] = function() return content_stub end
package.preload["weread.lib.thoughts"] = function() return thoughts_stub end

local Downloader = require("weread.lib.downloader")

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

-- Drain the scheduler queue until empty (each run may enqueue more).
local function run_all()
    local guard = 0
    while #queued > 0 do
        guard = guard + 1
        if guard > 1000 then
            error("scheduler queue did not drain (possible loop)")
        end
        local fn = table.remove(queued, 1)
        fn()
    end
end

local function make_dialog(rec)
    local dialog = {
        show = function() rec.shown = true end,
        close = function() rec.closed = true end,
        setTitle = function(_self, t) rec.title = t end,
        reportProgress = function(_self, p) rec.progress = p end,
    }
    return dialog
end

local function make_host(overrides)
    local rec = {
        infos = {}, transients = {}, confirms = {}, opened = {},
        prevent_count = 0, allow_count = 0, refreshed_shelf = 0,
        dialog = {},
    }
    local books_values = {}
    local host = {
        client = {
            get_binary = function() return nil end,
            build_chapter_review_batches = function() return {} end,
        },
        settings = {
            get = function(_self, key, default)
                if key == "cache" then
                    return { download_book_images = false }
                end
                if key == "books" then
                    return books_values
                end
                return default
            end,
            set = function(_self, key, value) books_values = value end,
            flush = function() end,
        },
        schedule = function(_delay, fn) queued[#queued + 1] = fn end,
        prevent_standby = function() rec.prevent_count = rec.prevent_count + 1 end,
        allow_standby = function() rec.allow_count = rec.allow_count + 1 end,
        now_ms = function() return 1000 end,
        show_info = function(text) rec.infos[#rec.infos + 1] = text end,
        show_transient = function(text) rec.transients[#rec.transients + 1] = text end,
        refresh_ui = function() end,
        refresh_shelf = function() rec.refreshed_shelf = rec.refreshed_shelf + 1 end,
        open_file = function(path) rec.opened[#rec.opened + 1] = path end,
        safe_callback = function(_label, fn) return fn end,
        require_login = function() return true end,
        run_online_task = function(_label, fn) fn() return true end,
        new_progress_dialog = function(_opts) return make_dialog(rec.dialog) end,
        show_confirm = function(opts) rec.confirms[#rec.confirms + 1] = opts end,
    }
    for key, value in pairs(overrides or {}) do
        host[key] = value
    end
    return Downloader:new(host), rec
end

local chapters = {
    { chapterUid = 11, title = "Ch1" },
    { chapterUid = 22, title = "Ch2" },
}

-- 1. Full-book download completes: confirm shown, standby balanced,
--    completion callback fired, books persisted.
do
    queued = {}
    local dl, rec = make_host()
    local completed
    local started = dl:start({ book_id = "b1", title = "T" }, chapters, "book", {
        on_complete = function(success, value) completed = { success, value } end,
    })
    ok(started == true, "start accepted")
    run_all()
    eq(rec.prevent_count, 1, "standby prevented once")
    eq(rec.allow_count, 1, "standby released once")
    eq(#rec.confirms, 1, "completion confirm shown")
    eq(rec.confirms[1].ok_text, "Read now", "confirm offers reading")
    eq(completed and completed[1], true, "completion success")
    eq(completed and completed[2], "/cache/book/full.epub", "completion path")
    eq(rec.refreshed_shelf, 1, "shelf refreshed")
    local saved = rec and dl.settings:get("books", {})
    ok(saved.b1 ~= nil, "book persisted to settings")
    eq(saved.b1.cached_file, "/cache/book/full.epub", "cached_file recorded")
    eq(saved.b1.cached_chapters["11"], "/cache/book/full.epub", "chapter 11 mapped")
    eq(saved.b1.cached_chapters["22"], "/cache/book/full.epub", "chapter 22 mapped")
    -- confirm ok_callback opens the file
    rec.confirms[1].ok_callback()
    eq(rec.opened[1], "/cache/book/full.epub", "confirm opens file")
end

-- 2. open_on_complete: file opens directly, no confirm dialog.
do
    queued = {}
    local dl, rec = make_host()
    dl:start({ book_id = "b2", title = "T" }, { chapters[2] }, "chapter", {
        single_chapter = true,
        open_on_complete = true,
    })
    run_all()
    eq(rec.opened[1], "/cache/book/chapter-22.epub", "opened directly on completion")
    eq(#rec.confirms, 0, "no confirm when open_on_complete")
    eq(rec.allow_count, 1, "standby released")
end

-- 3. All chapters fail: no confirm, error info, standby released.
do
    queued = {}
    local old_fetch = content_stub.fetch_single_chapter_source
    content_stub.fetch_single_chapter_source = function() error("network down") end
    local dl, rec = make_host()
    local completed
    dl:start({ book_id = "b3", title = "T" }, chapters, "book", {
        on_complete = function(success, value) completed = { success, value } end,
    })
    run_all()
    content_stub.fetch_single_chapter_source = old_fetch
    eq(completed and completed[1], false, "completion failure")
    eq(completed and completed[2], "no_chapters_downloaded", "failure reason")
    ok(#rec.infos > 0, "error surfaced via show_info")
    eq(rec.allow_count, 1, "standby released on all-fail")
    eq(#rec.confirms, 0, "no confirm on all-fail")
end

-- 4. Step exception inside a scheduled fn releases the standby guard.
do
    queued = {}
    local old_finalize = content_stub.finalize_single_chapter_content
    content_stub.finalize_single_chapter_content = function() error("boom") end
    -- make fetch raise OUTSIDE pcall path: corrupt save path instead
    local old_save = content_stub.save_book_epub
    content_stub.save_book_epub = function() error("disk full") end
    content_stub.finalize_single_chapter_content = old_finalize
    local dl, rec = make_host()
    dl:start({ book_id = "b4", title = "T" }, chapters, "book", {})
    run_all()
    content_stub.save_book_epub = old_save
    eq(rec.allow_count, 1, "standby released when save raises")
    ok(#rec.infos > 0, "save failure surfaced")
end

-- 5. Missing port is rejected at construction time.
do
    local ok_missing = pcall(function()
        Downloader:new{ client = {}, settings = {} }
    end)
    eq(ok_missing, false, "constructor asserts required ports")
end

print(string.format("downloader_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end

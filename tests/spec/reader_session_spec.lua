local ReaderSession = require("reader_session")

local checks, failures = 0, 0

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

local function ok(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local function new_settings(initial)
    local values = initial or {}
    local flushes = 0
    return {
        get = function(_self, key, default)
            local value = values[key]
            if value == nil then return default end
            return value
        end,
        set = function(_self, key, value)
            values[key] = value
        end,
        flush = function()
            flushes = flushes + 1
        end,
        values = values,
        flushes = function() return flushes end,
    }
end

local chapters = {
    { chapterUid = 11, title = "一" },
    { chapterUid = 22, title = "二" },
    { chapterUid = 33, title = "三" },
}

-- Fresh session starts at the beginning and persists every rendered page.
local settings = new_settings()
local session = ReaderSession:new{ settings = settings, now = function() return 123 end }
local action = session:begin({ book_id = "book" }, chapters)
eq(action.chapter_index, 1, "fresh chapter")
eq(action.page_mode, "resume", "fresh open mode")
eq(session:complete_open(action, 3), 1, "fresh page")
eq(settings.values.standalone_reader_positions.book.chapter_uid, 11,
    "fresh position chapter")
eq(settings.values.standalone_reader_positions.book.updated_at, 123,
    "position timestamp")

local move = session:next()
eq(move.kind, "page", "next within chapter")
eq(move.page, 2, "next page")
eq(settings.values.standalone_reader_positions.book.page, 2,
    "next page persisted")

session:next()
local next_chapter = session:next()
eq(next_chapter.kind, "open_chapter", "chapter boundary action")
eq(next_chapter.chapter_index, 2, "chapter boundary target")
eq(session:complete_open(next_chapter, 4), 1, "next chapter starts at first page")

local previous_chapter = session:previous()
eq(previous_chapter.kind, "open_chapter", "previous chapter action")
eq(previous_chapter.chapter_index, 1, "previous chapter target")
eq(session:complete_open(previous_chapter, 5), 5,
    "previous chapter opens at last page")

local prefetch = session:prefetch_action()
eq(prefetch.chapter_index, 2, "prefetch next chapter")
eq(session:prefetch_action(), nil, "prefetch offered once")

-- Resume by UID, and rescale a saved page when layout page count changes.
local resumed_settings = new_settings({
    standalone_reader_positions = {
        book = {
            chapter_uid = 22,
            chapter_index = 2,
            page = 3,
            page_count = 5,
            page_fraction = 0.5,
        },
    },
})
local resumed = ReaderSession:new{ settings = resumed_settings }
local resume_action = resumed:begin({ bookId = "book" }, chapters)
eq(resume_action.chapter_index, 2, "resume chapter by uid")
eq(resumed:complete_open(resume_action, 9), 5, "resume page rescaled")
eq(resumed:position().page_fraction, 0.5, "rescaled fraction")

-- A removed chapter falls back to the stored index, clamped to the catalog.
local stale_settings = new_settings({
    standalone_reader_positions = {
        book = { chapter_uid = 999, chapter_index = 99, page = 8, page_count = 8 },
    },
})
local stale = ReaderSession:new{ settings = stale_settings }
local stale_action = stale:begin({ book_id = "book" }, chapters)
eq(stale_action.chapter_index, 3, "stale index clamped")
eq(stale:complete_open(stale_action, 2), 1,
    "stale chapter uid does not restore page")
stale:next()
eq(stale:next().kind, "end_of_book", "end of book")

local first = ReaderSession:new{ settings = new_settings() }
local first_action = first:begin({ book_id = "book" }, chapters)
first:complete_open(first_action, 1)
eq(first:previous().kind, "start_of_book", "start of book")
ok(settings.flushes() >= 4, "positions flushed")

-- TOC jump and layout reflow preserve proportional position.
local layout_settings = new_settings()
local layout_session = ReaderSession:new{ settings = layout_settings }
local layout_open = layout_session:begin({ book_id = "layout-book" }, chapters)
layout_session:complete_open(layout_open, 5)
layout_session:next()
layout_session:next()
local reflow, layout = layout_session:set_layout{
    font_size = 36,
    line_spacing = 150,
    margin = 40,
}
eq(layout.font_size, 36, "layout font")
eq(layout.line_spacing, 150, "layout line spacing")
eq(layout.margin, 40, "layout margin")
eq(reflow.page_mode, "resume", "layout requests proportional resume")
eq(layout_session:complete_open(reflow, 9), 5, "layout restores fraction")
local toc_jump = layout_session:jump_to_chapter(3)
eq(toc_jump.chapter_index, 3, "TOC chapter target")
eq(toc_jump.page_mode, "first", "TOC starts chapter")
local missing_jump, missing_reason = layout_session:jump_to_chapter(99)
eq(missing_jump, nil, "invalid TOC target rejected")
eq(missing_reason, "chapter_not_found", "invalid TOC reason")

local mapped_chapters = {
    { chapterUid = 11, chapterIdx = 1, wordCount = 100, title = "一" },
    { chapterUid = 22, chapterIdx = 2, wordCount = 300, title = "二" },
}
local mapped = ReaderSession:new{ settings = new_settings() }
local mapped_open = mapped:begin({ book_id = "mapped" }, mapped_chapters)
mapped:complete_open(mapped_open, 5)
mapped:next()
mapped:next()
local remote = assert(mapped:remote_position())
eq(remote.chapter_uid, 11, "mapped remote chapter")
eq(remote.chapter_offset, 50, "mapped remote chapter offset")
eq(remote.safe, true, "mapped remote position marked safe")
local cloud_action = assert(mapped:apply_remote_position{
    chapter_uid = 22,
    chapter_offset = 225,
    has_chapter_offset = true,
    percent = 80,
})
eq(cloud_action.chapter_index, 2, "cloud progress chapter")
eq(cloud_action.page_mode, "resume", "cloud progress resume mode")
eq(cloud_action.saved_position.page_fraction, 0.75,
    "cloud chapter offset converted to fraction")
local rejected_cloud, rejected_reason = mapped:apply_remote_position{
    chapter_uid = 22,
    percent = 80,
    has_chapter_offset = false,
}
eq(rejected_cloud, nil, "percent-only cloud progress rejected")
eq(rejected_reason, "remote_offset_unavailable",
    "percent-only rejection reason")

-- The standalone SQLite adapter survives a real close/reopen cycle.
do
    local Settings = require("weread.lib.settings")
    local SqliteStore = require("sqlite_store")
    local root = "/tmp/weread-reader-session-test"
    os.execute("rm -rf " .. root)
    os.execute("mkdir -p " .. root)
    local store1 = SqliteStore:new{ path = root .. "/wereader.db" }
    local repo1 = Settings:new{ store = store1, data_dir = root }
    local persisted = ReaderSession:new{ settings = repo1 }
    local opened = persisted:begin({ book_id = "sqlite-book" }, chapters)
    persisted:complete_open(opened, 4)
    persisted:next()
    persisted:next()
    store1:close()

    local store2 = SqliteStore:new{ path = root .. "/wereader.db" }
    local repo2 = Settings:new{ store = store2, data_dir = root }
    local reopened = ReaderSession:new{ settings = repo2 }
    local resume = reopened:begin({ book_id = "sqlite-book" }, chapters)
    eq(resume.chapter_index, 1, "sqlite resume chapter")
    eq(reopened:complete_open(resume, 4), 3, "sqlite resume page")
    store2:close()
    os.execute("rm -rf " .. root)
end

print(string.format("reader_session_spec: %d checks, %d failure(s)",
    checks, failures))
if failures > 0 then
    os.exit(1)
end

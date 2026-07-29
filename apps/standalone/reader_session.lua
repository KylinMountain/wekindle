-- Standalone reading-session state machine.
--
-- This module owns chapter/page navigation and local position persistence,
-- but deliberately knows nothing about LVGL or crengine. The UI executes
-- open_chapter actions, then calls complete_open() with the resulting page
-- count. This keeps blocking cache/render work outside event callbacks and
-- makes the reading flow independently testable.

local ReaderSession = {}
ReaderSession.__index = ReaderSession

local POSITION_KEY = "standalone_reader_positions"
local LAYOUT_KEY = "standalone_reader_layouts"
local DEFAULT_LAYOUT = {
    font_size = 28,
    line_spacing = 120,
    margin = 24,
}

local function clamp(value, low, high)
    value = tonumber(value) or low
    if value < low then return low end
    if value > high then return high end
    return value
end

local function book_id_of(book)
    return book and (book.book_id or book.bookId)
end

local function chapter_uid(chapter)
    return chapter and (chapter.chapterUid or chapter.chapterId or chapter.chapter_uid)
end

local function page_fraction(page, page_count)
    if page_count <= 1 then
        return 0
    end
    return (page - 1) / (page_count - 1)
end

function ReaderSession:new(options)
    options = options or {}
    assert(type(options.settings) == "table"
        and type(options.settings.get) == "function"
        and type(options.settings.set) == "function"
        and type(options.settings.flush) == "function",
        "reader_session: settings repository required")
    return setmetatable({
        settings = options.settings,
        now = options.now or os.time,
        position_key = options.position_key or POSITION_KEY,
        layout_key = options.layout_key or LAYOUT_KEY,
        book = nil,
        book_id = nil,
        chapters = nil,
        chapter_index = nil,
        page = nil,
        page_count = nil,
        _prefetch_attempted = {},
    }, self)
end

local function normalized_layout(value)
    value = type(value) == "table" and value or {}
    return {
        font_size = clamp(math.floor(tonumber(value.font_size)
            or DEFAULT_LAYOUT.font_size), 16, 48),
        line_spacing = clamp(math.floor(tonumber(value.line_spacing)
            or DEFAULT_LAYOUT.line_spacing), 90, 180),
        margin = clamp(math.floor(tonumber(value.margin)
            or DEFAULT_LAYOUT.margin), 0, 80),
    }
end

function ReaderSession:layout()
    local layouts = self.settings:get(self.layout_key, {})
    local saved = type(layouts) == "table"
        and self.book_id and layouts[tostring(self.book_id)] or nil
    return normalized_layout(saved)
end

-- Persist layout and reopen the current chapter at the same proportional
-- semantic position. The caller performs the actual crengine reflow.
function ReaderSession:set_layout(changes)
    assert(self.book_id and self.chapter_index,
        "reader_session: no open chapter for layout change")
    local layout = self:layout()
    for key, value in pairs(changes or {}) do
        if DEFAULT_LAYOUT[key] ~= nil then
            layout[key] = value
        end
    end
    layout = normalized_layout(layout)
    local layouts = self.settings:get(self.layout_key, {})
    if type(layouts) ~= "table" then layouts = {} end
    layouts[tostring(self.book_id)] = layout
    self.settings:set(self.layout_key, layouts)
    self.settings:flush()
    return self:_open_action(
        self.chapter_index, "resume", self:position()), layout
end

function ReaderSession:reopen()
    assert(self.chapter_index, "reader_session: no open chapter")
    return self:_open_action(
        self.chapter_index, "resume", self:position())
end

function ReaderSession:_open_action(index, page_mode, saved_position)
    local chapter = self.chapters and self.chapters[index]
    if not chapter then
        return nil, "chapter_not_found"
    end
    return {
        kind = "open_chapter",
        chapter_index = index,
        chapter = chapter,
        page_mode = page_mode or "first",
        saved_position = saved_position,
    }
end

function ReaderSession:_saved_position()
    local all = self.settings:get(self.position_key, {})
    if type(all) ~= "table" then
        return nil
    end
    local position = all[tostring(self.book_id)]
    return type(position) == "table" and position or nil
end

function ReaderSession:_find_chapter_index(position)
    if type(position) == "table" and position.chapter_uid ~= nil then
        for index, chapter in ipairs(self.chapters) do
            if tostring(chapter_uid(chapter)) == tostring(position.chapter_uid) then
                return index
            end
        end
    end
    if type(position) == "table" and tonumber(position.chapter_index) then
        return clamp(math.floor(position.chapter_index), 1, #self.chapters)
    end
    return 1
end

-- Start a reading session and return the chapter-open action the UI should
-- execute. No state is persisted until that chapter opens successfully.
function ReaderSession:begin(book, chapters)
    local book_id = book_id_of(book)
    assert(book_id ~= nil and tostring(book_id) ~= "", "reader_session: book id required")
    assert(type(chapters) == "table" and #chapters > 0,
        "reader_session: non-empty chapter list required")
    self.book = book
    self.book_id = tostring(book_id)
    self.chapters = chapters
    self._prefetch_attempted = {}
    local saved = self:_saved_position()
    local index = self:_find_chapter_index(saved)
    return self:_open_action(index, "resume", saved)
end

local function restored_page(action, new_page_count)
    if action.page_mode == "last" then
        return new_page_count
    end
    if action.page_mode ~= "resume" then
        return 1
    end
    local saved = action.saved_position
    if type(saved) ~= "table"
        or tostring(saved.chapter_uid or "")
            ~= tostring(chapter_uid(action.chapter) or "") then
        return 1
    end
    local old_count = tonumber(saved.page_count)
    local old_page = tonumber(saved.page)
    if old_count == new_page_count and old_page then
        return clamp(math.floor(old_page), 1, new_page_count)
    end
    local fraction = tonumber(saved.page_fraction)
    if fraction then
        fraction = clamp(fraction, 0, 1)
        return clamp(math.floor(fraction * (new_page_count - 1) + 1.5),
            1, new_page_count)
    end
    return clamp(math.floor(old_page or 1), 1, new_page_count)
end

-- Commit a successful engine open and return the page that should render.
function ReaderSession:complete_open(action, page_count)
    assert(type(action) == "table" and action.kind == "open_chapter",
        "reader_session: open_chapter action required")
    page_count = math.max(1, math.floor(tonumber(page_count) or 1))
    self.chapter_index = action.chapter_index
    self.page_count = page_count
    self.page = restored_page(action, page_count)
    self:persist()
    return self.page
end

function ReaderSession:current_chapter()
    return self.chapters and self.chapters[self.chapter_index]
end

function ReaderSession:position()
    if not self.chapter_index or not self.page or not self.page_count then
        return nil
    end
    local chapter = self:current_chapter()
    return {
        schema = 1,
        book_id = self.book_id,
        chapter_uid = chapter_uid(chapter),
        chapter_index = self.chapter_index,
        page = self.page,
        page_count = self.page_count,
        page_fraction = page_fraction(self.page, self.page_count),
        updated_at = self.now(),
    }
end

-- Build a server-compatible position only when the catalog exposes enough
-- word-count data for PositionMapper to produce a bounded chapter offset.
function ReaderSession:remote_position()
    if not self.chapter_index or not self.page or not self.page_count then
        return nil, "reader_not_ready"
    end
    local Mapper = require("weread.lib.position_mapper")
    return Mapper.local_to_remote(
        self.chapters,
        page_fraction(self.page, self.page_count),
        {
            current_chapter_uid = chapter_uid(self:current_chapter()),
            summary = self:current_chapter().title or "",
            is_full_book = false,
        })
end

-- Convert a verified cloud position into the same proportional resume action
-- used by local persistence. The mapping must include a chapter offset; a
-- percent-only server record is intentionally rejected rather than guessed.
function ReaderSession:apply_remote_position(remote)
    if not self.chapters or not self.book_id then
        return nil, "reader_not_ready"
    end
    local Mapper = require("weread.lib.position_mapper")
    local current = self:current_chapter()
    local target, err = Mapper.remote_to_local(self.chapters, remote, {
        current_chapter_uid = chapter_uid(current),
        is_full_book = false,
    })
    if not target then
        return nil, err
    end
    local index
    for candidate, chapter in ipairs(self.chapters) do
        if tostring(chapter_uid(chapter))
            == tostring(chapter_uid(target.chapter)) then
            index = candidate
            break
        end
    end
    if not index then
        return nil, "remote_chapter_not_found"
    end
    local saved = {
        schema = 1,
        book_id = self.book_id,
        chapter_uid = chapter_uid(target.chapter),
        chapter_index = index,
        page_fraction = target.fraction,
        updated_at = self.now(),
        source = "cloud",
    }
    return self:_open_action(index, "resume", saved)
end

function ReaderSession:persist()
    local position = self:position()
    if not position then
        return false
    end
    local all = self.settings:get(self.position_key, {})
    if type(all) ~= "table" then
        all = {}
    end
    all[tostring(self.book_id)] = position
    self.settings:set(self.position_key, all)
    self.settings:flush()
    return true
end

function ReaderSession:next()
    if self.page < self.page_count then
        self.page = self.page + 1
        self:persist()
        return { kind = "page", page = self.page }
    end
    if self.chapter_index < #self.chapters then
        return self:_open_action(self.chapter_index + 1, "first")
    end
    return { kind = "end_of_book" }
end

function ReaderSession:previous()
    if self.page > 1 then
        self.page = self.page - 1
        self:persist()
        return { kind = "page", page = self.page }
    end
    if self.chapter_index > 1 then
        return self:_open_action(self.chapter_index - 1, "last")
    end
    return { kind = "start_of_book" }
end

function ReaderSession:jump_to_chapter(index)
    index = math.floor(tonumber(index) or 0)
    if index < 1 or index > #(self.chapters or {}) then
        return nil, "chapter_not_found"
    end
    if index == self.chapter_index then
        self.page = 1
        self:persist()
        return { kind = "page", page = 1 }
    end
    return self:_open_action(index, "first")
end

-- Return the next chapter that should be cached in the background. A target
-- is offered once per session; callers report completion to avoid retry loops
-- while offline.
function ReaderSession:prefetch_action()
    if not self.chapter_index or self.chapter_index >= #self.chapters then
        return nil
    end
    local index = self.chapter_index + 1
    local chapter = self.chapters[index]
    local key = tostring(chapter_uid(chapter) or index)
    if self._prefetch_attempted[key] then
        return nil
    end
    self._prefetch_attempted[key] = true
    return {
        kind = "prefetch_chapter",
        chapter_index = index,
        chapter = chapter,
    }
end

function ReaderSession:close()
    return self:persist()
end

return ReaderSession

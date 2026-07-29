-- Standalone book application use-cases.
--
-- Normalizes search results, merges/persists book details, resolves online or
-- cached catalogs, and exposes a one-chapter-per-step cache job for UI hosts.
-- Network and filesystem calls remain synchronous, but the step boundary lets
-- LVGL repaint between chapters and honor cancellation without duplicating
-- weread-core content logic.

local Content = require("weread.lib.content")
local Canonical = require("weread.lib.canonical")

local BookService = {}
BookService.__index = BookService

local DETAILS_KEY = "standalone_book_details"

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do
        out[key] = copy(item)
    end
    return out
end

local function merge(target, source)
    for key, value in pairs(source or {}) do
        if value ~= nil then
            target[key] = value
        end
    end
    return target
end

local function book_id_of(book)
    return book and (book.book_id or book.bookId)
end

local function filename_safe(value)
    value = tostring(value or "book")
    value = value:gsub("[%z\1-\31/\\:*?\"<>|]", "_")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or "book"
end

function BookService:new(options)
    options = options or {}
    assert(type(options.client) == "table", "book_service: client required")
    assert(type(options.settings) == "table", "book_service: settings required")
    return setmetatable({
        client = options.client,
        settings = options.settings,
        device = options.device,
        minimum_free_bytes = tonumber(options.minimum_free_bytes)
            or 64 * 1024 * 1024,
        content = options.content or Content,
        canonical = options.canonical or Canonical,
    }, self)
end

function BookService:_has_cache_space()
    if not self.device or type(self.device.free_space) ~= "function" then
        return true
    end
    local bytes, err = self.device:free_space()
    if not bytes then
        return nil, err or "free_space_unavailable"
    end
    if bytes < self.minimum_free_bytes then
        return false, "insufficient_space"
    end
    return true
end

function BookService.normalize_search_results(result)
    local books = {}
    local seen = {}
    for _group_index, group in ipairs(type(result) == "table"
        and result.results or {}) do
        for _book_index, entry in ipairs(type(group) == "table"
            and group.books or {}) do
            local book = type(entry) == "table" and (entry.bookInfo or entry) or nil
            local book_id = book_id_of(book)
            if book_id ~= nil and not seen[tostring(book_id)] then
                seen[tostring(book_id)] = true
                books[#books + 1] = book
            end
        end
    end
    return books
end

function BookService:search(keyword, count)
    keyword = tostring(keyword or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if keyword == "" then
        return nil, "empty_keyword"
    end
    local result = self.client:gateway("/store/search", {
        keyword = keyword,
        count = count or 10,
    })
    return BookService.normalize_search_results(result)
end

-- Always returns a useful record when the shelf/search record has an ID.
-- The second result is "online", "cache", or "basic"; the optional third
-- result carries the network failure that caused an offline fallback.
function BookService:load_details(book)
    local book_id = book_id_of(book)
    if book_id == nil then
        return nil, "missing_book_id"
    end
    book_id = tostring(book_id)
    local cached_all = self.settings:get(DETAILS_KEY, {})
    local cached = type(cached_all) == "table" and cached_all[book_id] or nil
    local details = merge(copy(book), copy(cached))

    local ok_info, info = pcall(self.client.get_book_info, self.client, book_id)
    if not ok_info or type(info) ~= "table" then
        return details, cached and "cache" or "basic", info
    end
    merge(details, info)
    details.book_id = details.book_id or details.bookId or book_id

    local ok_progress, progress = pcall(self.client.get_progress, self.client, book_id)
    if ok_progress and type(progress) == "table" then
        local progress_book = type(progress.book) == "table" and progress.book or progress
        details.progress = tonumber(progress_book.progress) or details.progress
    end

    cached_all = type(cached_all) == "table" and cached_all or {}
    cached_all[book_id] = copy(details)
    self.settings:set(DETAILS_KEY, cached_all)
    self.settings:flush()
    return details, "online"
end

-- Resolve a catalog online first, then fall back to Canonical Cache.
function BookService:load_catalog(book)
    local ok, result = pcall(function()
        self.content.ensure_reader_state(self.client, book)
        return self.content.fetch_catalog(self.client, book)
    end)
    if ok and type(result) == "table" and #result > 0 then
        self.canonical.write_metadata(self.settings, book)
        self.canonical.write_catalog(self.settings, book, result)
        return result, "online"
    end
    local cached, cache_err = self.canonical.read_catalog(self.settings, book)
    if cached then
        return cached, "cache", result
    end
    return nil, cache_err or result or "catalog_unavailable"
end

function BookService:new_cache_job(book, chapters, options)
    options = options or {}
    assert(book_id_of(book) ~= nil, "book_service: cache job book id required")
    assert(type(chapters) == "table" and #chapters > 0,
        "book_service: cache job chapters required")
    local has_space, space_err = self:_has_cache_space()
    if not has_space then
        return nil, space_err
    end
    self.canonical.write_metadata(self.settings, book)
    self.canonical.write_catalog(self.settings, book, chapters)
    return {
        book = book,
        chapters = chapters,
        index = 1,
        total = #chapters,
        completed = 0,
        failed = {},
        status = "running",
        cancelled = false,
        fetch_annotations = options.fetch_annotations == true,
    }
end

function BookService:cancel(job)
    if job and job.status == "running" then
        job.cancelled = true
    end
end

-- Cache at most one chapter. Returns the mutated job.
function BookService:step_cache(job)
    assert(type(job) == "table", "book_service: cache job required")
    if job.status ~= "running" then
        return job
    end
    if job.cancelled then
        job.status = "cancelled"
        return job
    end
    if job.index > job.total then
        job.status = #job.failed == 0 and "done" or "partial"
        return job
    end
    local has_space, space_err = self:_has_cache_space()
    if not has_space then
        job.status = "storage_full"
        job.failed[#job.failed + 1] = {
            chapter = job.chapters[job.index],
            error = tostring(space_err or "insufficient_space"),
        }
        return job
    end

    local chapter = job.chapters[job.index]
    job.current_chapter = chapter
    local ok, path_or_err = pcall(self.canonical.ensure_chapter,
        self.client, self.settings, job.book, chapter, {}, {
            fetch_annotations = job.fetch_annotations,
        })
    if ok then
        job.completed = job.completed + 1
        job.last_path = path_or_err
    else
        job.failed[#job.failed + 1] = {
            chapter = chapter,
            error = tostring(path_or_err),
        }
    end
    job.index = job.index + 1
    if job.index > job.total then
        job.status = #job.failed == 0 and "done" or "partial"
    end
    return job
end

function BookService:default_export_path(book)
    local dir = self.settings:get_download_dir()
    return dir .. "/" .. filename_safe(book.title or book_id_of(book)) .. ".epub"
end

function BookService:export_cached(book, chapters, output_path, options)
    output_path = output_path or self:default_export_path(book)
    return self.canonical.export_epub(
        self.settings, book, chapters, output_path, options or {})
end

return BookService

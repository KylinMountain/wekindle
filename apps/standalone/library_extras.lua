-- Standalone Phase-4 use-cases.
--
-- Keeps cloud progress conflict handling, reading-statistics fallback and
-- public-account article caching outside LVGL callbacks. Every operation
-- returns explicit source/error metadata so the UI never mistakes cached data
-- for a successful network refresh.

local Content = require("weread.lib.content")
local PositionMapper = require("weread.lib.position_mapper")
local ReadStats = require("weread.lib.read_stats")

local LibraryExtras = {}
LibraryExtras.__index = LibraryExtras

local POSITION_KEY = "standalone_reader_positions"
local MP_KEY = "standalone_mp_articles"
local STATS_KEY = "standalone_read_stats"

local function book_id_of(book)
    return book and (book.book_id or book.bookId)
end

local function chapter_uid(chapter)
    return chapter and (chapter.chapterUid or chapter.chapterId
        or chapter.chapter_uid)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function filename_safe(value)
    value = tostring(value or "collection")
    value = value:gsub("[%z\1-\31/\\:*?\"<>|]", "_")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or "collection"
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

function LibraryExtras:new(options)
    options = options or {}
    assert(type(options.client) == "table", "library_extras: client required")
    assert(type(options.settings) == "table",
        "library_extras: settings required")
    return setmetatable({
        client = options.client,
        settings = options.settings,
        content = options.content or Content,
        mapper = options.mapper or PositionMapper,
        read_stats = options.read_stats or ReadStats,
        now = options.now or os.time,
    }, self)
end

-- Fetch both progress endpoints independently. A single working endpoint is
-- enough; when both work, choose_remote records whether they materially
-- disagree so the caller can require an explicit user decision.
function LibraryExtras:fetch_progress(book, chapters)
    local book_id = tostring(book_id_of(book) or "")
    if book_id == "" then return nil, "missing_book_id" end

    local gateway, web
    local errors = {}
    local ok_gateway, gateway_raw = pcall(
        self.client.get_progress, self.client, book_id)
    if ok_gateway then
        gateway, errors.gateway = self.mapper.normalize_remote(
            gateway_raw, book_id, "gateway", chapters)
    else
        errors.gateway = tostring(gateway_raw)
    end

    local ok_web, web_raw = pcall(
        self.client.get_web_progress, self.client, book_id)
    if ok_web then
        web, errors.web = self.mapper.normalize_remote(
            web_raw, book_id, "web", chapters)
    else
        errors.web = tostring(web_raw)
    end

    local remote = self.mapper.choose_remote(web, gateway, 2)
    if not remote then
        return nil, "progress_unavailable", errors
    end
    return remote, nil, errors
end

-- Rebuild the saved local position using catalog word counts. This returns nil
-- rather than a guessed percentage whenever chapter identity/word counts are
-- insufficient for a safe upload.
function LibraryExtras:local_progress(book, chapters)
    local book_id = tostring(book_id_of(book) or "")
    local all = self.settings:get(POSITION_KEY, {})
    local saved = type(all) == "table" and all[book_id] or nil
    if type(saved) ~= "table" then
        return nil, "local_position_missing"
    end
    return self.mapper.local_to_remote(chapters, saved.page_fraction, {
        current_chapter_uid = saved.chapter_uid,
        summary = "",
        is_full_book = false,
    })
end

function LibraryExtras:compare_progress(book, chapters, remote)
    local local_position, local_err = self:local_progress(book, chapters)
    if not local_position then
        return {
            relation = "unknown",
            delta = 0,
            local_position = nil,
            local_error = local_err,
            remote = remote,
        }
    end
    local relation, delta = self.mapper.compare(local_position, remote, 2)
    return {
        relation = relation,
        delta = delta,
        local_position = local_position,
        remote = remote,
    }
end

-- Persist a cloud position for the next open. Percent-only records are not
-- accepted because they can land in the wrong chapter after catalog changes.
function LibraryExtras:accept_remote(book, chapters, remote)
    local target, err = self.mapper.remote_to_local(chapters, remote, {
        current_chapter_uid = remote and remote.chapter_uid,
        is_full_book = false,
    })
    if not target then return nil, err end
    local index
    for candidate, chapter in ipairs(chapters or {}) do
        if tostring(chapter_uid(chapter))
            == tostring(chapter_uid(target.chapter)) then
            index = candidate
            break
        end
    end
    if not index then return nil, "remote_chapter_not_found" end

    local book_id = tostring(book_id_of(book) or "")
    local all = self.settings:get(POSITION_KEY, {})
    if type(all) ~= "table" then all = {} end
    all[book_id] = {
        schema = 1,
        book_id = book_id,
        chapter_uid = chapter_uid(target.chapter),
        chapter_index = index,
        page_fraction = target.fraction,
        updated_at = self.now(),
        source = "cloud",
    }
    self.settings:set(POSITION_KEY, all)
    self.settings:flush()
    return all[book_id]
end

function LibraryExtras:upload_local(book, chapters, read_report)
    local position, err = self:local_progress(book, chapters)
    if not position or position.safe ~= true then
        return nil, err or "unsafe_local_position"
    end
    local ok, accepted, outcome = pcall(
        read_report.upload_position, read_report,
        tostring(book_id_of(book)), position, 0)
    if not ok then return nil, tostring(accepted) end
    if not accepted then
        return nil, type(outcome) == "table"
            and (outcome.error or "server_rejected") or tostring(outcome)
    end
    return true
end

local function stats_cache_key(mode, base_time)
    return tostring(mode or "monthly") .. ":"
        .. tostring(math.floor(tonumber(base_time) or 0))
end

function LibraryExtras:fetch_stats(mode, base_time)
    mode = mode or "monthly"
    local cache = self.settings:get(STATS_KEY, {})
    local key = stats_cache_key(mode, base_time)
    local ok, data = pcall(
        self.read_stats.fetch, self.client, mode, base_time)
    if ok and type(data) == "table" then
        cache = type(cache) == "table" and cache or {}
        cache[key] = { data = copy(data), fetched_at = self.now() }
        self.settings:set(STATS_KEY, cache)
        self.settings:flush()
        return data, "online"
    end
    local cached = type(cache) == "table" and cache[key] or nil
    if type(cached) == "table" and type(cached.data) == "table" then
        return copy(cached.data), "cache", tostring(data)
    end
    return nil, "unavailable", tostring(data)
end

function LibraryExtras:get_cached_mp_articles(book)
    local book_id = tostring(book_id_of(book) or "")
    local cache = self.settings:get(MP_KEY, {})
    local record = type(cache) == "table" and cache[book_id] or nil
    return type(record) == "table" and copy(record.articles) or nil
end

function LibraryExtras:_persist_mp_articles(book, articles)
    local book_id = tostring(book_id_of(book) or "")
    local cache = self.settings:get(MP_KEY, {})
    cache = type(cache) == "table" and cache or {}
    cache[book_id] = {
        articles = copy(articles),
        fetched_at = self.now(),
    }
    self.settings:set(MP_KEY, cache)
    self.settings:flush()
end

function LibraryExtras:fetch_mp_articles(book, force)
    if not force then
        local cached = self:get_cached_mp_articles(book)
        if cached and #cached > 0 then return cached, "cache" end
    end
    local book_id = tostring(book_id_of(book) or "")
    if book_id == "" then return nil, "missing_book_id" end
    local function request()
        local ticket = self.settings:get("wr_ticket", "")
        return self.client:get_mp_articles(
            book_id, 0, 100, ticket ~= "" and ticket or nil)
    end

    local ok, result, err_code = pcall(request)
    if ok and not result and (err_code == -2041 or err_code == -2012)
        and type(self.client.renew_cookie) == "function" then
        local renewed = pcall(self.client.renew_cookie, self.client)
        if renewed then ok, result, err_code = pcall(request) end
    end
    if ok and type(result) == "table" then
        local articles = self.content.parse_mp_articles(result)
        self:_persist_mp_articles(book, articles)
        return articles, "online"
    end
    local cached = self:get_cached_mp_articles(book)
    if cached then
        return cached, "cache", ok and ("errCode " .. tostring(err_code))
            or tostring(result)
    end
    return nil, "unavailable", ok and ("errCode " .. tostring(err_code))
        or tostring(result)
end

function LibraryExtras:open_mp_article(book, article)
    local cached = self.content.mp_article_cached_path(
        self.settings, book, article)
    if cached then return cached, "cache" end
    local ok, path = pcall(
        self.content.fetch_mp_article_html,
        self.client, self.settings, book, article, {})
    if not ok then return nil, "unavailable", tostring(path) end
    return path, "online"
end

-- Assemble a public-account EPUB from already cached, script-free article
-- documents. Remote image sources are removed at export time; embedded data
-- images remain self-contained. The method never performs network I/O.
function LibraryExtras:export_mp_collection(book, articles, output_path)
    if type(articles) ~= "table" or #articles == 0 then
        return nil, "articles_required"
    end
    local chapters, bodies = {}, {}
    for index, article in ipairs(articles) do
        local path = self.content.mp_article_cached_path(
            self.settings, book, article)
        if not path or not path:match("%.html$") then
            return nil, "article_not_cached:" .. tostring(index)
        end
        local document = read_file(path)
        if not document then
            return nil, "article_unreadable:" .. tostring(index)
        end
        local body = self.content.extract_body_fragment(document)
        body = tostring(body or "")
            :gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>", "")
            :gsub('%s+src="https?://[^"]*"', "")
            :gsub("%s+src='https?://[^']*'", "")
        local uid = tostring(article.reviewId or article.originalId or index)
        chapters[#chapters + 1] = {
            chapterUid = uid,
            title = article.title or ("文章 " .. tostring(index)),
            level = 1,
            wordCount = 1,
        }
        bodies[uid] = body
    end
    if not output_path then
        local dir = self.settings:get_download_dir()
        output_path = dir .. "/" .. filename_safe(
            (book.title or "公众号") .. " - 合集") .. ".epub"
    end
    local export_book = copy(book)
    export_book.title = (book.title or "公众号") .. " - 合集"
    local entries = self.content.build_book_epub_entries(
        export_book, chapters, bodies, "mp-collection", {}, [[
body { line-height: 1.7; margin: 5%; }
img { max-width: 100%; height: auto; }
]])
    self.content.write_epub_archive(output_path, entries)
    return output_path
end

return LibraryExtras

local BookService = require("book_service")

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

local values = {}
local settings = {
    get = function(_self, key, default)
        return values[key] == nil and default or values[key]
    end,
    set = function(_self, key, value)
        values[key] = value
    end,
    flush = function() end,
    get_download_dir = function() return "/tmp/exports" end,
}

local gateway_name, gateway_params
local client = {
    gateway = function(_self, name, params)
        gateway_name, gateway_params = name, params
        return {
            results = {
                { books = {
                    { bookInfo = { bookId = "1", title = "甲" } },
                    { bookInfo = { bookId = "2", title = "乙" } },
                } },
                { books = {
                    { bookInfo = { bookId = "1", title = "重复" } },
                } },
            },
        }
    end,
    get_book_info = function(_self, book_id)
        return {
            bookId = book_id,
            title = "线上详情",
            author = "作者",
            publisher = "出版社",
        }
    end,
    get_progress = function()
        return { book = { progress = 37 } }
    end,
}

local ensure_calls = {}
local canonical = {
    write_metadata = function() end,
    write_catalog = function() end,
    read_catalog = function()
        return { { chapterUid = 99, title = "离线章" } }
    end,
    ensure_chapter = function(_client, _settings, _book, chapter)
        ensure_calls[#ensure_calls + 1] = chapter.chapterUid
        if chapter.chapterUid == 22 then
            error("network down")
        end
        return "/cache/" .. chapter.chapterUid .. ".xhtml"
    end,
    export_epub = function(_settings, _book, _chapters, path)
        return path
    end,
}
local online_catalog = {
    { chapterUid = 11, title = "第一章" },
    { chapterUid = 22, title = "第二章" },
}
local content = {
    ensure_reader_state = function() end,
    fetch_catalog = function() return online_catalog end,
}

local service = BookService:new{
    client = client,
    settings = settings,
    canonical = canonical,
    content = content,
}

local results = assert(service:search("  测试  ", 8))
eq(gateway_name, "/store/search", "search endpoint")
eq(gateway_params.keyword, "测试", "search keyword trimmed")
eq(gateway_params.count, 8, "search count")
eq(#results, 2, "search results deduplicated")
eq(results[2].title, "乙", "search result normalized")

local details, source = service:load_details({ bookId = "1", title = "旧标题" })
eq(source, "online", "details source")
eq(details.title, "线上详情", "details merged")
eq(details.progress, 37, "progress merged")
eq(values.standalone_book_details["1"].publisher, "出版社",
    "details persisted")

client.get_book_info = function() error("offline") end
local cached, cached_source = service:load_details({ bookId = "1" })
eq(cached_source, "cache", "details offline source")
eq(cached.title, "线上详情", "details offline fallback")

local catalog, catalog_source = service:load_catalog({ bookId = "1" })
eq(catalog_source, "online", "catalog online source")
eq(#catalog, 2, "catalog online count")

content.fetch_catalog = function() error("offline") end
local offline_catalog, offline_source = service:load_catalog({ bookId = "1" })
eq(offline_source, "cache", "catalog offline source")
eq(offline_catalog[1].chapterUid, 99, "catalog offline value")

local job = service:new_cache_job(
    { bookId = "1", title = "测试/书" }, online_catalog)
service:step_cache(job)
eq(job.completed, 1, "cache first chapter")
eq(job.status, "running", "cache still running")
service:step_cache(job)
eq(job.status, "partial", "cache partial status")
eq(#job.failed, 1, "cache failure collected")
eq(ensure_calls[2], 22, "cache advances chapter")

local cancelled = service:new_cache_job(
    { bookId = "1" }, { online_catalog[1] })
service:cancel(cancelled)
service:step_cache(cancelled)
eq(cancelled.status, "cancelled", "cache cancellation")

local output = service:default_export_path({ bookId = "1", title = "测试/书" })
eq(output, "/tmp/exports/测试_书.epub", "safe export path")
eq(service:export_cached({ bookId = "1" }, online_catalog, "/tmp/out.epub"),
    "/tmp/out.epub", "export delegates")
ok(service:search(" ") == nil, "empty search rejected")

local storage_service = BookService:new{
    client = client,
    settings = settings,
    canonical = canonical,
    content = content,
    minimum_free_bytes = 100,
    device = {
        free_space = function() return 99 end,
    },
}
local no_job, space_err = storage_service:new_cache_job(
    { bookId = "space" }, { online_catalog[1] })
eq(no_job, nil, "low storage blocks cache job")
eq(space_err, "insufficient_space", "low storage reason")

print(string.format("book_service_spec: %d checks, %d failure(s)",
    checks, failures))
if failures > 0 then
    os.exit(1)
end

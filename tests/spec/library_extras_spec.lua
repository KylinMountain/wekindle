local LibraryExtras = require("library_extras")

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
        if values[key] == nil then return default end
        return values[key]
    end,
    set = function(_self, key, value) values[key] = value end,
    flush = function() end,
}

local chapters = {
    { chapterUid = 11, chapterIdx = 1, wordCount = 100, title = "一" },
    { chapterUid = 22, chapterIdx = 2, wordCount = 300, title = "二" },
}
values.standalone_reader_positions = {
    book = {
        chapter_uid = 11,
        page_fraction = 0.5,
    },
}

local renews = 0
local client = {
    get_progress = function()
        return { book = {
            bookId = "book", progress = 20, chapterUid = 11,
            chapterIdx = 1, chapterOffset = 80, updateTime = 20,
        } }
    end,
    get_web_progress = function()
        return {
            bookId = "book", progress = 10, chapterUid = 11,
            chapterIdx = 1, chapterOffset = 40, updateTime = 10,
        }
    end,
    get_mp_articles = function()
        return {
            reviews = {
                { subReviews = {
                    { review = {
                        reviewId = "r1",
                        belongBookId = "MP_WXS_1",
                        createTime = 123,
                        mpInfo = { title = "文章一" },
                    } },
                } },
            },
        }
    end,
    renew_cookie = function() renews = renews + 1 end,
}

local fake_stats = {
    fetch = function(_client, mode, base_time)
        return {
            mode = mode,
            base_time = base_time or 0,
            total_read_time = 3600,
            top_books = {},
        }
    end,
}
local fake_content = {
    parse_mp_articles = function(data)
        return {
            {
                title = data.reviews[1].subReviews[1].review.mpInfo.title,
                reviewId = "r1",
            },
        }
    end,
    mp_article_cached_path = function(_settings, _book, article)
        return article.cached_path or "/tmp/article.html"
    end,
    extract_body_fragment = function(document)
        return document:match("<body>(.*)</body>") or document
    end,
    build_book_epub_entries = function(_book, chapters, bodies)
        return { chapters = chapters, bodies = bodies }
    end,
    write_epub_archive = function(path, entries)
        values.export_path = path
        values.export_entries = entries
    end,
}

local service = LibraryExtras:new{
    client = client,
    settings = settings,
    content = fake_content,
    read_stats = fake_stats,
    now = function() return 99 end,
}

local remote = assert(service:fetch_progress({ book_id = "book" }, chapters))
eq(remote.source, "gateway", "newest progress endpoint selected")
eq(remote.conflict, true, "endpoint disagreement is explicit")

local comparison = service:compare_progress(
    { book_id = "book" }, chapters, remote)
eq(comparison.relation, "remote_ahead", "remote/local comparison")
eq(comparison.local_position.chapter_offset, 50, "safe local mapping")

local accepted = assert(service:accept_remote(
    { book_id = "book" }, chapters, remote))
eq(accepted.chapter_uid, 11, "remote chapter persisted")
eq(accepted.page_fraction, 0.8, "remote offset converted to fraction")
eq(accepted.source, "cloud", "remote persistence provenance")

local upload_position
local report = {
    upload_position = function(_self, book_id, position, seconds)
        upload_position = position
        eq(book_id, "book", "upload book id")
        eq(seconds, 0, "manual sync does not forge read time")
        return true
    end,
}
assert(service:upload_local({ book_id = "book" }, chapters, report))
eq(upload_position.safe, true, "only safe local position uploaded")

local stats, stats_source = service:fetch_stats("monthly", 123)
eq(stats.total_read_time, 3600, "statistics normalized service result")
eq(stats_source, "online", "statistics online source")

local articles, article_source = service:fetch_mp_articles(
    { bookId = "MP_WXS_1" }, true)
eq(#articles, 1, "MP list parsed")
eq(articles[1].title, "文章一", "MP article title")
eq(article_source, "online", "MP list online source")
local cached_articles, cached_source = service:fetch_mp_articles(
    { bookId = "MP_WXS_1" }, false)
eq(cached_articles[1].title, "文章一", "MP list persisted")
eq(cached_source, "cache", "MP list cache source")
eq(renews, 0, "valid credentials do not renew")

local article_path, path_source = service:open_mp_article(
    { bookId = "MP_WXS_1" }, articles[1])
eq(article_path, "/tmp/article.html", "cached MP article path")
eq(path_source, "cache", "cached MP article source")

local mp1 = "/tmp/wereader-mp-1.html"
local mp2 = "/tmp/wereader-mp-2.html"
local f1 = assert(io.open(mp1, "wb"))
f1:write('<html><body><p>本地一</p><script>bad()</script>'
    .. '<img src="https://remote.invalid/a.jpg"/></body></html>')
f1:close()
local f2 = assert(io.open(mp2, "wb"))
f2:write("<html><body><p>本地二</p></body></html>")
f2:close()
local collection_path = assert(service:export_mp_collection(
    { bookId = "MP_WXS_1", title = "订阅号" },
    {
        { reviewId = "a1", title = "一", cached_path = mp1 },
        { reviewId = "a2", title = "二", cached_path = mp2 },
    },
    "/tmp/collection.epub"))
eq(collection_path, "/tmp/collection.epub", "MP collection output")
eq(#values.export_entries.chapters, 2, "MP collection chapter count")
ok(values.export_entries.bodies.a1:find("<script", 1, true) == nil,
    "MP collection strips scripts")
ok(values.export_entries.bodies.a1:find("https://", 1, true) == nil,
    "MP collection strips remote image dependency")
os.remove(mp1)
os.remove(mp2)

-- Failed refresh falls back to the exact cached statistics period.
fake_stats.fetch = function() error("offline") end
local offline_stats, offline_source = service:fetch_stats("monthly", 123)
eq(offline_stats.total_read_time, 3600, "statistics offline fallback")
eq(offline_source, "cache", "statistics fallback source")

ok(values.standalone_mp_articles.MP_WXS_1 ~= nil,
    "MP cache stored outside legacy book records")

print(string.format("library_extras_spec: %d checks, %d failure(s)",
    checks, failures))
if failures > 0 then os.exit(1) end

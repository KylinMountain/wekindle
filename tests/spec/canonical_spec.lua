-- Tests for weread.lib.canonical: cache layout, offset mapping, EPUB export.
-- Content is stubbed via package.preload so no network is involved.

local raw_chapter = '<p>第一章 <img src="https://mmbiz.qpic.cn/pic1.png"/> 正文</p>'

local content_stub = {
    fetch_single_chapter_source = function()
        return raw_chapter
    end,
    finalize_single_chapter_content = function(_c, _s, _b, _ch, xhtml)
        local assets = {
            { href = "images/pic1.png", data = "PNG-DATA-1", media_type = "image/png" },
        }
        -- 按真实坐标模拟 finalize 的图片改写:远程 URL -> images/pic1.png
        local s, e = xhtml:find('src="https://mmbiz.qpic.cn/pic1.png"', 1, true)
        local replacement = 'src="images/pic1.png"'
        local edits = {
            { orig_start = s, orig_end = e + 1, orig_len = e - s + 1, new_len = #replacement },
        }
        local rewritten = xhtml:sub(1, s - 1) .. replacement .. xhtml:sub(e + 1)
        return rewritten, assets, edits
    end,
    book_cache_dir = function(settings, book_id)
        return settings.cache_dir .. "/" .. book_id
    end,
    book_dir_name = function(book_id) return book_id end,
}
package.preload["weread.lib.content"] = function() return content_stub end

-- Use the real build/write functions from content for export: keep them by
-- delegating to the actual module for those two names.
local real_content = nil
do
    package.preload["weread.lib.content"] = nil
    real_content = require("weread.lib.content")
    for k, v in pairs(content_stub) do
        real_content[k] = v
    end
end

local Canonical = require("weread.lib.canonical")
local ZipWriter = require("zip_writer")
real_content.set_zip_writer_factory(function() return ZipWriter:new() end)

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

local ROOT = "/tmp/weread-canonical-test"
os.execute("rm -rf " .. ROOT)
local settings = { cache_dir = ROOT .. "/cache" }
local book = { book_id = "b1", title = "测试书", author = "作者", format = "epub" }
local chapter = { chapterUid = 11, title = "第一章" }

-- 1. ensure_chapter writes the canonical layout.
local path = Canonical.ensure_chapter(nil, settings, book, chapter, {})
ok(path:find("canonical/b1/chapters/11.xhtml", 1, true) ~= nil, "chapter path in canonical layout: " .. path)

local doc = io.open(path, "rb"):read("a")
ok(doc:find("../styles/normalized.css", 1, true) ~= nil, "document links normalized css")
ok(doc:find("../assets/", 1, true) ~= nil, "image src rewritten to canonical asset path")
ok(doc:find("qpic.cn", 1, true) == nil, "no remote URL left in canonical document")

-- 2. textmap: raw position inside the rewritten span maps correctly.
local json = require("weread.lib.json")
local textmap = json.decode(io.open(ROOT .. "/cache/canonical/b1/chapters/11.textmap.json", "rb"):read("a"))
eq(textmap.schema, 1, "textmap schema")
eq(type(textmap.edit_chain), "table", "edit chain present")
eq(#textmap.edit_chain[1], 1, "one edit from asset rewrite")

-- raw offset 30 (inside the old src span): clamps to the span's new start
local mapped = Canonical.map_position(textmap.edit_chain, 30, false)
eq(mapped, 19, "in-span start clamps to new span start")
-- raw offset 80 (after the span): shifts by both edits' deltas
local e1, e2 = textmap.edit_chain[1][1], textmap.edit_chain[2][1]
local expected = 80 + (e1.new_len - e1.orig_len) + (e2.new_len - e2.orig_len)
eq(Canonical.map_position(textmap.edit_chain, 80, false), expected,
    "post-span offset shifts by combined delta")

-- 3. asset stored content-addressed.
local handle = io.popen("ls " .. string.format("%q", ROOT .. "/cache/canonical/b1/assets"))
local names = {}
for name in handle:lines() do
    names[#names + 1] = name
end
handle:close()
eq(#names, 1, "one hashed asset")
ok(names[1] and names[1]:match("%.png$") ~= nil, "asset has png extension")

-- 4. idempotency: second ensure does not refetch.
local fetch_count = 0
real_content.fetch_single_chapter_source = function()
    fetch_count = fetch_count + 1
    return raw_chapter
end
Canonical.ensure_chapter(nil, settings, book, chapter, {})
eq(fetch_count, 0, "cached chapter not refetched")

-- 5. export_epub packs from cache; structure validated with python zipfile.
local out = ROOT .. "/out.epub"
local ok_export, result = pcall(function()
    return Canonical.export_epub(settings, book, { chapter }, out, {})
end)
eq(ok_export, true, "export succeeded: " .. tostring(result))

local py = io.popen([=[python3 -c "
import zipfile
z = zipfile.ZipFile(']=] .. out .. [=[')
names = z.namelist()
assert names[0] == 'mimetype'
assert z.testzip() is None
assert 'OEBPS/content.opf' in names
assert 'OEBPS/text/chapter-001.xhtml' in names
assets = [n for n in names if n.startswith('OEBPS/assets/')]
assert len(assets) == 1, assets
chapter = z.read('OEBPS/text/chapter-001.xhtml').decode()
assert '../assets/' in chapter, chapter[:400]
print('export zip OK')
"]=], "r")
local out_text = py:read("a")
ok(py:close() and out_text:find("export zip OK", 1, true) ~= nil, "python zip validation: " .. tostring(out_text))

-- 6. get_chapter_document round-trip.
local doc2, tm2 = Canonical.get_chapter_document(settings, book, chapter)
ok(doc2 == doc, "document round-trip")
eq(tm2.schema, 1, "textmap round-trip")

-- 7. map_range: rune-index ranges map through the edit chain.
do
    -- raw 中「正文」位于 rune 51-52;canonical 中 URL 变长,位置随 edits 平移
    local range = Canonical.map_range(raw_chapter, doc:match("<body>(.*)</body>"),
        textmap.edit_chain, "51-53")
    local canonical_fragment = doc:match("<body>(.*)</body>")
    -- 独立验证:直接在 canonical fragment 中数 rune 位置
    local pos = 0
    local rune_count = 0
    local target_start
    while pos < #canonical_fragment do
        local b = canonical_fragment:byte(pos + 1)
        local len = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
        local ch = canonical_fragment:sub(pos + 1, pos + len)
        if ch == "正" and not target_start then
            target_start = rune_count
        end
        rune_count = rune_count + 1
        pos = pos + len
    end
    eq(range, tostring(target_start) .. "-" .. tostring(target_start + 2),
        "range maps to actual canonical rune position of 正文")
    -- 覆盖图片 URL 内部的 range 会被钳制,但不返回 nil
    local clamped = Canonical.map_range(raw_chapter, canonical_fragment,
        textmap.edit_chain, "20-30")
    ok(clamped ~= nil, "in-span range clamps without error: " .. tostring(clamped))
end

-- 8. export with annotations="footnote" injects underlines via mapped ranges.
do
    -- 手写 annotations 文件:划线覆盖「正文」(raw rune 51-52)
    os.execute("mkdir -p " .. ROOT .. "/cache/canonical/b1/annotations")
    local json = require("weread.lib.json")
    local payload = {
        underlines_data = {
            chapterUid = 11,
            underlines = {
                { range = "51-53", markText = "正文" },
            },
        },
        reviews = {},
    }
    local af = io.open(ROOT .. "/cache/canonical/b1/annotations/11.json", "w")
    af:write(json.encode(payload))
    af:close()

    local out2 = ROOT .. "/out-annotated.epub"
    local ok2, err2 = pcall(function()
        return Canonical.export_epub(settings, book, { chapter }, out2, { annotations = "footnote" })
    end)
    eq(ok2, true, "annotated export succeeded: " .. tostring(err2))
    local py2 = io.popen([=[python3 -c "
import zipfile
z = zipfile.ZipFile(']=] .. out2 .. [=[')
chapter = z.read('OEBPS/text/chapter-001.xhtml').decode()
assert 'wr-underline' in chapter, chapter[:600]
assert '正文</span>' in chapter, chapter[:600]
print('annotated export OK')
"]=], "r")
    local out2_text = py2:read("a")
    ok(py2:close() and out2_text:find("annotated export OK", 1, true) ~= nil,
        "annotation injection in exported epub: " .. tostring(out2_text))

    local reader_path, reader_variant =
        Canonical.reading_chapter_path(settings, book, chapter, {
            annotations = true,
        })
    eq(reader_variant, "annotated", "native reader uses derived annotation view")
    ok(reader_path:find("/derived/11.annotated.xhtml", 1, true) ~= nil,
        "derived reader path")
    local reader_file = io.open(reader_path, "rb")
    local reader_doc = reader_file and reader_file:read("a") or ""
    if reader_file then reader_file:close() end
    ok(reader_doc:find("wr%-underline") ~= nil,
        "derived reader XHTML contains underline")
    ok(reader_doc:find("reader%-annotations%.css") ~= nil,
        "derived reader XHTML links merged CSS")
    local clean_path, clean_variant =
        Canonical.reading_chapter_path(settings, book, chapter, {
            annotations = false,
        })
    eq(clean_path, path, "annotation toggle returns immutable canonical chapter")
    eq(clean_variant, "clean", "clean reader variant")
end

-- 9. catalog round-trip supports offline chapter selection.
do
    local chapters = {
        chapter,
        { chapterUid = 22, title = "第二章" },
    }
    local wrote, write_err = Canonical.write_catalog(settings, book, chapters)
    ok(wrote, "catalog written: " .. tostring(write_err))
    local cached, read_err = Canonical.read_catalog(settings, book)
    ok(cached ~= nil, "catalog read: " .. tostring(read_err))
    eq(#cached, 2, "cached catalog chapter count")
    eq(cached[2].chapterUid, 22, "cached catalog chapter uid")
end

os.execute("rm -rf " .. ROOT)
print(string.format("canonical_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end

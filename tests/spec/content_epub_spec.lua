-- Unit test for the IArchiver ZIP-writer injection point in weread.lib.content.
-- Verifies the EPUB invariant through the injected factory: mimetype first,
-- stored uncompressed, remaining entries deflated, archive closed.

local Content = require("weread.lib.content")

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

local captured = { entries = {}, compressions = {} }

Content.set_zip_writer_factory(function()
    return {
        open = function(_self, path, mode)
            captured.path = path
            captured.mode = mode
            return true
        end,
        setZipCompression = function(_self, compression)
            captured.compressions[#captured.compressions + 1] = compression
            captured.current_compression = compression
        end,
        addFileFromMemory = function(_self, name, data, _mtime)
            captured.entries[#captured.entries + 1] = {
                name = name,
                data = data,
                compression = captured.current_compression,
            }
        end,
        close = function(_self)
            captured.closed = true
        end,
    }
end)

local settings = { cache_dir = "/tmp/weread-core-test-cache" }
local book = { book_id = "testbook1", title = "测试书", author = "作者" }
local chapter = { chapterUid = 7, title = "第七章" }

local path = Content.save_chapter_epub(settings, book, chapter,
    "<p>正文</p>", {}, nil)

ok(path:match("%.epub$") ~= nil, "epub path returned")
eq(captured.mode, "epub", "archive opened in epub mode")
eq(captured.entries[1].name, "mimetype", "mimetype is first entry")
eq(captured.entries[1].compression, "store", "mimetype stored uncompressed")
eq(captured.entries[1].data, "application/epub+zip", "mimetype payload")

local seen = {}
for _i, entry in ipairs(captured.entries) do
    ok(seen[entry.name] == nil, "no duplicate entry " .. entry.name)
    seen[entry.name] = true
    if entry.name ~= "mimetype" then
        eq(entry.compression, "deflate", entry.name .. " deflated")
    end
end
ok(seen["META-INF/container.xml"], "container.xml present")
ok(seen["OEBPS/content.opf"], "OPF present")
ok(seen["OEBPS/nav.xhtml"], "nav present")
ok(seen["OEBPS/text/chapter.xhtml"], "chapter XHTML present")
ok(captured.closed == true, "archive closed")

local opf
for _i, entry in ipairs(captured.entries) do
    if entry.name == "OEBPS/content.opf" then
        opf = entry.data
    end
end
ok(opf and opf:find("测试书", 1, true) ~= nil, "OPF carries title")
ok(opf and opf:find('unique-identifier="bookid"', 1, true) ~= nil, "OPF identifier")

print(string.format("content_epub_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end

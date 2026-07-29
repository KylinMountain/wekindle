-- Integration test for the standalone reading loop:
-- ReaderSession action -> crengine open/render -> cross-chapter transition
-- -> persisted chapter restore. Skips when the optional native bridge is not
-- built (for example on the lightweight Linux CI job).

local ffi = require("ffi")
local suffix = ffi.os == "OSX" and ".dylib" or ".so"
local lib_path = os.getenv("CRBRIDGE_PATH")
    or ("reader/crengine_bridge/build/libcrbridge" .. suffix)
if not io.open(lib_path, "rb") then
    print("standalone_reader_flow_spec: SKIP (libcrbridge not built)")
    return
end

local font_dir = os.getenv("CR_TEST_FONT_DIR") or "/tmp/cr-fonts"
if not io.open(font_dir, "rb") then
    os.execute("mkdir -p " .. font_dir)
    os.execute('ln -sf "/System/Library/Fonts/STHeiti Medium.ttc" '
        .. font_dir .. "/ 2>/dev/null")
end

local ReaderSession = require("reader_session")
local RB = require("reader_bridge")
local failures, checks = 0, 0

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
}

local root = "/tmp/weread-standalone-reader-flow"
os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root)

local function write_chapter(uid, title)
    local paragraphs = {}
    for index = 1, 30 do
        paragraphs[#paragraphs + 1] = string.format(
            "<p>%s正文第%d段，跨章节阅读闭环测试。</p>", title, index)
    end
    local path = string.format("%s/%s.xhtml", root, uid)
    local file = assert(io.open(path, "wb"))
    file:write('<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">'
        .. "<head><title>" .. title .. "</title></head><body>"
        .. "<h1>" .. title .. "</h1>"
        .. table.concat(paragraphs)
        .. "</body></html>")
    file:close()
    return path
end

local paths = {
    ["11"] = write_chapter(11, "第一章"),
    ["22"] = write_chapter(22, "第二章"),
}
local chapters = {
    { chapterUid = 11, title = "第一章" },
    { chapterUid = 22, title = "第二章" },
}

ok(RB.init(font_dir) > 0, "font initialized")
local session = ReaderSession:new{ settings = settings }
local action = session:begin({ book_id = "integration-book" }, chapters)
ok(RB.open(paths[tostring(action.chapter.chapterUid)], {
    width = 600,
    height = 740,
    font_size = 28,
    font_face = os.getenv("CR_TEST_FONT_FACE") or "Heiti SC",
}), "first chapter opens")
session:complete_open(action, RB.page_count())

if session.page_count > 1 then
    session:next()
end
local before_reflow = session:position().page_fraction
local reflow, layout = session:set_layout{
    font_size = 34,
    line_spacing = 140,
    margin = 36,
}
ok(RB.open(paths[tostring(reflow.chapter.chapterUid)], {
    width = 600,
    height = 700,
    font_size = layout.font_size,
    line_spacing = layout.line_spacing,
    margin = layout.margin,
    font_face = os.getenv("CR_TEST_FONT_FACE") or "Heiti SC",
}), "layout reflow opens")
session:complete_open(reflow, RB.page_count())
ok(math.abs(session:position().page_fraction - before_reflow)
    <= 1 / math.max(1, session.page_count - 1),
    "layout reflow keeps nearby semantic position")

repeat
    action = session:next()
until action.kind ~= "page"
eq(action.kind, "open_chapter", "end opens next chapter")
eq(action.chapter_index, 2, "next chapter index")
ok(RB.open(paths[tostring(action.chapter.chapterUid)], {
    width = 600,
    height = 740,
    font_size = 28,
    font_face = os.getenv("CR_TEST_FONT_FACE") or "Heiti SC",
}), "second chapter opens")
session:complete_open(action, RB.page_count())
local second_text = RB.page_text(1)
ok(second_text and second_text:find("第二章", 1, true) ~= nil,
    "second chapter renders")
session:close()
RB.close()

local resumed = ReaderSession:new{ settings = settings }
local resume_action = resumed:begin({ book_id = "integration-book" }, chapters)
eq(resume_action.chapter_index, 2, "restart restores second chapter")

os.execute("rm -rf " .. root)
print(string.format("standalone_reader_flow_spec: %d checks, %d failure(s)",
    checks, failures))
if failures > 0 then
    os.exit(1)
end

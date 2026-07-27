-- IReaderEngine smoke test: open XHTML via the crengine bridge, verify
-- page count / page text / page rendering. Skips cleanly when libcrbridge
-- or a CJK font is not available (e.g. minimal CI).

local lib_path = os.getenv("CRBRIDGE_PATH")
    or "reader/crengine_bridge/build/libcrbridge.dylib"

if not io.open(lib_path, "rb") then
    print("reader_bridge_spec: SKIP (libcrbridge not built; run tools/build/build_crbridge.sh)")
    return
end

local font_dir = os.getenv("CR_TEST_FONT_DIR") or "/tmp/cr-fonts"
if not io.open(font_dir, "rb") then
    os.execute("mkdir -p " .. font_dir)
    os.execute('ln -sf "/System/Library/Fonts/STHeiti Medium.ttc" ' .. font_dir .. "/ 2>/dev/null")
end

local RB = require("reader_bridge")

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

-- Multi-page fixture with numbered paragraphs.
local paras = {}
for i = 1, 40 do
    paras[#paras + 1] = "<p>第" .. i .. "段：分页验证段落，编号 " .. i .. "。</p>"
end
local doc = '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n'
    .. '<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">\n'
    .. "<head><title>分页测试</title></head>\n<body>\n<h1>分页测试文档</h1>\n"
    .. table.concat(paras, "\n")
    .. "\n</body>\n</html>"
local doc_path = "/tmp/reader-bridge-spec.xhtml"
local f = assert(io.open(doc_path, "w"))
f:write(doc)
f:close()

local font_face = os.getenv("CR_TEST_FONT_FACE") or "Heiti SC"

local fonts = RB.init(font_dir)
ok(fonts > 0, "fonts registered: " .. tostring(fonts))

ok(RB.open(doc_path, { width = 600, height = 800, font_size = 28, font_face = font_face }),
    "document opens")

local pages = RB.page_count()
ok(pages > 1, "multi-page layout: " .. tostring(pages) .. " pages")

local p1 = RB.page_text(1)
ok(p1 and p1:find("分页测试文档", 1, true) ~= nil, "page 1 carries the heading")
ok(p1:find("第1段", 1, true) ~= nil, "page 1 carries paragraph 1")

local last = RB.page_text(pages)
ok(last and last:find("40", 1, true) ~= nil, "last page carries paragraph 40")

-- rendering produces a non-blank grayscale buffer
local buf, w, h = RB.render_page(1, 600, 800)
ok(buf ~= nil, "page 1 renders")
if buf then
    local dark = 0
    for i = 0, w * h - 1 do
        if buf[i] < 128 then
            dark = dark + 1
        end
    end
    ok(dark > 1000, "rendered page has real content (dark pixels: " .. dark .. ")")
end

RB.close()
os.remove(doc_path)
print(string.format("reader_bridge_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end

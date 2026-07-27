-- Unit tests for the standalone ZIP writer (IArchiver write side).
-- Structural assertions use Python's zipfile via an external check script
-- when available; format invariants are asserted locally.

local ZipWriter = require("zip_writer")

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

local PATH = "/tmp/weread-zip-spec.zip"

-- 1. Store + deflate entries round-trip through Python's zipfile.
do
    os.remove(PATH)
    local w = ZipWriter:new()
    eq(w:open(PATH, "epub"), true, "open ok")
    w:setZipCompression("store")
    w:addFileFromMemory("mimetype", "application/epub+zip", 1700000000)
    w:setZipCompression("deflate")
    w:addFileFromMemory("doc.txt", string.rep("hello world ", 100), 1700000000)
    w:addFileFromMemory("empty.bin", "", 1700000000)
    w:addFileFromMemory("one.bin", "x", 1700000000)
    eq(w:close(), true, "close ok")

    local py = io.popen([=[python3 -c "
import zipfile
z = zipfile.ZipFile(']=] .. PATH .. [=[')
names = z.namelist()
assert names[0] == 'mimetype', names
assert z.getinfo('mimetype').compress_type == zipfile.ZIP_STORED
assert z.getinfo('doc.txt').compress_type == zipfile.ZIP_DEFLATED
assert z.testzip() is None
assert z.read('doc.txt') == b'hello world ' * 100
assert z.read('empty.bin') == b''
assert z.read('one.bin') == b'x'
print('zipfile interop OK')
"]=], "r")
    local out = py:read("a")
    ok(py:close() and out:find("interop OK", 1, true) ~= nil, "python zipfile interop: " .. tostring(out))
end

-- 2. Unwritable destination fails at open(), not silently at close().
do
    local w = ZipWriter:new()
    eq(w:open("/nonexistent-dir-xyz/nope.zip", "epub"), false, "open fails on bad path")
    ok(w.err ~= nil, "error captured")
end

-- 3. Pre-1980 timestamps clamp to the DOS epoch instead of wrapping.
do
    os.remove(PATH)
    local w = ZipWriter:new()
    w:open(PATH, "zip")
    w:setZipCompression("store")
    w:addFileFromMemory("old.txt", "x", 0)  -- 1970-01-01
    eq(w:close(), true, "close ok")
    local file = io.open(PATH, "rb")
    local data = file:read("a")
    file:close()
    local dosdate = data:byte(13) + data:byte(14) * 256
    eq(dosdate, (0 * 512 + 1 * 32 + 1), "1970 clamped to 1980-01-01")
end

os.remove(PATH)
print(string.format("zip_writer_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end

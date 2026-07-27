-- Standalone ZIP writer (IArchiver write side) in pure Lua + zlib FFI.
-- Implements the writer contract consumed by weread.lib.content:
--
--   writer:open(path, "epub") -> ok
--   writer:setZipCompression("store"|"deflate")
--   writer:addFileFromMemory(name, data, mtime)
--   writer:close()
--
-- EPUB invariant: callers add `mimetype` first with "store"; this writer
-- records entries in memory and serializes on close(), preserving order.
-- If libz is unavailable, everything falls back to stored (still a valid
-- ZIP/EPUB, just larger).

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len);
unsigned long compressBound(unsigned long sourceLen);
int compress2(unsigned char *dest, unsigned long *destLen,
              const unsigned char *source, unsigned long sourceLen, int level);
]]

local ok_z, z = pcall(ffi.load, "z")

-- Pure-Lua CRC32 fallback for platforms without libz (table-driven,
-- processes ~1 byte per iteration — fast enough for EPUB-scale payloads).
local crc_table
local function crc32_lua(data)
    if not crc_table then
        crc_table = {}
        for n = 0, 255 do
            local c = n
            for _ = 1, 8 do
                c = c % 2 == 1 and bit.bxor(bit.rshift(c, 1), 0xEDB88320) or bit.rshift(c, 1)
            end
            crc_table[n] = c
        end
    end
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        crc = bit.bxor(crc_table[bit.band(bit.bxor(crc, data:byte(i)), 0xFF)], bit.rshift(crc, 8))
    end
    return bit.bxor(crc, 0xFFFFFFFF)
end

local ZipWriter = {}
ZipWriter.__index = ZipWriter

function ZipWriter:new()
    return setmetatable({ entries = nil, compression = "store", err = nil }, self)
end

function ZipWriter:open(path, _mode)
    -- Touch the file immediately so unwritable destinations fail at open()
    -- time instead of silently succeeding until close().
    local file, err = io.open(path, "wb")
    if not file then
        self.err = err
        return false
    end
    file:close()
    self.path = path
    self.entries = {}
    return true
end

function ZipWriter:setZipCompression(mode)
    self.compression = (mode == "deflate" and ok_z) and "deflate" or "store"
end

function ZipWriter:addFileFromMemory(name, data, mtime)
    assert(self.entries, "zip writer not open")
    self.entries[#self.entries + 1] = {
        name = name,
        data = data or "",
        mtime = mtime or os.time(),
        compression = self.compression,
    }
end

local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function u32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function dos_time(mtime)
    local t = os.date("*t", mtime)
    local year = math.max(t.year, 1980)  -- DOS epoch starts at 1980
    local dostime = t.hour * 2048 + t.min * 32 + math.floor(t.sec / 2)
    local dosdate = (year - 1980) * 512 + t.month * 32 + t.day
    return dostime, dosdate
end

local function crc(data)
    if not ok_z then
        return crc32_lua(data)
    end
    local len = ffi.new("unsigned long", #data)
    return tonumber(z.crc32(0, ffi.cast("const unsigned char *", data), len))
end

local function deflate(data)
    local bound = z.compressBound(#data)
    local dest = ffi.new("unsigned char[?]", bound)
    local dest_len = ffi.new("unsigned long[1]", bound)
    local rc = z.compress2(dest, dest_len, ffi.cast("const unsigned char *", data), #data, 6)
    if rc ~= 0 then
        return nil
    end
    local wrapped = ffi.string(dest, tonumber(dest_len[0]))
    -- ZIP method 8 is raw deflate: strip zlib's 2-byte header and the
    -- 4-byte adler32 trailer that compress2 wraps around it.
    if #wrapped < 7 then
        return nil
    end
    return wrapped:sub(3, -5)
end

local METHOD_STORE, METHOD_DEFLATE = 0, 8

function ZipWriter:close()
    assert(self.entries, "zip writer not open")
    local file, err = io.open(self.path, "wb")
    if not file then
        self.err = err
        self.entries = nil
        return false
    end

    local central = {}
    local offset = 0
    local function checked_write(...)
        local ok, werr = file:write(...)
        if not ok then
            file:close()
            self.entries = nil
            error("zip writer: write failed: " .. tostring(werr))
        end
    end
    for _i, entry in ipairs(self.entries) do
        local method = entry.compression == "deflate" and METHOD_DEFLATE or METHOD_STORE
        local payload = entry.data
        if method == METHOD_DEFLATE then
            payload = deflate(entry.data) or entry.data
            if payload == entry.data then
                method = METHOD_STORE
            end
        end
        local checksum = crc(entry.data)
        local dostime, dosdate = dos_time(entry.mtime)

        local header = table.concat{
            "PK\3\4", u16(20), u16(0), u16(method),
            u16(dostime), u16(dosdate),
            u32(checksum), u32(#payload), u32(#entry.data),
            u16(#entry.name), u16(0), entry.name,
        }
        checked_write(header, payload)
        central[#central + 1] = table.concat{
            "PK\1\2", u16(20), u16(20), u16(0), u16(method),
            u16(dostime), u16(dosdate),
            u32(checksum), u32(#payload), u32(#entry.data),
            u16(#entry.name), u16(0), u16(0), u16(0), u16(0),
            u32(0), u32(offset), entry.name,
        }
        offset = offset + #header + #payload
    end

    local cd = table.concat(central)
    checked_write(cd)
    checked_write(table.concat{
        "PK\5\6", u16(0), u16(0),
        u16(#self.entries), u16(#self.entries),
        u32(#cd), u32(offset), u16(0),
    })
    local ok_close, close_err = file:close()
    self.entries = nil
    if not ok_close then
        error("zip writer: close failed: " .. tostring(close_err))
    end
    return true
end

return ZipWriter

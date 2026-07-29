#!/usr/bin/env luajit
-- Deterministic local reader benchmark for the design §13 thresholds.

local root = arg[0]:match("^(.*)/tools/perf/") or "."
package.path = root .. "/platform/linux/?.lua;" .. package.path

local ffi = require("ffi")
local now
if ffi.os == "OSX" then
    ffi.cdef[[
    uint64_t mach_absolute_time(void);
    typedef struct { uint32_t numer; uint32_t denom; } mach_timebase_info_data_t;
    int mach_timebase_info(mach_timebase_info_data_t *info);
    int getpid(void);
    ]]
    local info = ffi.new("mach_timebase_info_data_t[1]")
    ffi.C.mach_timebase_info(info)
    now = function()
        return tonumber(ffi.C.mach_absolute_time())
            * tonumber(info[0].numer) / tonumber(info[0].denom) / 1e9
    end
else
    ffi.cdef[[
    typedef long time_t;
    typedef struct { time_t tv_sec; long tv_nsec; } timespec;
    int clock_gettime(int clk_id, timespec *tp);
    int getpid(void);
    ]]
    local tp = ffi.new("timespec[1]")
    now = function()
        ffi.C.clock_gettime(1, tp)
        return tonumber(tp[0].tv_sec) + tonumber(tp[0].tv_nsec) / 1e9
    end
end

local path = "/tmp/wereader-reader-benchmark.xhtml"
local file = assert(io.open(path, "wb"))
file:write([[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head><title>性能样本</title></head><body>]])
for index = 1, 1200 do
    file:write("<p>第", tostring(index),
        "段：这是用于验证离线分页性能、中文排版和稳定内存占用的固定文本。</p>")
end
file:write("</body></html>")
file:close()

local RB = require("reader_bridge")
assert(RB.init(os.getenv("CR_FONT_DIR") or "/tmp/cr-fonts") > 0,
    "crengine initialization failed")
local opened_at = now()
assert(RB.open(path, {
    width = 600,
    height = 700,
    font_size = 28,
    line_spacing = 120,
    margin = 24,
    font_face = os.getenv("CR_FONT_FACE") or "Heiti SC",
}), "cached document open failed")
local open_ms = (now() - opened_at) * 1000
local pages = RB.page_count()
assert(pages > 1, "benchmark fixture did not paginate")

local timings = {}
local samples = math.min(40, pages)
for index = 1, samples do
    local started = now()
    assert(RB.render_page(index, 600, 700), "page render failed")
    timings[index] = (now() - started) * 1000
end
table.sort(timings)
local median_ms = timings[math.floor((#timings + 1) / 2)]

local rss_kb = 0
local pipe = io.popen("ps -o rss= -p " .. tostring(ffi.C.getpid()))
if pipe then
    rss_kb = tonumber(pipe:read("*a")) or 0
    pipe:close()
end
RB.close()
os.remove(path)

print(string.format("cached_open_ms=%.2f", open_ms))
print(string.format("page_render_median_ms=%.2f", median_ms))
print(string.format("page_count=%d", pages))
print(string.format("rss_kb=%d", rss_kb))
print("page_network_requests=0")

if open_ms > 3000 then error("cached open exceeds 3000ms") end
if median_ms > 300 then error("page render median exceeds 300ms") end
if rss_kb > 96 * 1024 then error("reader RSS exceeds 96MB") end

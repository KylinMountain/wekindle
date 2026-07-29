local ffi = require("ffi")

ffi.cdef[[
typedef void lv_display_t;
lv_display_t * wk_kindledisplay_create(
    const char * touch_device, int32_t * width, int32_t * height);
int wk_kindledisplay_full_refresh(void);
int wk_kindledisplay_reinit(void);
int wk_kindledisplay_close(void);
const char * wk_kindledisplay_last_error(void);
const char * wk_kindledisplay_fbink_version(void);
int wk_jpeg_decode_gray(
    const uint8_t *data, uint32_t len,
    uint8_t *out, int32_t max_w, int32_t max_h,
    int32_t *out_w, int32_t *out_h);
]]

local Backend = {}
Backend.__index = Backend

function Backend.create()
    local library_path = os.getenv("WEREADER_KINDLE_HOST_PATH")
        or "libwereader_kindledisplay.so"
    local native = ffi.load(library_path)
    local width = ffi.new("int32_t[1]")
    local height = ffi.new("int32_t[1]")
    local display = native.wk_kindledisplay_create(
        os.getenv("WEREADER_TOUCH_DEVICE"), width, height)
    if display == nil then
        error("Kindle 显示初始化失败：" ..
            ffi.string(native.wk_kindledisplay_last_error()))
    end
    return setmetatable({
        native = native,
        display = display,
        width = tonumber(width[0]),
        height = tonumber(height[0]),
    }, Backend)
end

function Backend:full_refresh()
    return self.native.wk_kindledisplay_full_refresh() >= 0
end

function Backend:resume()
    return self.native.wk_kindledisplay_reinit() >= 0
end

function Backend:close()
    if self.display ~= nil then
        self.native.wk_kindledisplay_close()
        self.display = nil
    end
end

-- Decode JPEG bytes to grayscale, scaled to fit max_w x max_h (no upscale).
-- Returns gray_string, width, height, or nil on failure.
function Backend:decode_cover(data, max_w, max_h)
    local out = ffi.new("uint8_t[?]", max_w * max_h)
    local w = ffi.new("int32_t[1]")
    local h = ffi.new("int32_t[1]")
    local rc = self.native.wk_jpeg_decode_gray(
        data, #data, out, max_w, max_h, w, h)
    if rc ~= 0 then
        return nil
    end
    local width, height = tonumber(w[0]), tonumber(h[0])
    return ffi.string(out, width * height), width, height
end

return Backend

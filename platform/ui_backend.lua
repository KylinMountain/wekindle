local UIBackend = {}

function UIBackend.create(lv, requested_width, requested_height)
    if os.getenv("WEREADER_PLATFORM") == "kindle" then
        return require("kindle.backend").create()
    end

    local display = lv.C.lv_sdl_window_create(
        requested_width, requested_height)
    assert(display ~= nil, "SDL display initialization failed")
    lv.C.lv_sdl_keyboard_create()
    lv.C.lv_sdl_mouse_create()
    local backend = {
        display = display,
        width = requested_width,
        height = requested_height,
        full_refresh = function() return true end,
        resume = function() return true end,
        close = function() end,
    }
    function backend:screenshot(path)
        local draw_buf = lv.C.lv_snapshot_take(
            lv.C.lv_screen_active(), 0x06)
        if draw_buf == nil then return nil, "LVGL snapshot failed" end
        local width = tonumber(draw_buf.header.w)
        local height = tonumber(draw_buf.header.h)
        local stride = tonumber(draw_buf.header.stride)
        local file, err = io.open(path, "wb")
        if not file then
            lv.C.lv_draw_buf_destroy(draw_buf)
            return nil, err
        end
        file:write(string.format("P5\n%d %d\n255\n", width, height))
        local ffi = require("ffi")
        for y = 0, height - 1 do
            file:write(ffi.string(draw_buf.data + y * stride, width))
        end
        file:close()
        lv.C.lv_draw_buf_destroy(draw_buf)
        return path
    end
    return backend
end

return UIBackend

#!/usr/bin/env luajit
-- Wereader standalone LVGL app (Linux/macOS desktop, SDL backend).
--
-- Flow: (login QR if needed) -> shelf -> reader.
--   luajit apps/standalone/app.lua
--   luajit apps/standalone/app.lua --selftest   (run a few frames, then exit)
--
-- Environment: LVGL_PATH / CRBRIDGE_PATH point at the built dylibs;
-- CR_FONT_DIR holds CJK fonts (default: platform fonts dir or /tmp/cr-fonts).

local here = arg[0]:match("(.*/)") or "./"
package.path = here .. "?.lua;"
    .. here .. "../../core/lua/?.lua;"
    .. here .. "../../platform/standalone/?.lua;"
    .. here .. "../../platform/linux/?.lua;"
    .. here .. "../../third_party/?.lua;"
    .. package.path

local ffi = require("ffi")
ffi.cdef("unsigned int usleep(unsigned int usec);")
local lv = require("lv")
local bootstrap = require("bootstrap")

local L = lv.C
local SELFTEST = arg[1] == "--selftest"

local WIDTH, HEIGHT = 600, 800

local state = {
    screen = nil,
    cjk_font = nil,
    cjk_font_big = nil,
    page = 1,
    book = nil,
    chapter_path = nil,
    shelf_books = {},
    selected = 1,
    running = true,
    cbs = {},
}

if SELFTEST then
    -- never touch the real ~/.wereader in selftest runs
    os.execute("rm -rf /tmp/wereader-selftest")
end
local app = bootstrap.init(SELFTEST and { data_dir = "/tmp/wereader-selftest" } or nil)

-- ---------------------------------------------------------------- helpers

local function label(parent, text, font)
    local obj = L.lv_label_create(parent)
    L.lv_label_set_text(obj, text)
    if font then
        L.lv_obj_set_style_text_font(obj, font, 0)
    end
    return obj
end

local function button(parent, text, on_click, font)
    local btn = L.lv_button_create(parent)
    local lbl = label(btn, text, font)
    L.lv_obj_center(lbl)
    if on_click then
        local cb = ffi.cast("lv_event_cb_t", function(e)
            on_click(e)
        end)
        state.cbs[#state.cbs + 1] = cb  -- keep the callback alive
        L.lv_obj_add_event_cb(btn, cb, lv.EVENT_CLICKED, nil)
    end
    return btn
end

-- ------------------------------------------------------------------- QR

local function render_qr_canvas(parent, url)
    local QR = require("qr")
    local matrix = QR.encode_to_matrix(url)
    local size = #matrix
    local scale = 6
    local quiet = 4  -- QR spec: 4-module quiet zone, or scanners struggle
    local canvas_size = (size + quiet * 2) * scale
    local buf = ffi.new("unsigned char[?]", canvas_size * canvas_size)
    ffi.fill(buf, canvas_size * canvas_size, 255)
    for r = 1, size do
        for c = 1, size do
            if matrix[r][c] == 1 then
                for dr = 0, scale - 1 do
                    for dc = 0, scale - 1 do
                        buf[((r - 1 + quiet) * scale + dr) * canvas_size
                            + (c - 1 + quiet) * scale + dc] = 0
                    end
                end
            end
        end
    end
    local canvas = L.lv_canvas_create(parent)
    L.lv_canvas_set_buffer(canvas, buf, canvas_size, canvas_size, lv.CANVAS_CF_L8)
    state.qr_buf = buf  -- keep the buffer alive as long as the canvas uses it
    L.lv_obj_align(canvas, lv.ALIGN_TOP_MID, 0, 40)
    return canvas
end

local function show_login()
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "login"
    label(scr, "用微信扫码登录微信读书", state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_TOP_MID, 0, 8)

    -- kick the login flow in the background (blocking per-tick slice)
    state.login_step = "start"
    state.qr_canvas = nil
end

-- Login flow as a per-tick stepper. Each UI tick advances one non-blocking
-- slice; HTTP calls use short timeouts so the UI keeps breathing.
local function login_tick()
    if state.screen ~= "login" then
        return
    end
    if state.login_step == "start" then
        state.login_step = "uid"
        state.login_err = nil
        local ok, err = pcall(function()
            state.login_ctx = require("login").begin_login(app.client)
        end)
        if not ok then
            state.login_err = tostring(err)
            state.login_step = "error"
        end
    elseif state.login_step == "uid" then
        local ctx = state.login_ctx
        render_qr_canvas(L.lv_screen_active(), ctx.confirm_url)
        label(L.lv_screen_active(), ctx.confirm_url, nil)
        L.lv_obj_align(L.lv_obj_get_child(L.lv_screen_active(), -1), lv.ALIGN_BOTTOM_MID, 0, -8)
        state.login_step = "poll"
    elseif state.login_step == "poll" then
        local Login = require("login")
        local done, result = Login.poll_once(app.client, state.login_ctx, state.otp)
        if done == "success" then
            local ok, account_or_err = pcall(function()
                return Login.complete(app.client, app.settings, state.login_ctx, result)
            end)
            if ok then
                state.account = account_or_err
                state.screen = "shelf"
                show_shelf()
            else
                state.login_err = tostring(account_or_err)
                state.login_step = "error"
            end
        elseif done == "need_otp" or done == "otp_mismatch" then
            state.login_step = "otp"
            state.otp_hint = done == "otp_mismatch"
                and "验证码不正确，请重新输入"
                or "请输入微信读书 App 中显示的 4 位验证码"
            show_otp_input()
        elseif done == "expired" or done == "error" then
            state.login_err = done == "expired" and "二维码已过期" or tostring(result)
            state.login_step = "error"
        end
        -- "pending": keep polling on the next tick
    elseif state.login_step == "otp" then
        -- waiting for the user to submit the code via the on-screen keyboard
    elseif state.login_step == "error" then
        label(L.lv_screen_active(), "登录失败：" .. tostring(state.login_err), state.cjk_font)
        L.lv_obj_align(L.lv_obj_get_child(L.lv_screen_active(), -1), lv.ALIGN_CENTER, 0, 0)
        local retry = button(L.lv_screen_active(), "重试", function()
            show_login()
        end, state.cjk_font)
        L.lv_obj_align(retry, lv.ALIGN_CENTER, 0, 60)
        state.login_step = "done"
    end
end

-- OTP entry: textarea + on-screen keyboard (need_otp accounts).
function show_otp_input()
    local scr = L.lv_screen_active()
    label(scr, tostring(state.otp_hint or ""), state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, -1), lv.ALIGN_TOP_MID, 0, HEIGHT - 330)
    local ta = L.lv_textarea_create(scr)
    L.lv_textarea_set_one_line(ta, true)
    L.lv_textarea_set_max_length(ta, 4)
    L.lv_obj_set_size(ta, 200, 44)
    L.lv_obj_align(ta, lv.ALIGN_TOP_MID, 0, HEIGHT - 280)
    local kb = L.lv_keyboard_create(scr)
    L.lv_keyboard_set_textarea(kb, ta)
    L.lv_obj_set_size(kb, WIDTH, 240)
    L.lv_obj_align(kb, lv.ALIGN_BOTTOM_MID, 0, 0)
    button(scr, "提交", function()
        state.otp = L.lv_textarea_get_text(ta)
        if state.otp and #state.otp >= 4 then
            state.login_step = "poll"
            local scr2 = L.lv_screen_active()
            L.lv_obj_clean(scr2)
            state.cbs = {}
            render_qr_canvas(scr2, state.login_ctx.confirm_url)
        end
    end, state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, -1), lv.ALIGN_TOP_MID, 0, HEIGHT - 230)
end

-- ----------------------------------------------------------------- shelf

function show_shelf()
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.screen = "shelf"
    label(scr, "书架加载中...", state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_TOP_MID, 0, 8)
    state.shelf_step = "fetch"
end

local function open_book(index)
    local book = state.shelf_books[index]
    if not book then
        return
    end
    state.book = book
    state.screen = "loading"
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    label(scr, "正在准备《" .. tostring(book.title or book.bookId) .. "》...", state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_CENTER, 0, 0)
    state.load_step = "catalog"
end

local function shelf_tick()
    if state.screen ~= "shelf" or state.shelf_step ~= "fetch" then
        return
    end
    state.shelf_step = "done"
    local ok, result = pcall(function()
        return app.client:gateway("/shelf/sync", {})
    end)
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    if not ok then
        label(scr, "书架加载失败：" .. tostring(result), state.cjk_font)
        L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_CENTER, 0, 0)
        button(scr, "重试", function()
            show_shelf()
        end, state.cjk_font)
        L.lv_obj_align(L.lv_obj_get_child(scr, -1), lv.ALIGN_CENTER, 0, 60)
        return
    end
    state.shelf_books = result.books or {}
    local header = label(scr, "书架（" .. #state.shelf_books .. " 本）", state.cjk_font)
    L.lv_obj_align(header, lv.ALIGN_TOP_MID, 0, 6)
    local y = 40
    for i, book in ipairs(state.shelf_books) do
        if y > HEIGHT - 60 then
            break
        end
        local title = tostring(book.title or book.bookId)
        local author = tostring(book.author or "")
        local btn = button(scr, title .. "  " .. author, function()
            open_book(i)
        end, state.cjk_font)
        L.lv_obj_set_size(btn, WIDTH - 40, 44)
        L.lv_obj_set_pos(btn, 20, y)
        y = y + 52
    end
end

-- ---------------------------------------------------------------- reader

local READER_TEXT_H = HEIGHT - 60  -- bottom 60px reserved for nav buttons

local function render_current_page()
    local RB = require("reader_bridge")
    local buf, w, h = RB.render_page(state.page, WIDTH, READER_TEXT_H)
    if not buf then
        return
    end
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    local canvas = L.lv_canvas_create(scr)
    L.lv_canvas_set_buffer(canvas, buf, w, h, lv.CANVAS_CF_L8)
    state.page_buf = buf  -- keep the buffer alive as long as the canvas uses it
    L.lv_obj_set_pos(canvas, 0, 0)
    -- flip zones
    local prev = button(scr, "<", function()
        if state.page > 1 then
            state.page = state.page - 1
            render_current_page()
        end
    end, state.cjk_font)
    L.lv_obj_set_size(prev, 80, 44)
    L.lv_obj_set_pos(prev, 10, HEIGHT - 54)
    local pages = RB.page_count()
    local info = label(scr, state.page .. " / " .. pages, state.cjk_font)
    L.lv_obj_align(info, lv.ALIGN_BOTTOM_MID, 0, -14)
    local nextb = button(scr, ">", function()
        if state.page < RB.page_count() then
            state.page = state.page + 1
            render_current_page()
        end
    end, state.cjk_font)
    L.lv_obj_set_size(nextb, 80, 44)
    L.lv_obj_set_pos(nextb, WIDTH - 90, HEIGHT - 54)
    local back = button(scr, "返回", function()
        RB.close()
        show_shelf()
    end, state.cjk_font)
    L.lv_obj_set_size(back, 80, 44)
    L.lv_obj_set_pos(back, WIDTH / 2 - 40, HEIGHT - 54)
end

local function load_fail(message)
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "shelf"
    label(scr, tostring(message), state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_CENTER, 0, 0)
    button(scr, "返回书架", function()
        show_shelf()
    end, state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, -1), lv.ALIGN_CENTER, 0, 60)
end

local function load_tick()
    if state.screen ~= "loading" then
        return
    end
    local Content = require("weread.lib.content")
    local Canonical = require("weread.lib.canonical")
    local book = state.book
    if state.load_step == "catalog" then
        state.load_step = "chapter"
        local ok, err = pcall(function()
            Content.ensure_reader_state(app.client, book)
            state.chapters = Content.fetch_catalog(app.client, book)
        end)
        if not ok then
            load_fail("目录加载失败：" .. tostring(err))
            return
        end
        if type(state.chapters) ~= "table" or #state.chapters == 0 then
            load_fail("这本书没有可读章节")
            return
        end
    elseif state.load_step == "chapter" then
        state.load_step = "render"
        local ok, err = pcall(function()
            state.chapter_path = Canonical.ensure_chapter(
                app.client, app.settings, book, state.chapters[1], {})
        end)
        if not ok then
            load_fail("章节下载失败：" .. tostring(err))
            return
        end
    elseif state.load_step == "render" then
        state.load_step = "done"
        local RB = require("reader_bridge")
        local ok = RB.open(state.chapter_path, {
            width = WIDTH,
            height = READER_TEXT_H,
            font_size = 28,
            font_face = os.getenv("CR_FONT_FACE") or "Heiti SC",
        })
        if not ok then
            load_fail("章节无法打开（文件可能损坏）")
            return
        end
        state.page = 1
        state.screen = "reader"
        render_current_page()
    end
end

-- ------------------------------------------------------------------ main

local function main()
    L.lv_init()
    L.lv_sdl_window_create(WIDTH, HEIGHT)
    L.lv_sdl_keyboard_create()
    L.lv_sdl_mouse_create()
    -- freetype is already initialized by lv_init (cache size is set in
    -- lv_conf.h via LV_FREETYPE_CACHE_FT_GLYPH_CNT)

    -- the crengine bridge needs its font manager initialized once before
    -- any document is opened (cr_open dereferences fontMan otherwise)
    local RB = require("reader_bridge")
    RB.init(os.getenv("CR_FONT_DIR") or "/tmp/cr-fonts")

    local font_path = os.getenv("CR_FONT_PATH")
        or "/System/Library/Fonts/STHeiti Medium.ttc"
    state.cjk_font = L.lv_freetype_font_create(font_path, lv.FT_RENDER_MODE_NORMAL, 20, lv.FT_STYLE_NORMAL)
    state.cjk_font_big = L.lv_freetype_font_create(font_path, lv.FT_RENDER_MODE_NORMAL, 28, lv.FT_STYLE_NORMAL)

    if SELFTEST and not app.settings:is_cookie_configured() then
        -- deterministic boot path for CI: skip the real QR flow; the shelf
        -- fetch will fail offline and render the retry screen, which is
        -- exactly what the snapshot run should capture.
        app.settings:update_auth({
            cookies = { wr_gid = "selftest-gid" },
            api_key = "selftest-key",
        })
    end

    if app.settings:is_cookie_configured() then
        show_shelf()
    else
        show_login()
    end

    local frames = 0
    while state.running do
        login_tick()
        shelf_tick()
        load_tick()
        L.lv_tick_inc(10)
        L.lv_timer_handler()
        ffi.C.usleep(10000)
        frames = frames + 1
        if SELFTEST and frames > 300 then
            break
        end
    end
end

main()

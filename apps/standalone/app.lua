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

local app = bootstrap.init()

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
    local canvas_size = size * scale
    local buf = ffi.new("unsigned char[?]", canvas_size * canvas_size)
    ffi.fill(buf, canvas_size * canvas_size, 255)
    for r = 1, size do
        for c = 1, size do
            if matrix[r][c] == 1 then
                for dr = 0, scale - 1 do
                    for dc = 0, scale - 1 do
                        buf[(r - 1) * scale * canvas_size + dr * canvas_size
                            + (c - 1) * scale + dc] = 0
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
        local done, result = Login.poll_once(app.client, state.login_ctx)
        if done == "success" then
            local account = Login.complete(app.client, app.settings, state.login_ctx, result)
            state.account = account
            state.screen = "shelf"
            show_shelf()
        elseif done == "expired" or done == "error" then
            state.login_err = tostring(result)
            state.login_step = "error"
        end
        -- "pending": keep polling on the next tick
    elseif state.login_step == "error" then
        label(L.lv_screen_active(), "登录失败：" .. tostring(state.login_err), state.cjk_font)
        L.lv_obj_align(L.lv_obj_get_child(L.lv_screen_active(), -1), lv.ALIGN_CENTER, 0, 0)
        state.login_step = "done"
    end
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

local function render_current_page()
    local RB = require("reader_bridge")
    local buf, w, h = RB.render_page(state.page, WIDTH, HEIGHT)
    if not buf then
        return
    end
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
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
            state.screen = "shelf"
            show_shelf()
            return
        end
    elseif state.load_step == "chapter" then
        state.load_step = "render"
        local chapter = state.chapters[1]
        local path = Canonical.ensure_chapter(app.client, app.settings, book, chapter, {})
        state.chapter_path = path
    elseif state.load_step == "render" then
        state.load_step = "done"
        local RB = require("reader_bridge")
        RB.open(state.chapter_path, {
            width = WIDTH,
            height = HEIGHT - 60,
            font_size = 28,
            font_face = os.getenv("CR_FONT_FACE") or "Heiti SC",
        })
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
    L.lv_freetype_init(4096)

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

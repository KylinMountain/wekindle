#!/usr/bin/env luajit
-- Wereader standalone LVGL app (Linux/macOS desktop, SDL backend).
--
-- Flow: (login QR if needed) -> online/offline shelf -> multi-chapter reader.
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
    .. here .. "../../platform/?.lua;"
    .. here .. "../../third_party/?.lua;"
    .. package.path

local ffi = require("ffi")
ffi.cdef("unsigned int usleep(unsigned int usec);")
local lv = require("lv")
local bootstrap = require("bootstrap")
local ReaderSession = require("reader_session")
local BookService = require("book_service")
local CacheManager = require("cache_manager")
local ForegroundTime = require("foreground_time")
local LibraryExtras = require("library_extras")
local ReadReport = require("weread.lib.read_report")
local Protocol = require("weread.lib.protocol")
local UIBackend = require("ui_backend")

local L = lv.C
local SELFTEST = false
local SNAPSHOT_PATH = nil
for index = 1, #arg do
    if arg[index] == "--selftest" then
        SELFTEST = true
    elseif arg[index] == "--snapshot" then
        SNAPSHOT_PATH = arg[index + 1]
    end
end

local WIDTH, HEIGHT = 600, 800
local FRAME_INTERVAL_MS =
    os.getenv("WEREADER_PLATFORM") == "kindle" and 50 or 10

local state = {
    screen = nil,
    cjk_font = nil,
    cjk_font_big = nil,
    book = nil,
    chapter_path = nil,
    chapters = nil,
    reader_session = nil,
    pending_open = nil,
    prefetch_pending = false,
    shelf_books = {},
    shelf_offline = false,
    detail_source = nil,
    search_results = {},
    search_keyword = "",
    task_job = nil,
    task_mode = nil,
    task_stage = nil,
    task_cancelled = false,
    selected = 1,
    running = true,
    cbs = {},
    backend = nil,
    next_report_attempt = 0,
    last_report_status = nil,
    external_path = nil,
    progress_remote = nil,
    progress_comparison = nil,
    progress_notice = nil,
    stats_mode = "monthly",
    stats_base_time = nil,
    stats_data = nil,
    stats_source = nil,
    mp_articles = {},
    mp_source = nil,
    mp_notice = nil,
    last_loop_at = nil,
    next_power_poll = 0,
    power_state = "unknown",
}

if SELFTEST then
    -- never touch the real ~/.wereader in selftest runs
    os.execute("rm -rf /tmp/wereader-selftest")
end
local app = bootstrap.init(SELFTEST and { data_dir = "/tmp/wereader-selftest" } or nil)
local book_service = BookService:new{
    client = app.client,
    settings = app.settings,
    device = app.device,
}
local cache_manager = CacheManager:new{
    settings = app.settings,
}
local foreground_time = ForegroundTime:new{
    settings = app.settings,
    now = function() return app.now_ms() / 1000 end,
}
local library_extras = LibraryExtras:new{
    client = app.client,
    settings = app.settings,
}
local read_report = ReadReport:new{
    settings = app.settings,
    client = app.client,
    scheduler = {
        scheduleIn = function() end,
        unschedule = function() end,
    },
    get_document = function() return state.reader_session end,
    detect_book = function()
        return state.book and (state.book.book_id or state.book.bookId)
    end,
    is_online = function()
        return not app.device or app.device:is_online()
    end,
    subprocess = false,
    now = os.time,
}

-- ---------------------------------------------------------------- helpers

-- E-ink palette: strict black-on-white (see docs/official-ink-app-analysis.md)
local EINK_WHITE = ffi.new("lv_color_t", { blue = 255, green = 255, red = 255 })
local EINK_BLACK = ffi.new("lv_color_t", { blue = 0, green = 0, red = 0 })

local function eink_style_text(obj)
    L.lv_obj_set_style_text_color(obj, EINK_BLACK, 0)
end

local function eink_style_button(btn)
    L.lv_obj_set_style_bg_color(btn, EINK_WHITE, 0)
    L.lv_obj_set_style_bg_opa(btn, 255, 0)
    L.lv_obj_set_style_border_color(btn, EINK_BLACK, 0)
    L.lv_obj_set_style_border_width(btn, 1, 0)
    L.lv_obj_set_style_border_opa(btn, 255, 0)
    L.lv_obj_set_style_radius(btn, 4, 0)
end

local function label(parent, text, font)
    local obj = L.lv_label_create(parent)
    L.lv_label_set_text(obj, text)
    eink_style_text(obj)
    if font then
        L.lv_obj_set_style_text_font(obj, font, 0)
    end
    return obj
end

local function button(parent, text, on_click, font)
    local btn = L.lv_button_create(parent)
    eink_style_button(btn)
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
        state.otp = ffi.string(L.lv_textarea_get_text(ta))
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

local show_search_input
local show_book_detail
local show_progress_sync
local show_read_stats
local show_mp_articles
local begin_external_document
local build_shelf_grid
local begin_reading

function show_shelf()
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "shelf"
    label(scr, "书架加载中...", state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_TOP_MID, 0, 8)
    state.shelf_step = "fetch"
end

local function open_book_record(book)
    if not book then
        return
    end
    state.book = book
    state.reader_session = nil
    state.pending_open = nil
    state.prefetch_pending = false
    state.screen = "detail_loading"
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    label(scr, "正在加载《" .. tostring(book.title or book.bookId) .. "》...",
        state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_CENTER, 0, 0)
    state.detail_step = "fetch"
end

local function open_book(index)
    open_book_record(state.shelf_books[index])
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
        local cached = app.settings:get("standalone_shelf", {})
        if type(cached) ~= "table" or #cached == 0 then
            local failure = label(scr,
                "书架加载失败\n请检查网络或重新登录。", state.cjk_font)
            L.lv_obj_set_size(failure, WIDTH - 80, 120)
            L.lv_label_set_long_mode(failure, 0)
            L.lv_obj_align(failure, lv.ALIGN_CENTER, 0, -40)
            button(scr, "重试", function()
                show_shelf()
            end, state.cjk_font)
            L.lv_obj_align(L.lv_obj_get_child(scr, -1), lv.ALIGN_CENTER, 0, 60)
            return
        end
        state.shelf_books = cached
        state.shelf_offline = true
    else
        state.shelf_books = result.books or {}
        state.shelf_offline = false
        app.settings:set("standalone_shelf", state.shelf_books)
        app.settings:flush()
    end
    build_shelf_grid(scr)

    -- debug hook: open a book immediately after the shelf renders
    -- ("1"/bookId = detail page, "read"/"read:<bookId>" = straight to reader)
    local auto_open = os.getenv("WEREADER_AUTO_OPEN")
    if auto_open and auto_open ~= "" then
        local mode, wanted = "detail", auto_open
        if auto_open == "read" then
            mode, wanted = "read", "1"
        elseif auto_open:sub(1, 5) == "read:" then
            mode, wanted = "read", auto_open:sub(6)
        end
        for i, book in ipairs(state.shelf_books) do
            if wanted == "1" or tostring(book.bookId) == wanted then
                if mode == "read" then
                    begin_reading(book)
                else
                    open_book_record(book)
                end
                break
            end
        end
    end
end

-- ------------------------------------------------ shelf grid + cover queue

-- Layout derived from the official WeRead e-ink APK
-- (docs/official-ink-app-analysis.md): 3-column cover grid, cover aspect
-- ~0.69, search bar on top, strict black-on-white.
local SHELF_MARGIN_X = 44
local SHELF_COLS = 3
local COVER_RATIO = 0.69

local COVER_CANVAS_CAP = 30  -- ~4 MB of L8 pixels; the PW4 has 490 MB total

local function cover_attach(bookId, gray, w, h)
    local entry = state.cover_cells and state.cover_cells[bookId]
    if not entry then
        return
    end
    -- evict the oldest cover canvas before exceeding the memory budget
    state.cover_order = state.cover_order or {}
    while #state.cover_order >= COVER_CANVAS_CAP do
        local oldest = table.remove(state.cover_order, 1)
        local old = state.cover_cells[oldest]
        if old and old.canvas then
            L.lv_obj_delete(old.canvas)
            old.canvas = nil
            state.cover_bufs[oldest] = nil
            if old.placeholder then
                L.lv_label_set_text(old.placeholder,
                    tostring(old.title or ""))
            end
        end
    end
    local buf = ffi.new("unsigned char[?]", w * h)
    ffi.copy(buf, gray, w * h)
    local canvas = L.lv_canvas_create(entry.box)
    L.lv_canvas_set_buffer(canvas, buf, w, h, lv.CANVAS_CF_L8)
    L.lv_obj_set_pos(canvas,
        math.floor((entry.w - w) / 2), math.floor((entry.h - h) / 2))
    state.cover_bufs[bookId] = buf  -- keep the pixel buffer alive
    entry.canvas = canvas
    state.cover_order[#state.cover_order + 1] = bookId
    L.lv_label_set_text(entry.placeholder, "")
end

function build_shelf_grid(scr)
    state.cover_cells = {}
    state.cover_queue = {}
    state.cover_bufs = {}

    -- header row 1: search bar
    local search = button(scr, "搜索微信读书", function()
        show_search_input()
    end, state.cjk_font)
    L.lv_obj_set_size(search, WIDTH - 2 * SHELF_MARGIN_X, 64)
    L.lv_obj_set_pos(search, SHELF_MARGIN_X, 16)

    -- header row 2: shelf count (left) + reading stats + quit (right)
    local prefix = state.shelf_offline and "离线书架" or "书架"
    local header = label(scr,
        prefix .. "（" .. #state.shelf_books .. " 本）", state.cjk_font)
    L.lv_obj_set_pos(header, SHELF_MARGIN_X, 108)
    local quit = button(scr, "退出", function()
        state.running = false
    end, state.cjk_font)
    L.lv_obj_set_size(quit, 140, 56)
    L.lv_obj_set_pos(quit, WIDTH - SHELF_MARGIN_X - 140, 96)
    local stats = button(scr, "阅读统计", function()
        show_read_stats("monthly")
    end, state.cjk_font)
    L.lv_obj_set_size(stats, 200, 56)
    L.lv_obj_set_pos(stats, WIDTH - SHELF_MARGIN_X - 140 - 16 - 200, 96)

    -- scrollable cover grid
    local grid_top = 172
    local grid = L.lv_obj_create(scr)
    L.lv_obj_set_size(grid, WIDTH, HEIGHT - grid_top)
    L.lv_obj_set_pos(grid, 0, grid_top)
    L.lv_obj_set_style_bg_color(grid, EINK_WHITE, 0)
    L.lv_obj_set_style_bg_opa(grid, 255, 0)
    L.lv_obj_set_style_border_width(grid, 0, 0)
    L.lv_obj_set_style_radius(grid, 0, 0)
    lv.lv_obj_set_style_pad_all(grid, 0, 0)
    L.lv_obj_set_scrollbar_mode(grid, lv.SCROLLBAR_MODE_OFF)

    local gap = 27
    local cellw = math.floor(
        (WIDTH - 2 * SHELF_MARGIN_X - (SHELF_COLS - 1) * gap) / SHELF_COLS)
    local coverh = math.floor(cellw / COVER_RATIO)
    local titleh = 56
    local cellh = coverh + titleh
    local rowgap = 36

    -- ONE shared callback for every cell: LuaJIT caps the number of live
    -- FFI callbacks (per-cell callbacks kill the app after a few shelf
    -- rebuilds with "too many callbacks"). The cell index travels in
    -- user_data instead. Tap = read immediately (like the official ink
    -- app); long-press = book detail (cache/export/progress).
    if not state.cell_cb then
        state.cell_cb = ffi.cast("lv_event_cb_t", function(e)
            -- LVGL still fires CLICKED on release after a long-press; the
            -- long-press handler marks it so we don't open the reader too.
            if state.long_press_consumed then
                state.long_press_consumed = false
                return
            end
            local ud = L.lv_event_get_user_data(e)
            local index = tonumber(ffi.cast("intptr_t", ud))
            if index and state.shelf_books[index] then
                begin_reading(state.shelf_books[index])
            end
        end)
        state.cell_long_cb = ffi.cast("lv_event_cb_t", function(e)
            state.long_press_consumed = true
            local ud = L.lv_event_get_user_data(e)
            local index = tonumber(ffi.cast("intptr_t", ud))
            if index and state.shelf_books[index] then
                open_book(index)
            end
        end)
    end

    for i, book in ipairs(state.shelf_books) do
        local col = (i - 1) % SHELF_COLS
        local row = math.floor((i - 1) / SHELF_COLS)
        local x = SHELF_MARGIN_X + col * (cellw + gap)
        local y = row * (cellh + rowgap)

        local cell = L.lv_obj_create(grid)
        L.lv_obj_set_size(cell, cellw, cellh)
        L.lv_obj_set_pos(cell, x, y)
        L.lv_obj_set_style_bg_opa(cell, 0, 0)
        L.lv_obj_set_style_border_width(cell, 0, 0)
        lv.lv_obj_set_style_pad_all(cell, 0, 0)
        L.lv_obj_set_scrollbar_mode(cell, lv.SCROLLBAR_MODE_OFF)
        L.lv_obj_remove_flag(cell, lv.FLAG_SCROLLABLE)
        L.lv_obj_add_flag(cell, lv.FLAG_CLICKABLE)
        L.lv_obj_add_event_cb(cell, state.cell_cb, lv.EVENT_CLICKED,
            ffi.cast("void*", ffi.cast("intptr_t", i)))
        L.lv_obj_add_event_cb(cell, state.cell_long_cb,
            lv.EVENT_LONG_PRESSED,
            ffi.cast("void*", ffi.cast("intptr_t", i)))

        -- cover box (placeholder with title until the JPEG arrives)
        local box = L.lv_obj_create(cell)
        L.lv_obj_set_size(box, cellw, coverh)
        L.lv_obj_set_pos(box, 0, 0)
        eink_style_button(box)
        L.lv_obj_set_scrollbar_mode(box, lv.SCROLLBAR_MODE_OFF)
        L.lv_obj_remove_flag(box, lv.FLAG_SCROLLABLE)

        local ph = label(box, tostring(book.title or book.bookId),
            state.cjk_font)
        L.lv_obj_set_size(ph, cellw - 40, coverh - 40)
        L.lv_obj_set_pos(ph, 20, 20)
        L.lv_label_set_long_mode(ph, lv.LABEL_LONG_WRAP)
        L.lv_obj_set_style_text_align(ph, lv.TEXT_ALIGN_CENTER, 0)

        -- title under the cover: single line, ellipsis, left-aligned
        local title = label(cell, tostring(book.title or book.bookId),
            state.cjk_font)
        L.lv_obj_set_size(title, cellw, titleh - 8)
        L.lv_obj_set_pos(title, 0, coverh + 8)
        L.lv_label_set_long_mode(title, lv.LABEL_LONG_DOT)

        if book.cover and book.cover ~= "" then
            local bookId = tostring(book.bookId)
            state.cover_cells[bookId] = {
                box = box, placeholder = ph,
                url = book.cover, w = cellw, h = coverh,
                title = tostring(book.title or book.bookId),
                row = row,
            }
            -- only the first screens' covers are queued up front; deeper
            -- rows are queued by cover_tick as they scroll into view, so
            -- a big shelf doesn't burst hundreds of TLS handshakes
            if row < 6 then
                state.cover_queue[#state.cover_queue + 1] = bookId
            end
        end
    end

    state.grid_obj = grid
    state.grid_row_h = cellh + rowgap
end

-- One cover per frame: cache file -> decode -> swap placeholder for canvas.
-- The queue is re-ordered every tick so covers nearest the visible rows
-- load first (the user can scroll deep before the tail is fetched).
-- WEREADER_NO_COVERS=1 disables the pipeline entirely (debug isolation).
local COVERS_DISABLED = os.getenv("WEREADER_NO_COVERS") == "1"
local function cover_tick()
    if COVERS_DISABLED then
        return
    end
    if state.screen ~= "shelf" then
        return
    end
    local queue = state.cover_queue
    if not queue or #queue == 0 then
        return
    end
    if not state.backend or not state.backend.decode_cover
        or not app.transport then
        state.cover_queue = {}
        return
    end
    local pick = 1
    local first_row, last_row
    if state.grid_obj and state.grid_row_h then
        local scroll_y = tonumber(L.lv_obj_get_scroll_y(state.grid_obj)) or 0
        local grid_h = HEIGHT - 172
        first_row = math.max(0, math.floor(scroll_y / state.grid_row_h) - 1)
        last_row = math.ceil((scroll_y + grid_h) / state.grid_row_h) + 1
        -- re-queue visible covers that were evicted by the memory cap
        for bookId, entry in pairs(state.cover_cells) do
            if not entry.canvas and not entry.queued and not entry.failed
                and entry.row >= first_row and entry.row <= last_row then
                entry.queued = true
                queue[#queue + 1] = bookId
            end
        end
        local best_dist = math.huge
        for qi, bookId in ipairs(queue) do
            local entry = state.cover_cells[bookId]
            local row = entry and entry.row or first_row
            local dist = row < first_row and (first_row - row)
                or (row > last_row and (row - last_row) or 0)
            if dist < best_dist then
                best_dist = dist
                pick = qi
            end
        end
    end
    local bookId = table.remove(queue, pick)
    local entry = state.cover_cells[bookId]
    if entry then
        entry.queued = false
    end
    if not entry or entry.canvas then
        return
    end
    local dir = app.data_dir .. "/covers"
    local path = dir .. "/" .. bookId .. ".jpg"
    local data
    local f = io.open(path, "rb")
    if f then
        data = f:read("*a")
        f:close()
    else
        os.execute('mkdir -p "' .. dir .. '"')
        local ok, body, code = pcall(function()
            return app.transport:roundtrip{
                method = "GET", url = entry.url, timeout = 15 }
        end)
        if not ok or type(body) ~= "string" or code ~= 200 or #body < 100 then
            entry.failed = true  -- no retry storms when scrolled into view
            return
        end
        data = body
        local wf = io.open(path, "wb")
        if wf then
            wf:write(data)
            wf:close()
        end
    end
    local gray, w, h = state.backend:decode_cover(data, entry.w, entry.h)
    if gray then
        cover_attach(bookId, gray, w, h)
    end
end

-- ----------------------------------------------------- search / book detail

local function utf8_prefix(value, max_chars)
    value = tostring(value or "")
    local chars = {}
    for char in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = char
        if #chars >= max_chars then
            break
        end
    end
    local text = table.concat(chars)
    if #text < #value then
        text = text .. "…"
    end
    return text
end

function begin_reading(book)
    state.book = book
    state.reader_session = nil
    state.pending_open = nil
    state.prefetch_pending = false
    state.external_path = nil
    state.screen = "loading"
    state.load_step = "catalog"
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    label(scr, "正在准备《" .. tostring(book.title or book.bookId) .. "》...",
        state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_CENTER, 0, 0)
end

local start_book_task

show_book_detail = function(book, source, warning)
    state.book = book
    state.detail_source = source or state.detail_source
    state.screen = "detail"
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}

    local title = label(scr, utf8_prefix(book.title or book.bookId or "未命名", 28),
        state.cjk_font_big)
    L.lv_obj_set_pos(title, 20, 16)

    local metadata = {}
    if book.author and book.author ~= "" then
        metadata[#metadata + 1] = "作者：" .. tostring(book.author)
    end
    if book.publisher and book.publisher ~= "" then
        metadata[#metadata + 1] = "出版社：" .. tostring(book.publisher)
    end
    if book.categoryName or book.category then
        metadata[#metadata + 1] = "分类：" .. tostring(book.categoryName or book.category)
    end
    if tonumber(book.wordCount) then
        metadata[#metadata + 1] = "字数：" .. tostring(book.wordCount)
    end
    if tonumber(book.newRating) and tonumber(book.newRating) > 0 then
        metadata[#metadata + 1] = string.format(
            "评分：%.1f", tonumber(book.newRating) / 100)
    end
    if tonumber(book.progress) then
        metadata[#metadata + 1] = "阅读进度：" .. tostring(book.progress) .. "%"
    end
    local cached_bytes = cache_manager:book_usage(book.book_id or book.bookId)
    if cached_bytes > 0 then
        metadata[#metadata + 1] = string.format(
            "本地缓存：%.1f MB", cached_bytes / 1024 / 1024)
    end
    if state.cache_notice then
        metadata[#metadata + 1] = state.cache_notice
        state.cache_notice = nil
    end
    if state.detail_source and state.detail_source ~= "online" then
        metadata[#metadata + 1] = "当前使用离线详情"
    end
    local meta = label(scr, table.concat(metadata, "\n"), state.cjk_font)
    L.lv_obj_set_pos(meta, 20, 70)

    local intro_text = book.intro and book.intro ~= ""
        and ("简介：" .. utf8_prefix(book.intro, 150))
        or "暂无简介"
    if warning then
        intro_text = intro_text .. "\n\n详情刷新失败：" .. utf8_prefix(warning, 60)
    end
    local intro = label(scr, intro_text, state.cjk_font)
    L.lv_obj_set_size(intro, WIDTH - 40, 250)
    L.lv_label_set_long_mode(intro, 0)
    L.lv_obj_set_pos(intro, 20, 250)

    local is_mp = Protocol.is_mp_book(book.book_id or book.bookId)
    if is_mp then
        local articles = button(scr, "查看公众号文章", function()
            show_mp_articles(false)
        end, state.cjk_font)
        L.lv_obj_set_size(articles, WIDTH - 40, 44)
        L.lv_obj_set_pos(articles, 20, HEIGHT - 190)
    else
        local read = button(scr, "立即阅读", function()
            begin_reading(state.book)
        end, state.cjk_font)
        L.lv_obj_set_size(read, 170, 44)
        L.lv_obj_set_pos(read, 20, HEIGHT - 240)

        local cache = button(scr, "缓存整本", function()
            start_book_task("cache")
        end, state.cjk_font)
        L.lv_obj_set_size(cache, 170, 44)
        L.lv_obj_set_pos(cache, 215, HEIGHT - 240)

        local export = button(scr, "导出 EPUB", function()
            start_book_task("export")
        end, state.cjk_font)
        L.lv_obj_set_size(export, 170, 44)
        L.lv_obj_set_pos(export, 410, HEIGHT - 240)

        local progress = button(scr, "云端进度", function()
            show_progress_sync()
        end, state.cjk_font)
        L.lv_obj_set_size(progress, 270, 44)
        L.lv_obj_set_pos(progress, 20, HEIGHT - 190)
    end

    local clear_cache = button(scr, "清除本书缓存", function()
        local result = cache_manager:clear_book(
            state.book.book_id or state.book.bookId)
        if result.ok then
            state.cache_notice = string.format(
                "已清理 %.1f MB 缓存", result.removed_bytes / 1024 / 1024)
        else
            state.cache_notice = "部分缓存清理失败，请查看日志"
        end
        show_book_detail(state.book, state.detail_source)
    end, state.cjk_font)
    L.lv_obj_set_size(clear_cache, is_mp and (WIDTH - 40) or 270, 44)
    L.lv_obj_set_pos(clear_cache, is_mp and 20 or 310,
        is_mp and (HEIGHT - 140) or (HEIGHT - 190))

    local back = button(scr, "返回书架", show_shelf, state.cjk_font)
    L.lv_obj_set_size(back, WIDTH - 40, 44)
    L.lv_obj_set_pos(back, 20, HEIGHT - 90)
end

local function detail_tick()
    if state.screen ~= "detail_loading" or state.detail_step ~= "fetch" then
        return
    end
    state.detail_step = "done"
    local ok, details, source, warning = pcall(
        book_service.load_details, book_service, state.book)
    if not ok or not details then
        show_book_detail(state.book, "basic", tostring(details or source))
        return
    end
    show_book_detail(details, source, warning and tostring(warning) or nil)
end

local function show_search_results(keyword, books)
    state.search_results = books
    state.screen = "search_results"
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    local header = label(scr, "搜索：" .. utf8_prefix(keyword, 24), state.cjk_font)
    L.lv_obj_set_pos(header, 20, 12)
    if #books == 0 then
        local empty = label(scr, "没有搜索结果", state.cjk_font)
        L.lv_obj_align(empty, lv.ALIGN_CENTER, 0, 0)
    end
    local y = 52
    for index, book in ipairs(books) do
        if y > HEIGHT - 115 then break end
        local text = utf8_prefix(book.title or book.bookId or "未命名", 24)
        if book.author and book.author ~= "" then
            text = text .. " · " .. utf8_prefix(book.author, 10)
        end
        local item = button(scr, text, function()
            open_book_record(books[index])
        end, state.cjk_font)
        L.lv_obj_set_size(item, WIDTH - 40, 48)
        L.lv_obj_set_pos(item, 20, y)
        y = y + 54
    end
    local back = button(scr, "返回搜索", function()
        show_search_input()
    end, state.cjk_font)
    L.lv_obj_set_size(back, WIDTH - 40, 44)
    L.lv_obj_set_pos(back, 20, HEIGHT - 54)
end

show_search_input = function()
    state.screen = "search_input"
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    local heading = label(scr, "搜索微信读书", state.cjk_font_big)
    L.lv_obj_align(heading, lv.ALIGN_TOP_MID, 0, 18)
    local ta = L.lv_textarea_create(scr)
    L.lv_textarea_set_one_line(ta, true)
    L.lv_textarea_set_max_length(ta, 80)
    L.lv_obj_set_size(ta, WIDTH - 60, 50)
    L.lv_obj_set_pos(ta, 30, 80)
    if state.search_keyword ~= "" then
        L.lv_textarea_set_text(ta, state.search_keyword)
    end
    local search = button(scr, "搜索", function()
        local keyword = ffi.string(L.lv_textarea_get_text(ta))
        if keyword ~= "" then
            state.search_keyword = keyword
            state.screen = "search_loading"
            state.search_step = "fetch"
            L.lv_obj_clean(scr)
            state.cbs = {}
            local loading = label(scr, "正在搜索「" .. utf8_prefix(keyword, 24) .. "」...",
                state.cjk_font)
            L.lv_obj_align(loading, lv.ALIGN_CENTER, 0, 0)
        end
    end, state.cjk_font)
    L.lv_obj_set_size(search, 180, 44)
    L.lv_obj_set_pos(search, 100, 150)
    local cancel = button(scr, "取消", show_shelf, state.cjk_font)
    L.lv_obj_set_size(cancel, 180, 44)
    L.lv_obj_set_pos(cancel, 320, 150)

    local kb = L.lv_keyboard_create(scr)
    L.lv_keyboard_set_textarea(kb, ta)
    L.lv_obj_set_size(kb, WIDTH, 360)
    L.lv_obj_align(kb, lv.ALIGN_BOTTOM_MID, 0, 0)
end

local function search_tick()
    if state.screen ~= "search_loading" or state.search_step ~= "fetch" then
        return
    end
    state.search_step = "done"
    local ok, books_or_err, search_err = pcall(
        book_service.search, book_service, state.search_keyword, 10)
    if ok and books_or_err then
        show_search_results(state.search_keyword, books_or_err)
        return
    end
    state.screen = "search_error"
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    local message = label(scr, "搜索失败："
        .. utf8_prefix(books_or_err or search_err, 100), state.cjk_font)
    L.lv_obj_align(message, lv.ALIGN_CENTER, 0, -40)
    local retry = button(scr, "重试", function()
        state.screen = "search_loading"
        state.search_step = "fetch"
    end, state.cjk_font)
    L.lv_obj_align(retry, lv.ALIGN_CENTER, -80, 30)
    local back = button(scr, "返回", show_search_input, state.cjk_font)
    L.lv_obj_align(back, lv.ALIGN_CENTER, 80, 30)
end

-- ----------------------------------------- progress / statistics / MP

local function format_duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return string.format("%d 小时 %d 分钟", hours, minutes)
    end
    return string.format("%d 分钟", minutes)
end

local function render_progress_sync()
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "progress"
    local title = label(scr, "云端阅读进度", state.cjk_font_big)
    L.lv_obj_align(title, lv.ALIGN_TOP_MID, 0, 24)

    local remote = state.progress_remote
    local comparison = state.progress_comparison or {}
    local relation_text = ({
        same = "本地与云端基本一致",
        remote_ahead = "云端进度更靠后",
        local_ahead = "本地进度更靠后",
        different = "章节位置存在冲突",
        unknown = "没有可安全映射的本地进度",
    })[comparison.relation] or "进度状态未知"
    local local_position = comparison.local_position
    local lines = {
        string.format("云端：%.1f%% · %s",
            tonumber(remote and remote.percent) or 0,
            utf8_prefix(remote and remote.summary or "", 24)),
        local_position
            and string.format("本地：%.1f%%",
                tonumber(local_position.percent) or 0)
            or "本地：暂无可安全映射的位置",
        "判断：" .. relation_text,
    }
    if remote and remote.conflict then
        lines[#lines + 1] = "提示：微信读书两个进度接口返回不一致，已采用更新时间较新的记录。"
    end
    if state.progress_notice then
        lines[#lines + 1] = state.progress_notice
    end
    local info = label(scr, table.concat(lines, "\n\n"), state.cjk_font)
    L.lv_obj_set_size(info, WIDTH - 60, 360)
    L.lv_label_set_long_mode(info, 0)
    L.lv_obj_set_pos(info, 30, 100)

    local use_cloud = button(scr, "使用云端位置", function()
        local saved, err = library_extras:accept_remote(
            state.book, state.chapters, state.progress_remote)
        state.progress_notice = saved
            and "已保存云端位置，下次打开将从该处继续。"
            or ("无法使用云端位置：" .. tostring(err))
        render_progress_sync()
    end, state.cjk_font)
    L.lv_obj_set_size(use_cloud, 250, 48)
    L.lv_obj_set_pos(use_cloud, 35, HEIGHT - 190)

    local keep_local = button(scr, "保留本地并上传", function()
        state.screen = "progress_loading"
        state.progress_stage = "upload"
        local loading = L.lv_screen_active()
        L.lv_obj_clean(loading)
        state.cbs = {}
        local text = label(loading, "正在上传本地进度…", state.cjk_font)
        L.lv_obj_align(text, lv.ALIGN_CENTER, 0, 0)
    end, state.cjk_font)
    L.lv_obj_set_size(keep_local, 250, 48)
    L.lv_obj_set_pos(keep_local, WIDTH - 285, HEIGHT - 190)

    local retry = button(scr, "重新拉取", function()
        show_progress_sync()
    end, state.cjk_font)
    L.lv_obj_set_size(retry, 200, 44)
    L.lv_obj_set_pos(retry, 70, HEIGHT - 115)
    local back = button(scr, "返回详情", function()
        show_book_detail(state.book, state.detail_source)
    end, state.cjk_font)
    L.lv_obj_set_size(back, 200, 44)
    L.lv_obj_set_pos(back, WIDTH - 270, HEIGHT - 115)
end

show_progress_sync = function()
    state.screen = "progress_loading"
    state.progress_stage = "catalog"
    state.progress_notice = nil
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    local text = label(scr, "正在读取本地与云端进度…", state.cjk_font)
    L.lv_obj_align(text, lv.ALIGN_CENTER, 0, 0)
end

local function progress_tick()
    if state.screen ~= "progress_loading" then return end
    if state.progress_stage == "catalog" then
        state.progress_stage = "fetch"
        local ok, chapters, err = pcall(
            book_service.load_catalog, book_service, state.book)
        if not ok or not chapters then
            state.progress_stage = "error"
            state.progress_notice = "目录不可用：" .. utf8_prefix(chapters or err, 80)
            state.progress_remote = { percent = 0 }
            state.progress_comparison = { relation = "unknown" }
            render_progress_sync()
            return
        end
        state.chapters = chapters
        return
    end
    if state.progress_stage == "fetch" then
        state.progress_stage = "done"
        local remote, err = library_extras:fetch_progress(
            state.book, state.chapters)
        if not remote then
            state.progress_notice = "云端进度读取失败：" .. tostring(err)
            state.progress_remote = { percent = 0 }
            state.progress_comparison = { relation = "unknown" }
        else
            state.progress_remote = remote
            state.progress_comparison = library_extras:compare_progress(
                state.book, state.chapters, remote)
        end
        render_progress_sync()
        return
    end
    if state.progress_stage == "upload" then
        state.progress_stage = "done"
        local uploaded, err = library_extras:upload_local(
            state.book, state.chapters, read_report)
        state.progress_notice = uploaded
            and "本地进度已安全上传。"
            or ("未上传：" .. tostring(err))
        render_progress_sync()
    end
end

local function render_read_stats()
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "stats"
    local data = state.stats_data or {}
    local title = label(scr, "阅读统计", state.cjk_font_big)
    L.lv_obj_align(title, lv.ALIGN_TOP_MID, 0, 14)

    local modes = {
        { "周", "weekly" }, { "月", "monthly" },
        { "年", "annually" }, { "全部", "overall" },
    }
    local mode_width = math.floor((WIDTH - 50) / 4)
    for index, item in ipairs(modes) do
        local mode_name = item[2]
        local prefix = state.stats_mode == mode_name and "● " or ""
        local mode = button(scr, prefix .. item[1], function()
            show_read_stats(mode_name)
        end, state.cjk_font)
        L.lv_obj_set_size(mode, mode_width, 40)
        L.lv_obj_set_pos(mode, 10 + (index - 1) * (mode_width + 10), 58)
    end

    local lines = {
        data.period_label and data.period_label ~= ""
            and ("周期：" .. data.period_label) or "周期：全部",
        "阅读总时长：" .. format_duration(data.total_read_time),
        "阅读天数：" .. tostring(data.read_days or 0),
        "日均：" .. format_duration(data.day_average),
    }
    if state.stats_source == "cache" then
        lines[#lines + 1] = "当前为离线缓存数据"
    end
    local top = data.top_books or {}
    if #top > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "阅读最多"
        for index = 1, math.min(5, #top) do
            lines[#lines + 1] = string.format("%d. %s · %s",
                index, utf8_prefix(top[index].title, 20),
                format_duration(top[index].seconds))
        end
    end
    local info = label(scr, table.concat(lines, "\n"), state.cjk_font)
    L.lv_obj_set_size(info, WIDTH - 60, 480)
    L.lv_label_set_long_mode(info, 0)
    L.lv_obj_set_pos(info, 30, 120)

    local previous = button(scr, "上一周期", function()
        if data.allow_prev then
            show_read_stats(state.stats_mode, data.prev_base_time)
        end
    end, state.cjk_font)
    L.lv_obj_set_size(previous, 150, 42)
    L.lv_obj_set_pos(previous, 25, HEIGHT - 110)
    local back = button(scr, "返回书架", show_shelf, state.cjk_font)
    L.lv_obj_set_size(back, 200, 42)
    L.lv_obj_set_pos(back, WIDTH / 2 - 100, HEIGHT - 110)
    local next_period = button(scr, "下一周期", function()
        if data.allow_next then
            show_read_stats(state.stats_mode, data.next_base_time)
        end
    end, state.cjk_font)
    L.lv_obj_set_size(next_period, 150, 42)
    L.lv_obj_set_pos(next_period, WIDTH - 175, HEIGHT - 110)
end

show_read_stats = function(mode, base_time)
    state.stats_mode = mode or state.stats_mode or "monthly"
    state.stats_base_time = base_time
    state.stats_stage = "fetch"
    state.screen = "stats_loading"
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    local text = label(scr, "正在加载阅读统计…", state.cjk_font)
    L.lv_obj_align(text, lv.ALIGN_CENTER, 0, 0)
end

local function stats_tick()
    if state.screen ~= "stats_loading" or state.stats_stage ~= "fetch" then
        return
    end
    state.stats_stage = "done"
    local data, source, err = library_extras:fetch_stats(
        state.stats_mode, state.stats_base_time)
    if data then
        state.stats_data = data
        state.stats_source = source
        render_read_stats()
        return
    end
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "stats_error"
    local message = label(scr, "阅读统计加载失败："
        .. utf8_prefix(err, 100), state.cjk_font)
    L.lv_obj_align(message, lv.ALIGN_CENTER, 0, -40)
    local retry = button(scr, "重试", function()
        show_read_stats(state.stats_mode, state.stats_base_time)
    end, state.cjk_font)
    L.lv_obj_align(retry, lv.ALIGN_CENTER, -80, 30)
    local back = button(scr, "返回书架", show_shelf, state.cjk_font)
    L.lv_obj_align(back, lv.ALIGN_CENTER, 80, 30)
end

local function render_mp_articles(page)
    local articles = state.mp_articles or {}
    page = math.max(1, math.floor(tonumber(page) or 1))
    local per_page = math.max(4, math.floor((HEIGHT - 155) / 50))
    local page_count = math.max(1, math.ceil(#articles / per_page))
    if page > page_count then page = page_count end
    state.mp_page = page
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "mp_list"
    local source = state.mp_source == "cache" and " · 离线" or ""
    local title = label(scr, string.format("公众号文章 %d/%d%s",
        page, page_count, source), state.cjk_font_big)
    L.lv_obj_align(title, lv.ALIGN_TOP_MID, 0, 10)
    if state.mp_notice then
        local notice = label(scr, utf8_prefix(state.mp_notice, 54),
            state.cjk_font)
        L.lv_obj_set_pos(notice, 20, 48)
    end
    local first = (page - 1) * per_page + 1
    local last = math.min(#articles, first + per_page - 1)
    local y = state.mp_notice and 78 or 58
    for index = first, last do
        local article = articles[index]
        local date = tonumber(article.createTime) and
            os.date("%Y-%m-%d", article.createTime) or ""
        local item = button(scr,
            utf8_prefix(article.title or "未命名文章", 24)
                .. (date ~= "" and (" · " .. date) or ""),
            function()
                state.mp_article = article
                state.mp_stage = "article"
                state.screen = "mp_loading"
                L.lv_obj_clean(L.lv_screen_active())
                state.cbs = {}
                local loading = label(L.lv_screen_active(),
                    "正在准备文章…", state.cjk_font)
                L.lv_obj_align(loading, lv.ALIGN_CENTER, 0, 0)
            end, state.cjk_font)
        L.lv_obj_set_size(item, WIDTH - 40, 42)
        L.lv_obj_set_pos(item, 20, y)
        y = y + 48
    end
    if #articles == 0 then
        local empty = label(scr, "暂无文章", state.cjk_font)
        L.lv_obj_align(empty, lv.ALIGN_CENTER, 0, 0)
    end
    local previous = button(scr, "<", function()
        render_mp_articles(page - 1)
    end, state.cjk_font)
    L.lv_obj_set_size(previous, 55, 42)
    L.lv_obj_set_pos(previous, 10, HEIGHT - 52)
    local refresh = button(scr, "刷新", function()
        show_mp_articles(true)
    end, state.cjk_font)
    L.lv_obj_set_size(refresh, 85, 42)
    L.lv_obj_set_pos(refresh, 75, HEIGHT - 52)
    local export = button(scr, "导出合集", function()
        state.mp_export_index = 1
        state.mp_stage = "export_article"
        state.screen = "mp_loading"
        L.lv_obj_clean(L.lv_screen_active())
        state.cbs = {}
        local loading = label(L.lv_screen_active(),
            "正在准备公众号合集…", state.cjk_font)
        L.lv_obj_align(loading, lv.ALIGN_CENTER, 0, 0)
    end, state.cjk_font)
    L.lv_obj_set_size(export, 125, 42)
    L.lv_obj_set_pos(export, 170, HEIGHT - 52)
    local back = button(scr, "返回详情", function()
        show_book_detail(state.book, state.detail_source)
    end, state.cjk_font)
    L.lv_obj_set_size(back, 150, 42)
    L.lv_obj_set_pos(back, 305, HEIGHT - 52)
    local next_page = button(scr, ">", function()
        render_mp_articles(page + 1)
    end, state.cjk_font)
    L.lv_obj_set_size(next_page, 55, 42)
    L.lv_obj_set_pos(next_page, WIDTH - 65, HEIGHT - 52)
end

show_mp_articles = function(force)
    state.mp_force = force == true
    state.mp_stage = "list"
    state.screen = "mp_loading"
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    local text = label(scr, "正在加载公众号文章…", state.cjk_font)
    L.lv_obj_align(text, lv.ALIGN_CENTER, 0, 0)
end

local function mp_tick()
    if state.screen ~= "mp_loading" then return end
    if state.mp_stage == "list" then
        state.mp_stage = "done"
        local articles, source, err = library_extras:fetch_mp_articles(
            state.book, state.mp_force)
        if articles then
            state.mp_articles = articles
            state.mp_source = source
            state.mp_notice = err
            render_mp_articles(1)
            return
        end
        state.mp_articles = {}
        state.mp_source = source
        state.mp_notice = err
        render_mp_articles(1)
        return
    end
    if state.mp_stage == "article" then
        state.mp_stage = "done"
        local path, source, err = library_extras:open_mp_article(
            state.book, state.mp_article)
        if path then
            begin_external_document(path, state.mp_article)
            return
        end
        state.mp_notice = "文章下载失败：" .. tostring(err or source)
        render_mp_articles(state.mp_page)
        return
    end
    if state.mp_stage == "export_article" then
        local index = state.mp_export_index or 1
        if index <= #(state.mp_articles or {}) then
            local path, _source, err = library_extras:open_mp_article(
                state.book, state.mp_articles[index])
            if not path then
                state.mp_notice = string.format(
                    "合集准备失败（第 %d 篇）：%s", index, tostring(err))
                render_mp_articles(state.mp_page)
                return
            end
            state.mp_export_index = index + 1
            local scr = L.lv_screen_active()
            L.lv_obj_clean(scr)
            state.cbs = {}
            local progress = label(scr, string.format(
                "正在准备公众号合集：%d/%d",
                index, #state.mp_articles), state.cjk_font)
            L.lv_obj_align(progress, lv.ALIGN_CENTER, 0, 0)
            return
        end
        state.mp_stage = "export"
        return
    end
    if state.mp_stage == "export" then
        state.mp_stage = "done"
        local ok, path_or_err, export_err = pcall(
            library_extras.export_mp_collection, library_extras,
            state.book, state.mp_articles)
        state.mp_notice = ok and path_or_err
            and ("合集已导出：" .. tostring(path_or_err))
            or ("合集导出失败：" .. tostring(path_or_err or export_err))
        render_mp_articles(state.mp_page)
    end
end

local function render_task_screen(message, finished)
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    local title_text = state.task_mode == "export" and "导出 EPUB" or "缓存整本"
    local title = label(scr, title_text, state.cjk_font_big)
    L.lv_obj_align(title, lv.ALIGN_TOP_MID, 0, 50)
    local status = label(scr, message, state.cjk_font)
    L.lv_obj_set_size(status, WIDTH - 60, 360)
    L.lv_label_set_long_mode(status, 0)
    L.lv_obj_set_pos(status, 30, 160)
    if finished then
        local back = button(scr, "返回书籍详情", function()
            show_book_detail(state.book, state.detail_source)
        end, state.cjk_font)
        L.lv_obj_set_size(back, WIDTH - 80, 48)
        L.lv_obj_align(back, lv.ALIGN_BOTTOM_MID, 0, -60)
    else
        local cancel = button(scr, "取消任务", function()
            state.task_cancelled = true
            if state.task_job then
                book_service:cancel(state.task_job)
            end
        end, state.cjk_font)
        L.lv_obj_set_size(cancel, WIDTH - 80, 48)
        L.lv_obj_align(cancel, lv.ALIGN_BOTTOM_MID, 0, -60)
    end
end

start_book_task = function(mode)
    state.task_mode = mode
    state.task_stage = "catalog"
    state.task_job = nil
    state.task_cancelled = false
    state.screen = "book_task"
    render_task_screen("正在准备章节目录…", false)
end

local function finish_book_task(message)
    state.task_stage = "done"
    render_task_screen(message, true)
end

local function task_tick()
    if state.screen ~= "book_task" or state.task_stage == "done" then
        return
    end
    if state.task_cancelled
        and (not state.task_job or state.task_job.status ~= "running") then
        finish_book_task("任务已取消。")
        return
    end
    if state.task_stage == "catalog" then
        state.task_stage = "catalog_loading"
        local ok, chapters, source_or_err = pcall(
            book_service.load_catalog, book_service, state.book)
        if not ok or not chapters then
            finish_book_task("章节目录加载失败："
                .. utf8_prefix(chapters or source_or_err, 100))
            return
        end
        state.chapters = chapters
        local cache_config = app.settings:get("cache")
        local job_ok, job_or_err, create_err = pcall(
            book_service.new_cache_job, book_service, state.book, chapters, {
                fetch_annotations =
                    cache_config.download_underlines_and_thoughts == true,
            })
        if not job_ok or not job_or_err then
            finish_book_task("缓存任务创建失败："
                .. utf8_prefix(job_or_err or create_err, 100))
            return
        end
        state.task_job = job_or_err
        state.task_stage = "cache"
        render_task_screen(string.format("准备缓存，共 %d 章。", #chapters), false)
        return
    end
    if state.task_stage == "cache" then
        local job = book_service:step_cache(state.task_job)
        if job.status == "running" then
            local chapter = job.current_chapter or {}
            render_task_screen(string.format(
                "已完成 %d/%d 章\n当前：%s\n失败：%d",
                job.completed, job.total,
                utf8_prefix(chapter.title or chapter.chapterUid, 40),
                #job.failed), false)
            return
        end
        if job.status == "cancelled" then
            finish_book_task(string.format(
                "任务已取消，已缓存 %d/%d 章。", job.completed, job.total))
            return
        end
        if job.status == "partial" then
            finish_book_task(string.format(
                "缓存完成，但有 %d 章失败；已成功 %d/%d 章。",
                #job.failed, job.completed, job.total))
            return
        end
        if job.status == "storage_full" then
            finish_book_task(string.format(
                "存储空间不足，已缓存 %d/%d 章；请先清理缓存。",
                job.completed, job.total))
            return
        end
        if state.task_mode == "export" then
            state.task_stage = "export"
            render_task_screen("章节缓存完成，正在生成 EPUB…", false)
        else
            finish_book_task(string.format(
                "缓存完成：%d 章均可离线阅读。", job.completed))
        end
        return
    end
    if state.task_stage == "export" then
        state.task_stage = "exporting"
        local cache_config = app.settings:get("cache")
        local ok, path_or_err, export_err = pcall(
            book_service.export_cached, book_service,
            state.book, state.chapters, nil, {
                annotations = cache_config.download_underlines_and_thoughts
                    and "footnote" or "none",
            })
        if ok and path_or_err then
            finish_book_task("EPUB 已导出：\n" .. tostring(path_or_err))
        else
            finish_book_task("EPUB 导出失败："
                .. utf8_prefix(path_or_err or export_err, 100))
        end
    end
end

-- ---------------------------------------------------------------- reader

local READER_TEXT_H = HEIGHT - 100  -- bottom area reserved for page status/navigation

local render_current_page
local show_toc
local show_reader_settings

begin_external_document = function(path, article)
    local review_id = tostring(article and (
        article.reviewId or article.originalId) or "article")
    local synthetic_book = {
        book_id = tostring(state.book.book_id or state.book.bookId)
            .. "::" .. review_id,
        title = article and article.title or "公众号文章",
    }
    local chapters = {
        {
            chapterUid = review_id,
            chapterIdx = 1,
            wordCount = 1,
            title = synthetic_book.title,
        },
    }
    state.external_path = path
    state.reader_session = ReaderSession:new{ settings = app.settings }
    state.pending_open = state.reader_session:begin(synthetic_book, chapters)
    state.chapters = chapters
    state.prefetch_pending = false
    state.screen = "loading"
    state.load_step = "chapter"
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    local text = label(scr, "正在打开文章…", state.cjk_font)
    L.lv_obj_align(text, lv.ALIGN_CENTER, 0, 0)
end

local function close_reader()
    local RB = require("reader_bridge")
    foreground_time:close()
    if state.reader_session then
        state.reader_session:close()
    end
    RB.close()
    state.reader_session = nil
    state.pending_open = nil
    state.prefetch_pending = false
    state.external_path = nil
    show_book_detail(state.book, state.detail_source)
end

local function queue_chapter_open(action)
    state.pending_open = action
    state.screen = "loading"
    state.load_step = "chapter"
    local chapter = action.chapter or {}
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    label(scr, "正在打开「" .. tostring(chapter.title or "下一章") .. "」...",
        state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_CENTER, 0, 0)
end

local function show_book_boundary(message)
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "boundary"
    label(scr, message, state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_CENTER, 0, -30)
    local resume = button(scr, "返回阅读", function()
        state.screen = "reader"
        render_current_page()
    end, state.cjk_font)
    L.lv_obj_align(resume, lv.ALIGN_CENTER, 0, 30)
    local back = button(scr, "返回书架", close_reader, state.cjk_font)
    L.lv_obj_align(back, lv.ALIGN_CENTER, 0, 90)
end

local function handle_reader_action(action)
    if not action then
        return
    end
    if action.kind == "page" then
        render_current_page()
    elseif action.kind == "open_chapter" then
        queue_chapter_open(action)
    elseif action.kind == "end_of_book" then
        show_book_boundary("本书已读完")
    elseif action.kind == "start_of_book" then
        show_book_boundary("已经是全书第一页")
    end
end

show_toc = function(page)
    local session = state.reader_session
    if not session then return end
    page = math.max(1, math.floor(tonumber(page) or 1))
    local per_page = math.max(4, math.floor((HEIGHT - 150) / 48))
    local page_count = math.max(1, math.ceil(#session.chapters / per_page))
    if page > page_count then page = page_count end

    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "toc"
    local title = label(scr, string.format("目录 %d/%d", page, page_count),
        state.cjk_font_big)
    L.lv_obj_align(title, lv.ALIGN_TOP_MID, 0, 10)

    -- shared callback + chapter index in user_data (FFI callback slots are
    -- a scarce resource on LuaJIT)
    if not state.toc_cb then
        state.toc_cb = ffi.cast("lv_event_cb_t", function(e)
            local s = state.reader_session
            if not s then return end
            local index = tonumber(ffi.cast("intptr_t",
                L.lv_event_get_user_data(e)))
            if index and s.chapters[index] then
                state.screen = "reader"
                handle_reader_action(s:jump_to_chapter(index))
            end
        end)
    end

    local first = (page - 1) * per_page + 1
    local last = math.min(#session.chapters, first + per_page - 1)
    local y = 58
    for index = first, last do
        local chapter = session.chapters[index]
        local prefix = index == session.chapter_index and "● " or ""
        local item = button(scr, prefix
            .. utf8_prefix(chapter.title or ("第 " .. index .. " 章"), 28),
            nil, state.cjk_font)
        L.lv_obj_add_event_cb(item, state.toc_cb, lv.EVENT_CLICKED,
            ffi.cast("void*", ffi.cast("intptr_t", index)))
        L.lv_obj_set_size(item, WIDTH - 40, 42)
        L.lv_obj_set_pos(item, 20, y)
        y = y + 48
    end

    local previous = button(scr, "上一页", function()
        show_toc(page - 1)
    end, state.cjk_font)
    L.lv_obj_set_size(previous, 110, 42)
    L.lv_obj_set_pos(previous, 20, HEIGHT - 52)
    local resume = button(scr, "返回阅读", function()
        state.screen = "reader"
        render_current_page()
    end, state.cjk_font)
    L.lv_obj_set_size(resume, 140, 42)
    L.lv_obj_set_pos(resume, WIDTH / 2 - 70, HEIGHT - 52)
    local next_page = button(scr, "下一页", function()
        show_toc(page + 1)
    end, state.cjk_font)
    L.lv_obj_set_size(next_page, 110, 42)
    L.lv_obj_set_pos(next_page, WIDTH - 130, HEIGHT - 52)
end

show_reader_settings = function()
    local session = state.reader_session
    if not session then return end
    local layout = session:layout()
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "reader_settings"

    local title = label(scr, "阅读排版", state.cjk_font_big)
    L.lv_obj_align(title, lv.ALIGN_TOP_MID, 0, 30)

    local function add_control(y, name, key, step, suffix)
        local text = label(scr, string.format("%s：%d%s",
            name, layout[key], suffix or ""), state.cjk_font)
        L.lv_obj_set_pos(text, 70, y + 8)
        local decrease = button(scr, "−", function()
            local change = {}
            change[key] = layout[key] - step
            local action = session:set_layout(change)
            queue_chapter_open(action)
        end, state.cjk_font_big)
        L.lv_obj_set_size(decrease, 70, 44)
        L.lv_obj_set_pos(decrease, WIDTH - 190, y)
        local increase = button(scr, "+", function()
            local change = {}
            change[key] = layout[key] + step
            local action = session:set_layout(change)
            queue_chapter_open(action)
        end, state.cjk_font_big)
        L.lv_obj_set_size(increase, 70, 44)
        L.lv_obj_set_pos(increase, WIDTH - 100, y)
    end

    add_control(140, "字号", "font_size", 2, " px")
    add_control(220, "行距", "line_spacing", 10, "%")
    add_control(300, "边距", "margin", 4, " px")

    -- Kindle frontlight (powerd stays up while the framework is stopped)
    if os.getenv("WEREADER_PLATFORM") == "kindle" then
        local level = 12
        local probe = io.popen(
            "lipc-get-prop com.lab126.powerd flIntensity 2>/dev/null")
        if probe then
            level = tonumber(probe:read("*a")) or 12
            probe:close()
        end
        state.brightness = level
        local glow = label(scr, string.format("亮度：%d", level), state.cjk_font)
        L.lv_obj_set_pos(glow, 70, 388)
        local function set_brightness(value)
            value = math.max(0, math.min(24, value))
            os.execute("lipc-set-prop com.lab126.powerd flIntensity " .. value)
            L.lv_label_set_text(glow, string.format("亮度：%d", value))
        end
        local dim = button(scr, "−", function()
            set_brightness((state.brightness or 12) - 2)
            state.brightness = math.max(0, (state.brightness or 12) - 2)
        end, state.cjk_font_big)
        L.lv_obj_set_size(dim, 70, 44)
        L.lv_obj_set_pos(dim, WIDTH - 190, 380)
        local bright = button(scr, "+", function()
            set_brightness((state.brightness or 12) + 2)
            state.brightness = math.min(24, (state.brightness or 12) + 2)
        end, state.cjk_font_big)
        L.lv_obj_set_size(bright, 70, 44)
        L.lv_obj_set_pos(bright, WIDTH - 100, 380)
    end

    local report_config = app.settings:get("read_report")
    local report_text = report_config.enabled
        and "阅读时长上报：已开启"
        or "阅读时长上报：已关闭"
    local report_toggle = button(scr, report_text, function()
        local config = app.settings:get("read_report")
        config.enabled = not config.enabled
        config.mode = "auto"
        config.report_on_open = true
        app.settings:set("read_report", config)
        app.settings:flush()
        state.next_report_attempt = 0
        state.last_report_status = config.enabled and "等待满 30 秒后上报"
            or "已停止上报"
        show_reader_settings()
    end, state.cjk_font)
    L.lv_obj_set_size(report_toggle, WIDTH - 140, 48)
    L.lv_obj_set_pos(report_toggle, 70, 460)
    if state.last_report_status then
        local report_status = label(scr,
            utf8_prefix(state.last_report_status, 50), state.cjk_font)
        L.lv_obj_set_pos(report_status, 70, 520)
    end

    local cache_config = app.settings:get("cache")
    local annotations_toggle = button(scr,
        cache_config.show_annotations
            and "阅读中显示划线/想法：开"
            or "阅读中显示划线/想法：关",
        function()
            local config = app.settings:get("cache")
            config.show_annotations = not config.show_annotations
            app.settings:set("cache", config)
            app.settings:flush()
            queue_chapter_open(session:reopen())
        end, state.cjk_font)
    L.lv_obj_set_size(annotations_toggle, WIDTH - 140, 44)
    L.lv_obj_set_pos(annotations_toggle, 70, 580)

    local annotation_cache = button(scr,
        cache_config.download_underlines_and_thoughts
            and "缓存/导出包含注释：开"
            or "缓存/导出包含注释：关",
        function()
            local config = app.settings:get("cache")
            config.download_underlines_and_thoughts =
                not config.download_underlines_and_thoughts
            app.settings:set("cache", config)
            app.settings:flush()
            show_reader_settings()
        end, state.cjk_font)
    L.lv_obj_set_size(annotation_cache, WIDTH - 140, 44)
    L.lv_obj_set_pos(annotation_cache, 70, 635)

    local back = button(scr, "返回阅读", function()
        state.screen = "reader"
        render_current_page()
    end, state.cjk_font)
    L.lv_obj_set_size(back, WIDTH - 80, 48)
    L.lv_obj_set_pos(back, 40, HEIGHT - 80)
end

render_current_page = function()
    local RB = require("reader_bridge")
    local session = state.reader_session
    if not session then
        return
    end
    local buf, w, h = RB.render_page(session.page, WIDTH, READER_TEXT_H)
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
    state.screen = "reader"
    -- E-ink friendly controls: explicit buttons, no animated overlays.
    local control_gap = 8
    local control_width = math.floor((WIDTH - control_gap * 6) / 5)
    local control_y = HEIGHT - 50
    local prev = button(scr, "<", function()
        handle_reader_action(session:previous())
    end, state.cjk_font)
    L.lv_obj_set_size(prev, control_width, 42)
    L.lv_obj_set_pos(prev, control_gap, control_y)
    local toc = button(scr, "目录", function()
        show_toc(math.ceil(session.chapter_index /
            math.max(4, math.floor((HEIGHT - 150) / 48))))
    end, state.cjk_font)
    L.lv_obj_set_size(toc, control_width, 42)
    L.lv_obj_set_pos(toc, control_gap * 2 + control_width, control_y)
    local info = label(scr, string.format("%d/%d章 · %d/%d页",
        session.chapter_index, #session.chapters, session.page, session.page_count),
        state.cjk_font)
    L.lv_obj_align(info, lv.ALIGN_BOTTOM_MID, 0, -62)
    local layout = button(scr, "排版", show_reader_settings, state.cjk_font)
    L.lv_obj_set_size(layout, control_width, 42)
    L.lv_obj_set_pos(layout, control_gap * 3 + control_width * 2, control_y)
    local back = button(scr, "返回", close_reader, state.cjk_font)
    L.lv_obj_set_size(back, control_width, 42)
    L.lv_obj_set_pos(back, control_gap * 4 + control_width * 3, control_y)
    local nextb = button(scr, ">", function()
        handle_reader_action(session:next())
    end, state.cjk_font)
    L.lv_obj_set_size(nextb, control_width, 42)
    L.lv_obj_set_pos(nextb, control_gap * 5 + control_width * 4, control_y)
end

local function load_fail(message, can_return_to_reader)
    local scr = L.lv_screen_active()
    L.lv_obj_clean(scr)
    state.cbs = {}
    state.screen = "load_error"
    label(scr, tostring(message), state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, 0), lv.ALIGN_CENTER, 0, 0)
    if state.pending_open then
        local retry = button(scr, "重试", function()
            queue_chapter_open(state.pending_open)
        end, state.cjk_font)
        L.lv_obj_align(retry, lv.ALIGN_CENTER, -70, 60)
    end
    if can_return_to_reader and state.reader_session
        and state.reader_session.chapter_index then
        local resume = button(scr, "返回阅读", function()
            state.pending_open = nil
            state.screen = "reader"
            render_current_page()
        end, state.cjk_font)
        L.lv_obj_align(resume, lv.ALIGN_CENTER, 70, 60)
        return
    end
    button(scr, "返回书架", function()
        show_shelf()
    end, state.cjk_font)
    L.lv_obj_align(L.lv_obj_get_child(scr, -1), lv.ALIGN_CENTER, 0, 60)
end

local function load_tick()
    if state.screen ~= "loading" then
        return
    end
    local Canonical = require("weread.lib.canonical")
    local book = state.book
    if state.load_step == "catalog" then
        local ok, chapters, source_or_err = pcall(
            book_service.load_catalog, book_service, book)
        if not ok or not chapters then
            load_fail("目录加载失败："
                .. tostring(chapters or source_or_err))
            return
        end
        state.chapters = chapters
        if type(state.chapters) ~= "table" or #state.chapters == 0 then
            load_fail("这本书没有可读章节")
            return
        end
        state.reader_session = ReaderSession:new{ settings = app.settings }
        state.pending_open = state.reader_session:begin(book, state.chapters)
        state.load_step = "chapter"
    elseif state.load_step == "chapter" then
        state.load_step = "render"
        local ok, err = pcall(function()
            if state.external_path then
                state.chapter_path = state.external_path
                return
            end
            local cache_config = app.settings:get("cache")
            Canonical.ensure_chapter(
                app.client, app.settings, book, state.pending_open.chapter, {}, {
                    fetch_annotations =
                        cache_config.download_underlines_and_thoughts == true,
                })
            state.chapter_path = Canonical.reading_chapter_path(
                app.settings, book, state.pending_open.chapter, {
                    annotations = cache_config.show_annotations == true,
                })
        end)
        if not ok then
            load_fail("章节下载失败：" .. tostring(err),
                state.reader_session and state.reader_session.chapter_index ~= nil)
            return
        end
    elseif state.load_step == "render" then
        state.load_step = "done"
        local RB = require("reader_bridge")
        local layout = state.reader_session:layout()
        io.stderr:write("[load] RB.open ", tostring(state.chapter_path), "\n")
        local ok = RB.open(state.chapter_path, {
            width = WIDTH,
            height = READER_TEXT_H,
            font_size = layout.font_size,
            line_spacing = layout.line_spacing,
            margin = layout.margin,
            font_face = os.getenv("CR_FONT_FACE") or "Heiti SC",
        })
        io.stderr:write("[load] RB.open -> ", tostring(ok), "\n")
        if not ok then
            load_fail("章节无法打开（文件可能损坏）")
            return
        end
        state.reader_session:complete_open(state.pending_open, RB.page_count())
        foreground_time:enter(
            state.book.book_id or state.book.bookId)
        state.pending_open = nil
        state.prefetch_pending = true
        state.screen = "reader"
        render_current_page()
    end
end

-- Upload only time measured while the reader is actually in the foreground.
-- A server failure keeps the persisted seconds pending; retries are bounded
-- to one attempt per minute and never run from a page-turn callback.
local function read_report_tick()
    if not state.reader_session or not foreground_time.active then
        return
    end
    if state.external_path
        or Protocol.is_mp_book(state.book and (
            state.book.book_id or state.book.bookId)) then
        return
    end
    local config = app.settings:get("read_report")
    if not config.enabled then
        return
    end
    local current = app.now_ms() / 1000
    if current < (state.next_report_attempt or 0) then
        return
    end
    local elapsed = foreground_time:checkpoint(30)
    if not elapsed then
        return
    end
    state.next_report_attempt = current + 60
    local position = state.reader_session:remote_position()
    local book_id = state.book.book_id or state.book.bookId
    local called, accepted, outcome = pcall(
        read_report.upload_position, read_report,
        tostring(book_id), position, elapsed)
    if called and accepted then
        foreground_time:acknowledge(elapsed)
        state.last_report_status = string.format(
            "已上报 %d 秒前台阅读时长", elapsed)
        state.next_report_attempt = current + 30
    else
        local error_value = called and outcome or accepted
        state.last_report_status = "上报失败，保留时长稍后重试："
            .. utf8_prefix(type(error_value) == "table"
                and error_value.error or error_value, 40)
    end
end

-- Prefetch one chapter ahead after the current page is visible. The cache
-- operation may block on network, so it runs from the main tick rather than
-- from an LVGL event callback. Failures are intentionally silent and are not
-- retried in a loop; opening the chapter will still offer an explicit retry.
local function prefetch_tick()
    if state.screen ~= "reader" or not state.prefetch_pending
        or not state.reader_session then
        return
    end
    state.prefetch_pending = false
    local action = state.reader_session:prefetch_action()
    if not action then
        return
    end
    local Canonical = require("weread.lib.canonical")
    local cache_config = app.settings:get("cache")
    pcall(Canonical.ensure_chapter, app.client, app.settings,
        state.book, action.chapter, {}, {
            fetch_annotations =
                cache_config.download_underlines_and_thoughts == true,
        })
end

-- Kindle may freeze the process before Lua observes a suspend notification.
-- We combine powerd polling with a monotonic-gap fallback: the former records
-- the exact foreground boundary when possible, while the latter guarantees
-- sleep time is never reported as reading time after an unobserved freeze.
local function lifecycle_tick()
    local current = app.now_ms() / 1000
    if state.last_loop_at and current - state.last_loop_at > 5 then
        foreground_time:discard_unobserved_gap()
        if app.device and state.backend and state.backend.resume then
            pcall(state.backend.resume, state.backend)
            -- the fb may hold a screensaver/stale image; force a full
            -- LVGL re-render before flashing, or the user wakes to garbage
            L.lv_obj_invalidate(L.lv_screen_active())
            L.lv_refr_now(state.backend.display)
            if state.backend.full_refresh then
                pcall(state.backend.full_refresh, state.backend)
            end
        end
    end
    state.last_loop_at = current

    if not app.device or type(app.device.lifecycle_state) ~= "function"
        or current < state.next_power_poll then
        return
    end
    state.next_power_poll = current + 1
    local ok, power_state = pcall(
        app.device.lifecycle_state, app.device)
    if not ok or power_state == "unknown"
        or power_state == state.power_state then
        return
    end
    local previous = state.power_state
    state.power_state = power_state
    if power_state == "suspended" then
        foreground_time:suspend()
    elseif power_state == "active" and previous == "suspended" then
        foreground_time:resume()
        if state.backend and state.backend.resume then
            pcall(state.backend.resume, state.backend)
        end
        L.lv_obj_invalidate(L.lv_screen_active())
        L.lv_refr_now(state.backend.display)
        if state.backend and state.backend.full_refresh then
            pcall(state.backend.full_refresh, state.backend)
        end
    end
end

-- ------------------------------------------------------------------ main

local function main()
    L.lv_init()
    state.backend = UIBackend.create(lv, WIDTH, HEIGHT)
    WIDTH = state.backend.width
    HEIGHT = state.backend.height
    READER_TEXT_H = HEIGHT - 100
    do
        local scr = L.lv_screen_active()
        L.lv_obj_set_style_bg_color(scr, EINK_WHITE, 0)
        L.lv_obj_set_style_bg_opa(scr, 255, 0)
    end
    -- freetype is already initialized by lv_init (cache size is set in
    -- lv_conf.h via LV_FREETYPE_CACHE_FT_GLYPH_CNT)

    -- the crengine bridge needs its font manager initialized once before
    -- any document is opened (cr_open dereferences fontMan otherwise)
    local RB = require("reader_bridge")
    RB.init(os.getenv("CR_FONT_DIR") or "/tmp/cr-fonts")

    local font_path = os.getenv("CR_FONT_PATH")
        or "/System/Library/Fonts/STHeiti Medium.ttc"
    -- 300dpi e-ink needs ~1.5x the point sizes of a phone LCD
    state.cjk_font = L.lv_freetype_font_create(font_path, lv.FT_RENDER_MODE_NORMAL, 32, lv.FT_STYLE_NORMAL)
    state.cjk_font_big = L.lv_freetype_font_create(font_path, lv.FT_RENDER_MODE_NORMAL, 44, lv.FT_STYLE_NORMAL)

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
        lifecycle_tick()
        login_tick()
        shelf_tick()
        cover_tick()
        detail_tick()
        search_tick()
        progress_tick()
        stats_tick()
        mp_tick()
        task_tick()
        read_report_tick()
        prefetch_tick()
        load_tick()
        L.lv_tick_inc(FRAME_INTERVAL_MS)
        L.lv_timer_handler()
        ffi.C.usleep(FRAME_INTERVAL_MS * 1000)
        frames = frames + 1
        if SNAPSHOT_PATH and frames == 250 then
            local captured, capture_err =
                state.backend:screenshot(SNAPSHOT_PATH)
            if not captured then
                error("UI snapshot failed: " .. tostring(capture_err))
            end
        end
        if SELFTEST and frames > 300 then
            break
        end
    end
end

local ok, err = xpcall(main, debug.traceback)
if app and app.close then
    pcall(foreground_time.close, foreground_time)
    pcall(app.close, app)
end
if state.backend and state.backend.close then
    pcall(state.backend.close, state.backend)
end
if not ok then
    error(err, 0)
end

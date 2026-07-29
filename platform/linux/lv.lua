-- LuaJIT FFI binding for LVGL (v9, SDL backend) — the subset the Wereader
-- app needs: display, objects, labels, buttons, canvas, events, freetype.

local ffi = require("ffi")

ffi.cdef[[
typedef void lv_obj_t;
typedef void lv_display_t;
typedef void lv_indev_t;
typedef void lv_font_t;
typedef void lv_event_t;
typedef struct { uint8_t blue; uint8_t green; uint8_t red; } lv_color_t;
typedef void (*lv_event_cb_t)(lv_event_t * e);
typedef struct {
    uint32_t magic: 8;
    uint32_t cf: 8;
    uint32_t flags: 16;
    uint32_t w: 16;
    uint32_t h: 16;
    uint32_t stride: 16;
    uint32_t reserved_2: 16;
} lv_image_header_t;
typedef struct lv_draw_buf_t {
    lv_image_header_t header;
    uint32_t data_size;
    uint8_t * data;
    void * unaligned_data;
    const void * handlers;
} lv_draw_buf_t;

void lv_init(void);
lv_display_t * lv_sdl_window_create(int32_t hor_res, int32_t ver_res);
void * lv_sdl_window_get_renderer(lv_display_t * display);
lv_draw_buf_t * lv_snapshot_take(lv_obj_t * obj, int cf);
void lv_draw_buf_destroy(lv_draw_buf_t * draw_buf);
lv_indev_t * lv_sdl_keyboard_create(void);
lv_indev_t * lv_sdl_mouse_create(void);
void lv_tick_inc(uint32_t tick_period);
uint32_t lv_timer_handler(void);

lv_obj_t * lv_screen_active(void);
lv_obj_t * lv_obj_create(lv_obj_t * parent);
lv_obj_t * lv_label_create(lv_obj_t * parent);
lv_obj_t * lv_button_create(lv_obj_t * parent);
lv_obj_t * lv_canvas_create(lv_obj_t * parent);
lv_obj_t * lv_textarea_create(lv_obj_t * parent);
lv_obj_t * lv_keyboard_create(lv_obj_t * parent);
void lv_keyboard_set_textarea(lv_obj_t * keyboard, lv_obj_t * textarea);
void lv_textarea_set_text(lv_obj_t * ta, const char * txt);
void lv_textarea_set_max_length(lv_obj_t * ta, uint32_t num);
void lv_textarea_set_one_line(lv_obj_t * ta, bool en);
const char * lv_textarea_get_text(lv_obj_t * ta);

void lv_obj_set_pos(lv_obj_t * obj, int32_t x, int32_t y);
void lv_obj_set_size(lv_obj_t * obj, int32_t w, int32_t h);
void lv_obj_center(lv_obj_t * obj);
void lv_obj_align(lv_obj_t * obj, int align, int32_t x_ofs, int32_t y_ofs);
void lv_obj_clean(lv_obj_t * obj);
lv_obj_t * lv_obj_get_child(lv_obj_t * obj, int32_t idx);
void lv_obj_add_event_cb(lv_obj_t * obj, lv_event_cb_t cb, int32_t code, void * user_data);
int32_t lv_event_get_code(lv_event_t * e);
lv_obj_t * lv_event_get_target_obj(lv_event_t * e);
void * lv_event_get_user_data(lv_event_t * e);

void lv_label_set_text(lv_obj_t * obj, const char * text);
void lv_label_set_long_mode(lv_obj_t * obj, int mode);

void lv_canvas_set_buffer(lv_obj_t * canvas, void * buf, int32_t w, int32_t h, int cf);
void lv_obj_invalidate(lv_obj_t * obj);
void lv_refr_now(lv_display_t * disp);

void lv_obj_set_style_text_font(lv_obj_t * obj, const lv_font_t * font, int selector);
void lv_obj_set_style_border_width(lv_obj_t * obj, int32_t value, int selector);
void lv_obj_set_style_border_color(lv_obj_t * obj, lv_color_t color, int selector);
void lv_obj_set_style_border_opa(lv_obj_t * obj, int value, int selector);
void lv_obj_set_style_bg_opa(lv_obj_t * obj, int value, int selector);
void lv_obj_set_style_radius(lv_obj_t * obj, int32_t value, int selector);
void lv_obj_set_style_bg_color(lv_obj_t * obj, lv_color_t color, int selector);
void lv_obj_set_style_text_color(lv_obj_t * obj, lv_color_t color, int selector);
void lv_obj_set_style_text_align(lv_obj_t * obj, int align, int selector);
void lv_obj_set_flex_flow(lv_obj_t * obj, int flow);
void lv_obj_set_flex_align(lv_obj_t * obj, int main_place, int cross_place, int track_cross_place);
void lv_obj_add_flag(lv_obj_t * obj, int32_t flag);
void lv_obj_remove_flag(lv_obj_t * obj, int32_t flag);
void lv_obj_set_scrollbar_mode(lv_obj_t * obj, int mode);
void lv_obj_set_style_pad_top(lv_obj_t * obj, int32_t value, int selector);
void lv_obj_set_style_pad_bottom(lv_obj_t * obj, int32_t value, int selector);
void lv_obj_set_style_pad_left(lv_obj_t * obj, int32_t value, int selector);
void lv_obj_set_style_pad_right(lv_obj_t * obj, int32_t value, int selector);

int lv_freetype_init(uint32_t max_glyph_cnt);
lv_font_t * lv_freetype_font_create(const char * pathname, int render_mode, uint32_t size, int style);
]]

local lib_path = os.getenv("LVGL_PATH")
    or (ffi.os == "OSX"
        and "platform/linux/lvgl_build/build/liblvgl.dylib"
        or "platform/linux/lvgl_build/build/liblvgl.so")

local lv = {
    C = ffi.load(lib_path),
    -- event codes (subset of lv_event_code_t)
    EVENT_CLICKED = 7,
    EVENT_PRESSED = 1,
    EVENT_RELEASED = 8,
    -- align (subset of lv_align_t)
    ALIGN_CENTER = 9,
    ALIGN_TOP_MID = 2,
    ALIGN_BOTTOM_MID = 5,
    -- canvas color formats (lv_color_format_t)
    CANVAS_CF_L8 = 0x06,
    -- flex flow
    FLEX_FLOW_COLUMN = 1,
    FLEX_FLOW_ROW = 0,
    FLEX_ALIGN_CENTER = 2,
    FLEX_ALIGN_START = 0,
    FLEX_ALIGN_SPACE_BETWEEN = 5,
    -- freetype render mode / style
    FT_RENDER_MODE_NORMAL = 0,
    FT_STYLE_NORMAL = 0,
    FT_STYLE_BOLD = 2,
    -- lv_obj_flag_t subset
    FLAG_CLICKABLE = 2,        -- 1 << 1
    FLAG_SCROLLABLE = 16,      -- 1 << 4
    -- lv_scrollbar_mode_t
    SCROLLBAR_MODE_OFF = 0,
    -- lv_label_long_mode_t subset
    LABEL_LONG_WRAP = 0,
    LABEL_LONG_DOT = 1,
    -- lv_text_align_t subset
    TEXT_ALIGN_LEFT = 1,
    TEXT_ALIGN_CENTER = 2,
}

-- pad_all/pad_hor/pad_ver are static inline helpers in LVGL's headers (not
-- exported by the shared library), so compose them from the real symbols.
function lv.lv_obj_set_style_pad_all(obj, value, selector)
    lv.C.lv_obj_set_style_pad_top(obj, value, selector)
    lv.C.lv_obj_set_style_pad_bottom(obj, value, selector)
    lv.C.lv_obj_set_style_pad_left(obj, value, selector)
    lv.C.lv_obj_set_style_pad_right(obj, value, selector)
end

function lv.lv_obj_set_style_pad_hor(obj, value, selector)
    lv.C.lv_obj_set_style_pad_left(obj, value, selector)
    lv.C.lv_obj_set_style_pad_right(obj, value, selector)
end

function lv.lv_obj_set_style_pad_ver(obj, value, selector)
    lv.C.lv_obj_set_style_pad_top(obj, value, selector)
    lv.C.lv_obj_set_style_pad_bottom(obj, value, selector)
end

return lv

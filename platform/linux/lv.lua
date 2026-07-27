-- LuaJIT FFI binding for LVGL (v9, SDL backend) — the subset the Wereader
-- app needs: display, objects, labels, buttons, canvas, events, freetype.

local ffi = require("ffi")

ffi.cdef[[
typedef void lv_obj_t;
typedef void lv_display_t;
typedef void lv_indev_t;
typedef void lv_font_t;
typedef void lv_event_t;
typedef void (*lv_event_cb_t)(lv_event_t * e);

void lv_init(void);
lv_display_t * lv_sdl_window_create(int32_t hor_res, int32_t ver_res);
lv_indev_t * lv_sdl_keyboard_create(void);
lv_indev_t * lv_sdl_mouse_create(void);
void lv_tick_inc(uint32_t tick_period);
uint32_t lv_timer_handler(void);

lv_obj_t * lv_screen_active(void);
lv_obj_t * lv_obj_create(lv_obj_t * parent);
lv_obj_t * lv_label_create(lv_obj_t * parent);
lv_obj_t * lv_button_create(lv_obj_t * parent);
lv_obj_t * lv_canvas_create(lv_obj_t * parent);

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

void lv_obj_set_style_text_font(lv_obj_t * obj, const lv_font_t * font, int selector);
void lv_obj_set_style_bg_color(lv_obj_t * obj, uint32_t color, int selector);
void lv_obj_set_style_text_color(lv_obj_t * obj, uint32_t color, int selector);
void lv_obj_set_style_text_align(lv_obj_t * obj, int align, int selector);
void lv_obj_set_style_pad_all(lv_obj_t * obj, int32_t pad, int selector);
void lv_obj_set_flex_flow(lv_obj_t * obj, int flow);
void lv_obj_set_flex_align(lv_obj_t * obj, int main_place, int cross_place, int track_cross_place);

int lv_freetype_init(uint32_t max_glyph_cnt);
lv_font_t * lv_freetype_font_create(const char * pathname, int render_mode, uint32_t size, int style);
]]

local lib_path = os.getenv("LVGL_PATH")
    or "platform/linux/lvgl_build/build/liblvgl.dylib"

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
    FLEX_ALIGN_CENTER = 1,
    FLEX_ALIGN_START = 0,
    FLEX_ALIGN_SPACE_BETWEEN = 5,
    -- freetype render mode / style
    FT_RENDER_MODE_NORMAL = 0,
    FT_STYLE_NORMAL = 0,
    FT_STYLE_BOLD = 1,
}

return lv

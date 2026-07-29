#include "kindle_host.h"
#include <stdio.h>
#define DBG(...) do { fprintf(stderr, "[wk] " __VA_ARGS__); fflush(stderr); } while (0)

#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "fbink.h"
#include "lvgl.h"

#define WK_DRAW_LINES 64U
#define WK_AUTO_FULL_REFRESHES 12U
#define WK_EVENT_SCAN_LIMIT 32

typedef struct {
    int fd;
    int x_code;
    int y_code;
    int min_x;
    int max_x;
    int min_y;
    int max_y;
    int raw_x;
    int raw_y;
    int32_t width;
    int32_t height;
    bool pressed;
    bool swap_axes;
    bool mirror_x;
    bool mirror_y;
} wk_touch_t;

static int g_fbfd = -1;
static FBInkConfig g_fbink_cfg;
static FBInkState g_fbink_state;
static FBInkDump g_original_screen;
static bool g_original_screen_valid;
static lv_display_t *g_display;
static lv_indev_t *g_input;
static wk_touch_t *g_touch;
static uint8_t *g_draw_buffer;
static uint8_t *g_fbmem;
static size_t g_fbmem_size;
static uint32_t g_fb_stride;
static uint32_t g_dirty_left;
static uint32_t g_dirty_top;
static uint32_t g_dirty_right;
static uint32_t g_dirty_bottom;
static bool g_has_dirty;
static uint32_t g_partial_refreshes;
static char g_last_error[256];

// Blit LVGL pixels into the mapped framebuffer row by row. We cannot use
// fbink_print_raw_data here: it dumps the input contiguously, which skews
// whenever the LVGL area width (1072) differs from the fb stride (1088).
static void wk_blit_rows(const lv_area_t *area, const uint8_t *pixels,
                         int32_t width, int32_t height)
{
    if(g_fbmem == NULL) return;
    int32_t x = area->x1;
    int32_t y = area->y1;
    DBG("blit x=%d y=%d w=%d h=%d\n", (int)x, (int)y, (int)width, (int)height);
    if(x < 0 || y < 0) return;
    for(int32_t row = 0; row < height; row++) {
        uint8_t *dst = g_fbmem + (size_t)(y + row) * g_fb_stride + (size_t)x;
        const uint8_t *src = pixels + (size_t)row * (size_t)width;
        memcpy(dst, src, (size_t)width);
    }
}

static void wk_set_error(const char *message, int detail)
{
    if(detail == 0) {
        snprintf(g_last_error, sizeof(g_last_error), "%s", message);
    }
    else {
        snprintf(g_last_error, sizeof(g_last_error), "%s (%d)", message, detail);
    }
}

static bool wk_env_flag(const char *name, bool fallback)
{
    const char *value = getenv(name);
    if(value == NULL || value[0] == '\0') return fallback;
    if(strcmp(value, "1") == 0 || strcmp(value, "yes") == 0 || strcmp(value, "true") == 0) return true;
    if(strcmp(value, "0") == 0 || strcmp(value, "no") == 0 || strcmp(value, "false") == 0) return false;
    return fallback;
}

static int wk_scale_axis(int value, int minimum, int maximum, int extent)
{
    if(extent <= 1 || maximum <= minimum) return 0;
    int64_t numerator = (int64_t)(value - minimum) * (extent - 1);
    int mapped = (int)(numerator / (maximum - minimum));
    if(mapped < 0) return 0;
    if(mapped >= extent) return extent - 1;
    return mapped;
}

static bool wk_touch_axis_info(int fd, int *x_code, int *y_code,
                               struct input_absinfo *x_info,
                               struct input_absinfo *y_info)
{
    if(ioctl(fd, EVIOCGABS(ABS_MT_POSITION_X), x_info) == 0 &&
       ioctl(fd, EVIOCGABS(ABS_MT_POSITION_Y), y_info) == 0) {
        *x_code = ABS_MT_POSITION_X;
        *y_code = ABS_MT_POSITION_Y;
        return true;
    }
    if(ioctl(fd, EVIOCGABS(ABS_X), x_info) == 0 &&
       ioctl(fd, EVIOCGABS(ABS_Y), y_info) == 0) {
        *x_code = ABS_X;
        *y_code = ABS_Y;
        return true;
    }
    return false;
}

static bool wk_name_looks_like_touch(const char *name)
{
    char lowered[128];
    size_t length = strlen(name);
    if(length >= sizeof(lowered)) length = sizeof(lowered) - 1U;
    for(size_t i = 0; i < length; i++) {
        char c = name[i];
        lowered[i] = (c >= 'A' && c <= 'Z') ? (char)(c + ('a' - 'A')) : c;
    }
    lowered[length] = '\0';
    return strstr(lowered, "touch") != NULL ||
           strstr(lowered, "zforce") != NULL ||
           strstr(lowered, "gesture") != NULL ||
           strstr(lowered, "cyttsp") != NULL;
}

static int wk_open_touch_candidate(const char *path, bool require_touch_name,
                                   wk_touch_t *touch)
{
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if(fd < 0) return -1;

    char name[128] = { 0 };
    (void)ioctl(fd, EVIOCGNAME(sizeof(name) - 1U), name);
    if(require_touch_name && !wk_name_looks_like_touch(name)) {
        close(fd);
        return -1;
    }

    struct input_absinfo x_info = { 0 };
    struct input_absinfo y_info = { 0 };
    int x_code = 0;
    int y_code = 0;
    if(!wk_touch_axis_info(fd, &x_code, &y_code, &x_info, &y_info)) {
        close(fd);
        return -1;
    }

    touch->fd = fd;
    touch->x_code = x_code;
    touch->y_code = y_code;
    touch->min_x = x_info.minimum;
    touch->max_x = x_info.maximum;
    touch->min_y = y_info.minimum;
    touch->max_y = y_info.maximum;
    touch->raw_x = x_info.minimum;
    touch->raw_y = y_info.minimum;
    return 0;
}

static int wk_open_touch(const char *requested, wk_touch_t *touch)
{
    if(requested != NULL && requested[0] != '\0') {
        return wk_open_touch_candidate(requested, false, touch);
    }

    char path[64];
    for(int named_pass = 1; named_pass >= 0; named_pass--) {
        for(int index = 0; index < WK_EVENT_SCAN_LIMIT; index++) {
            snprintf(path, sizeof(path), "/dev/input/event%d", index);
            if(wk_open_touch_candidate(path, named_pass != 0, touch) == 0) return 0;
        }
    }
    return -1;
}

static void wk_touch_read(lv_indev_t *indev, lv_indev_data_t *data)
{
    wk_touch_t *touch = lv_indev_get_driver_data(indev);
    struct input_event event;
    ssize_t bytes;

    while((bytes = read(touch->fd, &event, sizeof(event))) == (ssize_t)sizeof(event)) {
        if(event.type == EV_ABS) {
            if(event.code == touch->x_code) touch->raw_x = event.value;
            else if(event.code == touch->y_code) touch->raw_y = event.value;
            else if(event.code == ABS_MT_TRACKING_ID) touch->pressed = event.value >= 0;
        }
        else if(event.type == EV_KEY && event.code == BTN_TOUCH) {
            touch->pressed = event.value != 0;
        }
    }

    int x = wk_scale_axis(touch->raw_x, touch->min_x, touch->max_x,
                          touch->swap_axes ? touch->height : touch->width);
    int y = wk_scale_axis(touch->raw_y, touch->min_y, touch->max_y,
                          touch->swap_axes ? touch->width : touch->height);
    if(touch->swap_axes) {
        int temporary = x;
        x = y;
        y = temporary;
    }
    if(touch->mirror_x) x = touch->width - 1 - x;
    if(touch->mirror_y) y = touch->height - 1 - y;

    data->point.x = x;
    data->point.y = y;
    data->state = touch->pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

static void wk_dirty_add(const lv_area_t *area)
{
    uint32_t left = area->x1 < 0 ? 0U : (uint32_t)area->x1;
    uint32_t top = area->y1 < 0 ? 0U : (uint32_t)area->y1;
    uint32_t right = area->x2 < 0 ? 0U : (uint32_t)area->x2;
    uint32_t bottom = area->y2 < 0 ? 0U : (uint32_t)area->y2;
    if(!g_has_dirty) {
        g_dirty_left = left;
        g_dirty_top = top;
        g_dirty_right = right;
        g_dirty_bottom = bottom;
        g_has_dirty = true;
        return;
    }
    if(left < g_dirty_left) g_dirty_left = left;
    if(top < g_dirty_top) g_dirty_top = top;
    if(right > g_dirty_right) g_dirty_right = right;
    if(bottom > g_dirty_bottom) g_dirty_bottom = bottom;
}

static void wk_flush(lv_display_t *display, const lv_area_t *area, uint8_t *pixels)
{
    int32_t width = lv_area_get_width(area);
    int32_t height = lv_area_get_height(area);

    wk_blit_rows(area, pixels, width, height);
    wk_dirty_add(area);

    if(lv_display_flush_is_last(display) && g_has_dirty) {
        FBInkConfig refresh_cfg = g_fbink_cfg;
        g_partial_refreshes++;
        int result;
        if(g_partial_refreshes >= WK_AUTO_FULL_REFRESHES) {
            refresh_cfg.is_flashing = true;
            result = fbink_refresh(g_fbfd, 0U, 0U, 0U, 0U, &refresh_cfg);
            g_partial_refreshes = 0U;
        }
        else {
            result = fbink_refresh(
                g_fbfd,
                g_dirty_top,
                g_dirty_left,
                g_dirty_right - g_dirty_left + 1U,
                g_dirty_bottom - g_dirty_top + 1U,
                &refresh_cfg);
        }
        DBG("refresh dirty t=%u l=%u r=%u b=%u ret=%d\n",
            g_dirty_top, g_dirty_left, g_dirty_right, g_dirty_bottom, result);
        if(result < 0) wk_set_error("FBInk refresh failed", result);
        g_has_dirty = false;
    }
    lv_display_flush_ready(display);
}

static void wk_release_input(void)
{
    if(g_input != NULL) {
        lv_indev_delete(g_input);
        g_input = NULL;
    }
    if(g_touch != NULL) {
        if(g_touch->fd >= 0) close(g_touch->fd);
        free(g_touch);
        g_touch = NULL;
    }
}

lv_display_t * wk_kindledisplay_create(
    const char *touch_device,
    int32_t *width,
    int32_t *height)
{
    if(g_display != NULL) {
        if(width != NULL) *width = (int32_t)g_fbink_state.screen_width;
        if(height != NULL) *height = (int32_t)g_fbink_state.screen_height;
        return g_display;
    }

    memset(&g_fbink_cfg, 0, sizeof(g_fbink_cfg));
    memset(&g_fbink_state, 0, sizeof(g_fbink_state));
    memset(&g_original_screen, 0, sizeof(g_original_screen));
    g_fbink_cfg.is_quiet = true;
    g_fbink_cfg.ignore_alpha = true;

    DBG("fbink_open\n");
    g_fbfd = fbink_open();
    if(g_fbfd < 0) {
        wk_set_error("unable to open framebuffer", g_fbfd);
        return NULL;
    }
    DBG("fbink_init\n");
    int result = fbink_init(g_fbfd, &g_fbink_cfg);
    if(result < 0) {
        wk_set_error("FBInk initialization failed", result);
        fbink_close(g_fbfd);
        g_fbfd = -1;
        return NULL;
    }
    DBG("get_state\n");
    fbink_get_state(&g_fbink_cfg, &g_fbink_state);
    DBG("state w=%u h=%u\n", g_fbink_state.screen_width, g_fbink_state.screen_height);
    if(g_fbink_state.screen_width == 0U || g_fbink_state.screen_height == 0U) {
        wk_set_error("FBInk returned an empty screen", 0);
        fbink_close(g_fbfd);
        g_fbfd = -1;
        return NULL;
    }

    // Map the framebuffer ourselves for the row-wise blit (fb stride can
    // differ from the visible width, which fbink_print_raw_data ignores).
    {
        int memfd = open("/dev/fb0", O_RDWR | O_CLOEXEC);
        if(memfd >= 0) {
            struct fb_fix_screeninfo finfo;
            if(ioctl(memfd, FBIOGET_FSCREENINFO, &finfo) == 0) {
                g_fbmem_size = finfo.smem_len;
                g_fb_stride = finfo.line_length;
                g_fbmem = mmap(NULL, g_fbmem_size, PROT_READ | PROT_WRITE,
                               MAP_SHARED, memfd, 0);
                if(g_fbmem == MAP_FAILED) g_fbmem = NULL;
            }
            close(memfd);
        }
        DBG("fbmem=%p stride=%u size=%zu\n", (void *)g_fbmem,
            g_fb_stride, g_fbmem_size);
    }

    DBG("dump\n");
    result = fbink_dump(g_fbfd, &g_original_screen);
    g_original_screen_valid = result == 0;

    DBG("lv_display_create\n");
    g_display = lv_display_create(
        (int32_t)g_fbink_state.screen_width,
        (int32_t)g_fbink_state.screen_height);
    if(g_display == NULL) {
        wk_set_error("LVGL display creation failed", 0);
        wk_kindledisplay_close();
        return NULL;
    }

    size_t draw_size = (size_t)g_fbink_state.screen_width * WK_DRAW_LINES;
    g_draw_buffer = malloc(draw_size);
    if(g_draw_buffer == NULL) {
        wk_set_error("LVGL draw buffer allocation failed", ENOMEM);
        wk_kindledisplay_close();
        return NULL;
    }
    DBG("draw buffer\n");
    memset(g_draw_buffer, 0xFF, draw_size);
    lv_display_set_color_format(g_display, LV_COLOR_FORMAT_L8);
    lv_display_set_buffers(
        g_display, g_draw_buffer, NULL, (uint32_t)draw_size,
        LV_DISPLAY_RENDER_MODE_PARTIAL);
    DBG("flush cb\n");
    lv_display_set_flush_cb(g_display, wk_flush);

    g_touch = calloc(1U, sizeof(*g_touch));
    if(g_touch != NULL) {
        g_touch->fd = -1;
        g_touch->width = (int32_t)g_fbink_state.screen_width;
        g_touch->height = (int32_t)g_fbink_state.screen_height;
        g_touch->swap_axes = wk_env_flag(
            "WEREADER_TOUCH_SWAP", g_fbink_state.touch_swap_axes);
        g_touch->mirror_x = wk_env_flag(
            "WEREADER_TOUCH_MIRROR_X", g_fbink_state.touch_mirror_x);
        g_touch->mirror_y = wk_env_flag(
            "WEREADER_TOUCH_MIRROR_Y", g_fbink_state.touch_mirror_y);
        if(wk_open_touch(touch_device, g_touch) == 0) {
            g_input = lv_indev_create();
            lv_indev_set_type(g_input, LV_INDEV_TYPE_POINTER);
            lv_indev_set_driver_data(g_input, g_touch);
            lv_indev_set_read_cb(g_input, wk_touch_read);
            lv_indev_set_display(g_input, g_display);
        }
        else {
            wk_set_error("touchscreen auto-detection failed", errno);
            free(g_touch);
            g_touch = NULL;
        }
    }

    if(width != NULL) *width = (int32_t)g_fbink_state.screen_width;
    if(height != NULL) *height = (int32_t)g_fbink_state.screen_height;
    return g_display;
}

int wk_kindledisplay_full_refresh(void)
{
    if(g_fbfd < 0) return -ENODEV;
    FBInkConfig cfg = g_fbink_cfg;
    cfg.is_flashing = true;
    int result = fbink_refresh(g_fbfd, 0U, 0U, 0U, 0U, &cfg);
    if(result < 0) wk_set_error("FBInk full refresh failed", result);
    else g_partial_refreshes = 0U;
    return result;
}

int wk_kindledisplay_reinit(void)
{
    if(g_fbfd < 0) return -ENODEV;
    int result = fbink_reinit(g_fbfd, &g_fbink_cfg);
    if(result < 0) wk_set_error("FBInk reinitialization failed", result);
    else fbink_get_state(&g_fbink_cfg, &g_fbink_state);
    return result;
}

int wk_kindledisplay_close(void)
{
    wk_release_input();
    if(g_display != NULL) {
        lv_display_delete(g_display);
        g_display = NULL;
    }
    free(g_draw_buffer);
    g_draw_buffer = NULL;

    int result = 0;
    if(g_fbfd >= 0 && g_original_screen_valid) {
        FBInkConfig restore_cfg = g_fbink_cfg;
        restore_cfg.is_flashing = true;
        result = fbink_restore(g_fbfd, &restore_cfg, &g_original_screen);
        (void)fbink_free_dump_data(&g_original_screen);
        g_original_screen_valid = false;
    }
    if(g_fbfd >= 0) {
        int close_result = fbink_close(g_fbfd);
        if(result == 0) result = close_result;
        g_fbfd = -1;
    }
    g_has_dirty = false;
    g_partial_refreshes = 0U;
    return result;
}

const char * wk_kindledisplay_last_error(void)
{
    return g_last_error;
}

const char * wk_kindledisplay_fbink_version(void)
{
    return fbink_version();
}

#ifndef WK_NO_JPEG

#include <setjmp.h>
#include <jpeglib.h>

typedef struct {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
} wk_jpeg_err_t;

static void wk_jpeg_error_exit(j_common_ptr cinfo)
{
    wk_jpeg_err_t *err = (wk_jpeg_err_t *)cinfo->err;
    longjmp(err->jump, 1);
}

int wk_jpeg_decode_gray(
    const uint8_t *data, uint32_t len,
    uint8_t *out, int32_t max_w, int32_t max_h,
    int32_t *out_w, int32_t *out_h)
{
    struct jpeg_decompress_struct cinfo;
    wk_jpeg_err_t jerr;

    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = wk_jpeg_error_exit;
    if(setjmp(jerr.jump)) {
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, data, (unsigned long)len);
    (void)jpeg_read_header(&cinfo, TRUE);
    cinfo.out_color_space = JCS_GRAYSCALE;

    // libjpeg scales by m/8 for m in 1..16. m=8 is 1:1 (never upscale);
    // walk down from 1:1 and keep the first factor that fits the box.
    bool fits = false;
    for(unsigned int m = 8; m >= 1; m--) {
        cinfo.scale_num = m;
        cinfo.scale_denom = 8;
        jpeg_calc_output_dimensions(&cinfo);
        if((int32_t)cinfo.output_width <= max_w &&
           (int32_t)cinfo.output_height <= max_h) {
            fits = true;
            break;
        }
    }
    if(!fits) {
        jpeg_destroy_decompress(&cinfo);
        return -2;
    }

    (void)jpeg_start_decompress(&cinfo);
    size_t stride = (size_t)cinfo.output_width * (size_t)cinfo.output_components;
    while(cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW row = out + (size_t)cinfo.output_scanline * stride;
        (void)jpeg_read_scanlines(&cinfo, &row, 1);
    }
    *out_w = (int32_t)cinfo.output_width;
    *out_h = (int32_t)cinfo.output_height;
    (void)jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    return 0;
}

#else

int wk_jpeg_decode_gray(
    const uint8_t *data, uint32_t len,
    uint8_t *out, int32_t max_w, int32_t max_h,
    int32_t *out_w, int32_t *out_h)
{
    (void)data; (void)len; (void)out; (void)max_w; (void)max_h;
    (void)out_w; (void)out_h;
    return -3;
}

#endif

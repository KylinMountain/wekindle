#ifndef WEREADER_KINDLE_HOST_H
#define WEREADER_KINDLE_HOST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lv_display_t lv_display_t;

/*
 * Create an LVGL L8 display backed by FBInk and an optional evdev pointer.
 * touch_device may be NULL/empty to auto-detect /dev/input/event*.
 */
lv_display_t * wk_kindledisplay_create(
    const char *touch_device,
    int32_t *width,
    int32_t *height);

/* Request an immediate flashing full-screen refresh. */
int wk_kindledisplay_full_refresh(void);

/* Re-read framebuffer state after wake/rotation. */
int wk_kindledisplay_reinit(void);

/* Restore the framebuffer captured before create() and release resources. */
int wk_kindledisplay_close(void);

const char * wk_kindledisplay_last_error(void);
const char * wk_kindledisplay_fbink_version(void);

/*
 * Decode a JPEG to 8-bit grayscale, scaled down (libjpeg m/8 factors, never
 * upscaled) to fit max_w x max_h while keeping aspect. `out` must hold at
 * least max_w * max_h bytes. On success writes the decoded dimensions to
 * out_w/out_h and returns 0. Returns -1 on corrupt input, -2 when even the
 * smallest supported scale does not fit, -3 when built without JPEG support.
 */
int wk_jpeg_decode_gray(
    const uint8_t *data, uint32_t len,
    uint8_t *out, int32_t max_w, int32_t max_h,
    int32_t *out_w, int32_t *out_h);

#ifdef __cplusplus
}
#endif

#endif

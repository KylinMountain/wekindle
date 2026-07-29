/* UI-startup-only crengine ABI stub. Reader integration uses the real bridge. */
#include <stddef.h>

int cr_init(const char *font_dir) { return font_dir ? 1 : 0; }
int cr_open(const char *path, int width, int height, int font_size,
            const char *font_face) {
    (void)path; (void)width; (void)height; (void)font_size; (void)font_face;
    return 0;
}
int cr_open_layout(const char *path, int width, int height, int font_size,
                   int line_spacing, int margin, const char *font_face) {
    (void)line_spacing; (void)margin;
    return cr_open(path, width, height, font_size, font_face);
}
int cr_page_count(void) { return 0; }
int cr_page_text(int page, char *buf, int buf_len) {
    (void)page; (void)buf; (void)buf_len; return -1;
}
int cr_render_page(int page, unsigned char *gray_buf, int width, int height) {
    (void)page; (void)gray_buf; (void)width; (void)height; return 0;
}
void cr_close(void) {}

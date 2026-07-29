// Debug harness for the crengine bridge: exercises cr_* functions directly.
#include <cstdio>
#include <csignal>
#include <execinfo.h>
#include <unistd.h>

static void crash_handler(int sig) {
    void *frames[64];
    int n = backtrace(frames, 64);
    fprintf(stderr, "\n[crash] signal %d\n", sig);
    backtrace_symbols_fd(frames, n, STDERR_FILENO);
    _exit(128 + sig);
}

extern "C" {
int cr_init(const char *font_dir);
int cr_open(const char *path, int width, int height, int font_size, const char *font_face);
int cr_page_count(void);
int cr_page_text(int page, char *buf, int buf_len);
int cr_render_page(int page, unsigned char *gray_buf, int width, int height);
void cr_close(void);
}

int main(int argc, char **argv) {
    signal(SIGSEGV, crash_handler);
    signal(SIGBUS, crash_handler);
    signal(SIGABRT, crash_handler);
    const char *font_dir = argc > 1 ? argv[1] : "/tmp/cr-fonts";
    const char *doc = argc > 2 ? argv[2] : "/tmp/test-chapter.xhtml";
    fprintf(stderr, "[t] init\n");
    int fonts = cr_init(font_dir);
    fprintf(stderr, "[t] fonts: %d\n", fonts);
    fprintf(stderr, "[t] open\n");
    int ok = cr_open(doc, 600, 800, 28, nullptr);
    fprintf(stderr, "[t] open: %d\n", ok);
    if (!ok) return 1;
    fprintf(stderr, "[t] pages: %d\n", cr_page_count());
    int len = cr_page_text(1, nullptr, 0);
    fprintf(stderr, "[t] page1 text len: %d\n", len);
    char *buf = new char[len + 1];
    cr_page_text(1, buf, len + 1);
    fprintf(stderr, "[t] page1: %.100s\n", buf);
    delete[] buf;
    static unsigned char gray[600 * 800];
    int r = cr_render_page(1, gray, 600, 800);
    fprintf(stderr, "[t] render: %d\n", r);
    cr_close();
    fprintf(stderr, "[t] done\n");
    return 0;
}

// C bridge over crengine's LVDocView, exposing the subset of functionality
// weread-core's IReaderEngine port needs (see core/contracts/ports.md).
// Called from LuaJIT FFI; all strings are UTF-8.

#include "lvdocview.h"
#include "lvstream.h"
#include "lvdrawbuf.h"
#include "crsetup.h"
#include "lvfntman.h"

#include <cstring>
#include <cstdio>
#include <cstdlib>

#ifdef WEREADER_CRASH_HANDLER
#include <csignal>
#include <cstddef>
#include <execinfo.h>
#include <unistd.h>
#include <ucontext.h>
static void cr_crash_handler(int sig, siginfo_t *info, void *uctx) {
    ucontext_t *uc = (ucontext_t *)uctx;
    void *frames[48];
    int n = backtrace(frames, 48);
    fprintf(stderr,
        "\n[crbridge] signal %d fault_addr=%p pc=%p lr=%p, backtrace:\n",
        sig, info ? info->si_addr : nullptr,
        (void *)uc->uc_mcontext.arm_pc, (void *)uc->uc_mcontext.arm_lr);
    backtrace_symbols_fd(frames, n, STDERR_FILENO);
    fsync(STDERR_FILENO);
    signal(sig, SIG_DFL);
    raise(sig);  // re-raise so the core dump still happens
}
#endif

extern "C" {

struct CrDoc {
    LVDocView *view;
    int width;
    int height;
};

static CrDoc *g_doc = nullptr;  // single-document PoC; the app serializes access

void cr_close(void);

// Initialize the engine once: every font file in font_dir is registered so
// CJK-capable fonts are available. Returns the registered font count.
int cr_init(const char *font_dir) {
#ifdef WEREADER_CRASH_HANDLER
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = cr_crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigaction(SIGSEGV, &sa, nullptr);
    sigaction(SIGBUS, &sa, nullptr);
    sigaction(SIGABRT, &sa, nullptr);
#endif
    InitFontManager(lString8());
    LVContainerRef dir = LVOpenDirectory(lString8(font_dir), U"*.*");
    if (!dir.isNull()) {
        for (int i = 0; i < dir->GetObjectCount(); i++) {
            const LVContainerItemInfo *item = dir->GetObjectInfo(i);
            if (!item->IsContainer()) {
                lString8 name = UnicodeToUtf8(lString32(item->GetName()));
                lString8 lower = name;
                lower.lowercase();
                if (lower.endsWith(".ttf") || lower.endsWith(".otf") || lower.endsWith(".ttc")) {
                    lString8 full = lString8(font_dir);
                    full.append("/");
                    full.append(name);
                    fontMan->RegisterFont(full);
                }
            }
        }
    }
    return fontMan->GetFontCount();
}

int cr_open_layout(const char *path, int width, int height, int font_size,
                   int line_spacing, int margin, const char *font_face) {
    cr_close();
    fprintf(stderr, "[crb] new LVDocView\n");
    CrDoc *doc = new CrDoc();
    doc->view = new LVDocView(32, true);  // noDefaultDocument
    doc->width = width;
    doc->height = height;
    doc->view->setFontSize(font_size);
    fprintf(stderr, "[crb] LoadDocument %s\n", path);
    if (!doc->view->LoadDocument(path)) {
        delete doc->view;
        delete doc;
        return 0;
    }
    fprintf(stderr, "[crb] setters\n");
    doc->view->setFontSize(font_size);
    if (line_spacing < 90) line_spacing = 90;
    if (line_spacing > 180) line_spacing = 180;
    doc->view->setDefaultInterlineSpace(line_spacing);
    if (margin < 0) margin = 0;
    if (margin > width / 3) margin = width / 3;
    if (margin > height / 3) margin = height / 3;
    doc->view->setPageMargins(lvRect(margin, margin, margin, margin));
    doc->view->setViewMode(DVM_PAGES, 1);
    if (font_face && font_face[0]) {
        doc->view->setDefaultFontFace(lString8(font_face));
        // Route every font lookup for missing glyphs through the CJK font,
        // otherwise headings/styles that request other families render "?".
        fontMan->SetFallbackFontFaces(lString8(font_face));
    }
    fprintf(stderr, "[crb] Render %dx%d\n", width, height);
    doc->view->Render(width, height);
    fprintf(stderr, "[crb] done\n");
    g_doc = doc;
    return 1;
}

int cr_open(const char *path, int width, int height, int font_size, const char *font_face) {
    return cr_open_layout(path, width, height, font_size, 120, 24, font_face);
}

int cr_page_count(void) {
    return g_doc ? g_doc->view->getPageCount() : 0;
}

// Text content of one page (1-based page index). Returns bytes written
// (excluding NUL), -1 on error, -2 on out-of-range page. buf may be null
// to query the size.
int cr_page_text(int page, char *buf, int buf_len) {
    if (!g_doc) {
        return -1;
    }
    if (page < 1 || page > g_doc->view->getPageCount()) {
        return -2;
    }
    lString32 text = g_doc->view->getPageText(false, page - 1);
    lString8 utf8 = UnicodeToUtf8(text);
    int len = (int)utf8.length();
    if (!buf) {
        return len;
    }
    if (buf_len <= 0) {
        return -1;
    }
    int copy = len < buf_len - 1 ? len : buf_len - 1;
    if (copy > 0) {
        memcpy(buf, utf8.c_str(), copy);
    }
    buf[copy] = 0;
    return copy;
}

// Render one page (1-based) into an 8-bit grayscale buffer (width*height
// bytes, row-major). Returns 1 on success.
int cr_render_page(int page, unsigned char *gray_buf, int width, int height) {
    if (!g_doc || !gray_buf) {
        return 0;
    }
    if (width != g_doc->width || height != g_doc->height) {
        g_doc->view->Render(width, height);
        g_doc->width = width;
        g_doc->height = height;
    }
    LVGrayDrawBuf drawbuf(width, height, 8);
    drawbuf.Clear(0xFF);
    g_doc->view->Draw(drawbuf, 0, page - 1, false, false);
    for (int y = 0; y < height; y++) {
        memcpy(gray_buf + y * width, drawbuf.GetScanLine(y), width);
    }
    return 1;
}

// Switch to single-page mode (default renders two pages side by side).
void cr_set_single_page(void) {
    if (g_doc) {
        g_doc->view->setViewMode(DVM_PAGES, 1);
        g_doc->view->Render(g_doc->width, g_doc->height);
    }
}

// Set the default font face for body text (must be a registered face name,
// e.g. a CJK-capable font so headings don't fall back to "?").
void cr_set_default_font_face(const char *face) {
    if (g_doc) {
        g_doc->view->setDefaultFontFace(lString8(face));
        g_doc->view->Render(g_doc->width, g_doc->height);
    }
}

// Debug: dump current view state to stderr.
void cr_debug_state(void) {
    if (g_doc) {
        fprintf(stderr, "[cr] view_mode=%d visible_pages=%d page_count=%d dx=%d dy=%d\n",
                (int)g_doc->view->getViewMode(),
                (int)g_doc->view->getVisiblePageCount(),
                g_doc->view->getPageCount(),
                0, 0);
    }
}

void cr_close(void) {
    if (g_doc) {
        delete g_doc->view;
        delete g_doc;
        g_doc = nullptr;
    }
}

}

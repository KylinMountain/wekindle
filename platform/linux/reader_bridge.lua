-- LuaJIT FFI binding for the crengine bridge (libcrbridge).
-- Implements the IReaderEngine subset: init/open/page_count/page_text/
-- render_page/close (see core/contracts/ports.md).

local ffi = require("ffi")

ffi.cdef[[
int cr_init(const char *font_dir);
int cr_open(const char *path, int width, int height, int font_size, const char *font_face);
int cr_open_layout(const char *path, int width, int height, int font_size,
    int line_spacing, int margin, const char *font_face);
int cr_page_count(void);
int cr_page_text(int page, char *buf, int buf_len);
int cr_render_page(int page, unsigned char *gray_buf, int width, int height);
void cr_set_single_page(void);
void cr_set_default_font_face(const char *face);
void cr_close(void);
]]

local ReaderBridge = {}

local lib_path = arg and arg.crbridge_path
    or os.getenv("CRBRIDGE_PATH")
    or (ffi.os == "OSX"
        and "reader/crengine_bridge/build/libcrbridge.dylib"
        or "reader/crengine_bridge/build/libcrbridge.so")

local lib = ffi.load(lib_path)

function ReaderBridge.init(font_dir)
    return lib.cr_init(font_dir)
end

function ReaderBridge.open(path, opts)
    opts = opts or {}
    return lib.cr_open_layout(path,
        opts.width or 600,
        opts.height or 800,
        opts.font_size or 26,
        opts.line_spacing or 120,
        opts.margin or 24,
        opts.font_face) == 1
end

function ReaderBridge.page_count()
    return lib.cr_page_count()
end

function ReaderBridge.page_text(page)
    local len = lib.cr_page_text(page, nil, 0)
    if len < 0 then
        return nil
    end
    local buf = ffi.new("char[?]", len + 1)
    lib.cr_page_text(page, buf, len + 1)
    return ffi.string(buf)
end

-- Renders a page into a grayscale buffer; returns the buffer (ffi cdata).
function ReaderBridge.render_page(page, width, height)
    local buf = ffi.new("unsigned char[?]", width * height)
    if lib.cr_render_page(page, buf, width, height) == 1 then
        return buf, width, height
    end
    return nil
end

-- Write a grayscale buffer as PGM (trivial debug format).
function ReaderBridge.write_pgm(buf, width, height, path)
    local file = assert(io.open(path, "wb"))
    file:write("P5\n" .. width .. " " .. height .. "\n255\n")
    file:write(ffi.string(buf, width * height))
    file:close()
    return path
end

function ReaderBridge.close()
    lib.cr_close()
end

return ReaderBridge

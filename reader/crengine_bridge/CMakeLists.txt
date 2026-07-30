cmake_minimum_required(VERSION 3.20)
project(crbridge CXX C)

set(CMAKE_CXX_STANDARD 17)

get_filename_component(WEREADER_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(CRE_DIR "${WEREADER_ROOT}/third_party/src/koreader-crengine/crengine")
set(TP_DIR "${WEREADER_ROOT}/third_party/src/coolreader/thirdparty_unman")

# KOReader's crengine fork, minus the stale GUI files (crgui/crskin
# reference LVDrawBuf::DrawTo, which this fork removed).
set(CRE_SOURCES
    src/cp_stats.cpp
    src/lvstring.cpp
    src/props.cpp
    src/lstridmap.cpp
    src/rtfimp.cpp
    src/cri18n.cpp
    src/lvmemman.cpp
    src/lvstyles.cpp
    src/crtxtenc.cpp
    src/lvtinydom.cpp
    src/lvstream.cpp
    src/lvxml.cpp
    src/lvstsheet.cpp
    src/txtselector.cpp
    src/crtest.cpp
    src/lvbmpbuf.cpp
    src/lvfnt.cpp
    src/hyphman.cpp
    src/lvfntman.cpp
    src/lvimg.cpp
    src/lvdrawbuf.cpp
    src/lvdocview.cpp
    src/lvpagesplitter.cpp
    src/lvtextfm.cpp
    src/lvrend.cpp
    src/wolutil.cpp
    src/hist.cpp
    src/chmfmt.cpp
    src/epubfmt.cpp
    src/pdbfmt.cpp
    src/wordfmt.cpp
    src/fb3fmt.cpp
    src/docxfmt.cpp
    src/odtfmt.cpp
    src/renderutil.cpp
    src/lvopc.cpp
    src/mathml.cpp
    src/textlang.cpp
    src/odxutil.cpp
    qimagescale/qimagescale.cpp
    # crconcurrent.cpp excluded: this fork ships no-op crlocks (KOReader
    # does not build it either); the bridge is single-threaded.
)
list(TRANSFORM CRE_SOURCES PREPEND "${CRE_DIR}/")

# CR3_ANTIWORD_PATCH=1 is REQUIRED (koreader-crengine/CMakeLists.txt:221 does
# the same): without it, antiword.h maps aw_rewind/aw_getc onto libc
# rewind/getc, wordfmt.cpp's wrapper gets exported as a plain "rewind"
# symbol, and whether antiword's format sniffers hit the wrapper or real
# libc rewind depends on ELF load order. When libcrbridge is dlopen'd after
# libc (the app, via LuaJIT FFI) the sniffers call libc rewind() on the fake
# AntiwordStreamGuard FILE* — heap garbage as a FILE — and crash (arm32).
# With the macro, aw_rewind/aw_getc stay unique names that always resolve
# to the wrappers regardless of load order.
add_definitions(-DCR3_ANTIWORD_PATCH=1)

add_library(crbridge SHARED cr_bridge.cpp ${CRE_SOURCES})
add_executable(cr_test cr_test.cpp)
target_link_libraries(cr_test PRIVATE crbridge)
if(WEREADER_KINDLE_DEPS_INC)
    target_include_directories(cr_test PRIVATE ${WEREADER_KINDLE_DEPS_INC})
endif()

set(NS_DIR "${TP_DIR}/nanosvg/src")

# Kindle cross-build: device-pulled KOReader libs + source headers, no
# pkg-config. Activated by -DWEREADER_KINDLE_LIBS=<dir> and
# -DWEREADER_KINDLE_DEPS_INC=<dir1;dir2;...>
if(WEREADER_KINDLE_LIBS)
    target_include_directories(crbridge PRIVATE
        "${CRE_DIR}/include"
        "${NS_DIR}"
        "${TP_DIR}/antiword"
        "${TP_DIR}/chmlib/src"
        ${WEREADER_KINDLE_DEPS_INC}
    )
    target_compile_definitions(crbridge PRIVATE
        _LINUX
        USE_FREETYPE=1
        USE_HARFBUZZ=1
        USE_FRIBIDI=1
        USE_LIBUNIBREAK=1
        USE_ZSTD=1
        USE_NANOSVG=1
        USE_FONTCONFIG=0
        COLOR_BACKBUFFER=1
        LDOM_USE_OWN_MEM_MAN=1
        NDEBUG=1
    )
    target_compile_options(crbridge PRIVATE -O2 -include sys/time.h)
    target_link_directories(crbridge PRIVATE "${WEREADER_KINDLE_LIBS}")
    target_link_libraries(crbridge PRIVATE
        "${TP_DIR}/antiword/build/libantiword.a"
        "${TP_DIR}/chmlib/build/libchmlib.a"
        freetype
        harfbuzz
        fribidi
        png16
        jpeg
        z
        zstd
        unibreak
        xxhash
    )
    return()
endif()

target_include_directories(crbridge PRIVATE
    "${CRE_DIR}/include"
    "${NS_DIR}"
    "${TP_DIR}/antiword"
    "${TP_DIR}/chmlib/src"
)

target_compile_definitions(crbridge PRIVATE
    _LINUX
    USE_FREETYPE=1
    USE_HARFBUZZ=1
    USE_FRIBIDI=1
    USE_LIBUNIBREAK=1
    USE_ZSTD=1
    USE_NANOSVG=1
    USE_FONTCONFIG=1
    COLOR_BACKBUFFER=1
    LDOM_USE_OWN_MEM_MAN=1
    NDEBUG=1
)
target_compile_options(crbridge PRIVATE -O2 -include sys/time.h)

find_package(PkgConfig REQUIRED)
pkg_check_modules(FREETYPE REQUIRED IMPORTED_TARGET freetype2)
pkg_check_modules(HARFBUZZ REQUIRED IMPORTED_TARGET harfbuzz)
pkg_check_modules(FRIBIDI REQUIRED IMPORTED_TARGET fribidi)
pkg_check_modules(PNG REQUIRED IMPORTED_TARGET libpng)
pkg_check_modules(JPEG REQUIRED IMPORTED_TARGET libjpeg)
pkg_check_modules(ZSTD REQUIRED IMPORTED_TARGET libzstd)
pkg_check_modules(UNIBREAK REQUIRED IMPORTED_TARGET libunibreak)
pkg_check_modules(FONTCONFIG REQUIRED IMPORTED_TARGET fontconfig)
pkg_check_modules(XXHASH REQUIRED IMPORTED_TARGET libxxhash)
find_package(ZLIB REQUIRED)
find_library(INTL_LIBRARY intl)

target_link_libraries(crbridge PRIVATE
    "${TP_DIR}/antiword/build/libantiword.a"
    "${TP_DIR}/chmlib/build/libchmlib.a"
    PkgConfig::FREETYPE
    PkgConfig::HARFBUZZ
    PkgConfig::FRIBIDI
    PkgConfig::PNG
    PkgConfig::JPEG
    PkgConfig::ZSTD
    PkgConfig::UNIBREAK
    PkgConfig::FONTCONFIG
    PkgConfig::XXHASH
    ZLIB::ZLIB
)
if(INTL_LIBRARY)
    target_link_libraries(crbridge PRIVATE "${INTL_LIBRARY}")
endif()

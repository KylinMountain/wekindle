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

add_library(crbridge SHARED cr_bridge.cpp ${CRE_SOURCES})

set(HB /opt/homebrew/opt)
set(NS_DIR "${TP_DIR}/nanosvg/src")
target_include_directories(crbridge PRIVATE
    "${CRE_DIR}/include"
    "${NS_DIR}"
    "${TP_DIR}/antiword"
    "${TP_DIR}/chmlib/src"
    "${HB}/gettext/include"
    "${HB}/harfbuzz/include/harfbuzz"
    "${HB}/fribidi/include/fribidi"
    "${HB}/fribidi/include"
    "${HB}/freetype/include/freetype2"
    "${HB}/libpng/include"
    "${HB}/jpeg-turbo/include"
    "${HB}/libunibreak/include"
    "${HB}/zstd/include"
    "${HB}/fontconfig/include"
    "${HB}/xxhash/include"
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

target_link_directories(crbridge PRIVATE
    "${HB}/gettext/lib"
    "${HB}/harfbuzz/lib"
    "${HB}/fribidi/lib"
    "${HB}/freetype/lib"
    "${HB}/libpng/lib"
    "${HB}/jpeg-turbo/lib"
    "${HB}/libunibreak/lib"
    "${HB}/zstd/lib"
    "${HB}/fontconfig/lib"
    "${HB}/xxhash/lib"
)

target_link_libraries(crbridge PRIVATE
    "${TP_DIR}/antiword/build/libantiword.a"
    "${TP_DIR}/chmlib/build/libchmlib.a"
    freetype
    harfbuzz
    fribidi
    png
    jpeg
    z
    zstd
    unibreak
    intl
    fontconfig
    xxhash
)

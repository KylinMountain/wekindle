cmake_minimum_required(VERSION 3.20)
project(wereader_kindle_host C)

set(LVGL_SOURCE_DIR "" CACHE PATH "Pinned LVGL source directory")
set(FBINK_SOURCE_DIR "" CACHE PATH "Pinned FBInk source directory")
set(FBINK_LIBRARY "" CACHE FILEPATH "Built libfbink shared/static library")

if(NOT EXISTS "${LVGL_SOURCE_DIR}/src/lv_init.h")
    message(FATAL_ERROR "LVGL_SOURCE_DIR must point at the pinned LVGL checkout")
endif()
if(NOT EXISTS "${FBINK_SOURCE_DIR}/fbink.h")
    message(FATAL_ERROR "FBINK_SOURCE_DIR must point at the pinned FBInk checkout")
endif()
if(NOT EXISTS "${FBINK_LIBRARY}")
    message(FATAL_ERROR "FBINK_LIBRARY does not exist: ${FBINK_LIBRARY}")
endif()

file(GLOB_RECURSE LVGL_SOURCES "${LVGL_SOURCE_DIR}/src/*.c")

add_library(lvgl SHARED ${LVGL_SOURCES})
target_include_directories(lvgl PUBLIC
    "${LVGL_SOURCE_DIR}"
    "${LVGL_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_definitions(lvgl PUBLIC LV_CONF_INCLUDE_SIMPLE)

find_package(Freetype REQUIRED)
target_link_libraries(lvgl PUBLIC Freetype::Freetype m)

add_library(wereader_kindledisplay SHARED kindle_host.c)
target_include_directories(wereader_kindledisplay PRIVATE
    "${LVGL_SOURCE_DIR}"
    "${LVGL_SOURCE_DIR}/src"
    "${FBINK_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_definitions(wereader_kindledisplay PRIVATE LV_CONF_INCLUDE_SIMPLE)
target_link_libraries(wereader_kindledisplay PRIVATE lvgl "${FBINK_LIBRARY}")

# Optional JPEG decoding for shelf covers (libjpeg-turbo from the KOReader
# sysroot on device builds). Without it covers fall back to text placeholders.
set(WEREADER_JPEG_INCLUDE "" CACHE PATH "libjpeg header directory")
set(WEREADER_JPEG_LIBRARY "" CACHE FILEPATH "libjpeg shared library")
if(WEREADER_JPEG_INCLUDE AND WEREADER_JPEG_LIBRARY)
    target_include_directories(wereader_kindledisplay PRIVATE "${WEREADER_JPEG_INCLUDE}")
    target_link_libraries(wereader_kindledisplay PRIVATE "${WEREADER_JPEG_LIBRARY}")
else()
    target_compile_definitions(wereader_kindledisplay PRIVATE WK_NO_JPEG=1)
endif()

set_target_properties(lvgl wereader_kindledisplay PROPERTIES
    BUILD_RPATH "$ORIGIN"
    INSTALL_RPATH "$ORIGIN"
)

cmake_minimum_required(VERSION 3.20)
project(lvgl_sdl C)

# Build LVGL v9 (SDL2 backend) as a static library for the standalone app.
# lv_conf.h lives in this directory.

get_filename_component(LVGL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/src/lvgl" ABSOLUTE)

file(GLOB_RECURSE LVGL_SOURCES
    "${LVGL_DIR}/src/*.c"
)

add_library(lvgl SHARED ${LVGL_SOURCES})
target_include_directories(lvgl PUBLIC
    "${LVGL_DIR}"
    "${LVGL_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_definitions(lvgl PUBLIC LV_CONF_INCLUDE_SIMPLE)

find_package(SDL2 REQUIRED)
target_include_directories(lvgl PRIVATE ${SDL2_INCLUDE_DIRS})
target_link_libraries(lvgl PUBLIC ${SDL2_LIBRARIES})

target_include_directories(lvgl PRIVATE /opt/homebrew/opt/freetype/include/freetype2)
target_link_directories(lvgl PUBLIC /opt/homebrew/opt/freetype/lib)
target_link_libraries(lvgl PUBLIC freetype)

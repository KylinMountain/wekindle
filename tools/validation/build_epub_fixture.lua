#!/usr/bin/env luajit
-- Build a deterministic, image-bearing EPUB used by CI conformance checks.

local root = arg[0]:match("^(.*)/tools/validation/") or "."
package.path = root .. "/core/lua/?.lua;"
    .. root .. "/platform/standalone/?.lua;"
    .. root .. "/third_party/?.lua;" .. package.path

local Content = require("weread.lib.content")
local ZipWriter = require("zip_writer")
Content.set_zip_writer_factory(function() return ZipWriter:new() end)

local output = arg[1] or "/tmp/wereader-validation.epub"
local book = {
    book_id = "validation-book",
    title = "Wereader EPUB 验证样本",
    author = "Wereader",
}
local chapters = {
    { chapterUid = "one", title = "第一章", level = 1 },
    { chapterUid = "two", title = "第二章", level = 1 },
}
-- Valid 1x1 transparent PNG.
local png = "\137PNG\r\n\026\n\0\0\0\rIHDR"
    .. "\0\0\0\1\0\0\0\1\8\6\0\0\0\31\21\196\137"
    .. "\0\0\0\rIDAT\8\215c\248\207\192\240\31\0\5\0\1\255"
    .. "\137\153=\29\0\0\0\0IEND\174B\96\130"
local bodies = {
    one = '<p>中文、多标签与实体：<em>第一章</em> &amp; 正文。</p>'
        .. '<p><img src="../images/pixel.png" alt="测试图片"/></p>',
    two = "<p>第二章用于验证目录和章节跳转。</p>",
}
local entries = Content.build_book_epub_entries(
    book, chapters, bodies, "validation",
    {
        {
            href = "images/pixel.png",
            media_type = "image/png",
            data = png,
        },
    },
    "body{line-height:1.7} img{max-width:100%}")
Content.write_epub_archive(output, entries)
print(output)

-- Canonical Cache (design doc §7.1): the single normalized content store
-- shared by the reader and the EPUB exporter.
--
-- Layout (under <cache_dir>/canonical/<bookId>/):
--   metadata.json                 book metadata (title/author/format/cover)
--   catalog.json                  normalized chapter list
--   styles/normalized.css         book CSS
--   chapters/<uid>.xhtml          clean full XHTML document (no annotations)
--   chapters/<uid>.textmap.json   raw -> canonical offset mapping (schema 1)
--   assets/<sha256>.<ext>         content-addressed images
--   annotations/<uid>.json        raw underline/review payloads (optional)
--
-- Annotations are NOT baked into cached chapters (v0.2 design decision):
-- they are injected at reader-render or EPUB-export time, with ranges mapped
-- through the textmap edit list.

local Crypto = require("weread.lib.crypto")
local Content = require("weread.lib.content")
local json = require("weread.lib.json")
local logger = require("weread.lib.log")

local Canonical = {}

local LOG_MODULE = "[WeRead][Canonical]"

-- ----------------------------------------------------------- path helpers

local function ensure_dir(path)
    os.execute("mkdir -p " .. string.format("%q", path))
end

local function write_atomic(path, data)
    local tmp = path .. ".tmp"
    local file, err = io.open(tmp, "wb")
    if not file then
        return nil, err
    end
    file:write(data)
    file:close()
    local ok, rename_err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return nil, rename_err
    end
    return true
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("a")
    file:close()
    return data
end

function Canonical.book_dir(settings, book_id)
    return Content.book_cache_dir(settings, book_id)
        .. "/../canonical/" .. Content.book_dir_name(book_id)
end

local function chapter_path(dir, uid)
    return dir .. "/chapters/" .. uid .. ".xhtml"
end

local function textmap_path(dir, uid)
    return dir .. "/chapters/" .. uid .. ".textmap.json"
end

-- -------------------------------------------------------- offset mapping

-- Map a raw-HTML character position through an edit list (see
-- Content.rewrite_image_sources). Edits are in original coordinates.
-- Positions inside an edited span clamp to the span's new start (or new end
-- when is_end is true, for range-end semantics).
local function map_with_edits(edits, raw_pos, is_end)
    local delta = 0
    for _i, e in ipairs(edits or {}) do
        if e.orig_end <= raw_pos then
            delta = delta + (e.new_len - e.orig_len)
        elseif e.orig_start < raw_pos then
            local base = e.orig_start + delta - 1  -- new position of span start (1-based)
            if is_end then
                return base + e.new_len
            end
            return base + 1
        else
            break
        end
    end
    return raw_pos + delta
end

-- Map a raw position through a chain of edit lists (raw -> v1 -> canonical).
function Canonical.map_position(edit_chain, raw_pos, is_end)
    local pos = raw_pos
    for _i, edits in ipairs(edit_chain or {}) do
        pos = map_with_edits(edits, pos, is_end)
    end
    return pos
end

-- --------------------------------------------------------------- assets

local IMAGE_EXTS = {
    ["image/png"] = ".png",
    ["image/jpeg"] = ".jpg",
    ["image/gif"] = ".gif",
    ["image/webp"] = ".webp",
}

local function asset_ext(asset)
    return IMAGE_EXTS[asset.media_type] or ".bin"
end

-- ------------------------------------------------------------ read/write

function Canonical.has_chapter(settings, book, chapter)
    local dir = Canonical.book_dir(settings, book.book_id or book.bookId)
    local uid = tostring(chapter.chapterUid)
    local file = io.open(chapter_path(dir, uid), "rb")
    if file then
        file:close()
        return true
    end
    return false
end

function Canonical.write_catalog(settings, book, chapters)
    local dir = Canonical.book_dir(settings, book.book_id or book.bookId)
    ensure_dir(dir)
    return write_atomic(dir .. "/catalog.json", json.encode({
        book_id = book.book_id or book.bookId,
        chapters = chapters,
    }))
end

function Canonical.write_metadata(settings, book)
    local dir = Canonical.book_dir(settings, book.book_id or book.bookId)
    ensure_dir(dir)
    return write_atomic(dir .. "/metadata.json", json.encode({
        book_id = book.book_id or book.bookId,
        title = book.title,
        author = book.author,
        format = book.format,
        cover = book.cover,
    }))
end

-- Fetch + normalize one chapter into the cache (idempotent: existing
-- chapters are returned without refetching).
--
-- Returns: xhtml_path, textmap_path
function Canonical.ensure_chapter(client, settings, book, chapter, state)
    state = state or {}
    local book_id = book.book_id or book.bookId
    local uid = tostring(chapter.chapterUid)
    local dir = Canonical.book_dir(settings, book_id)
    local final_path = chapter_path(dir, uid)
    if Canonical.has_chapter(settings, book, chapter) then
        return final_path, textmap_path(dir, uid)
    end

    -- 1. raw chapter source (annotations NOT applied at this stage)
    local raw_xhtml = Content.fetch_single_chapter_source(client, settings, book, chapter, state)

    -- 2. assets + image rewrite (edits1: raw -> asset-rewritten)
    local rewritten, assets, edits1 =
        Content.finalize_single_chapter_content(client, settings, book, chapter, raw_xhtml, state)

    -- 3. content-address assets; rewrite hrefs to canonical relative paths
    --    (edits2: asset-rewritten -> canonical)
    ensure_dir(dir)
    ensure_dir(dir .. "/chapters")
    ensure_dir(dir .. "/assets")
    ensure_dir(dir .. "/styles")
    ensure_dir(dir .. "/annotations")
    local canonical_src_map = {}
    local asset_index = {}
    for _i, asset in ipairs(assets or {}) do
        local hash = Crypto.sha256_hex(asset.data)
        local name = hash .. asset_ext(asset)
        local rel = "../assets/" .. name
        if not asset_index[name] then
            local ok, err = write_atomic(dir .. "/assets/" .. name, asset.data)
            if not ok then
                error("canonical: asset write failed: " .. tostring(err))
            end
            asset_index[name] = true
        end
        -- key by basename of the href currently embedded in the document
        local base = tostring(asset.href or ""):match("[^/]+$") or asset.href
        canonical_src_map[base] = rel
    end
    local canonical_xhtml, edits2 = Content.rewrite_image_sources(rewritten, canonical_src_map)

    -- 4. wrap as a standalone document referencing the normalized stylesheet
    local title = chapter.title or ("Chapter " .. uid)
    local document = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head>
<title>]] .. (title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) .. [[</title>
<link rel="stylesheet" type="text/css" href="../styles/normalized.css"/>
</head>
<body>
]] .. canonical_xhtml .. [[
</body>
</html>]]

    local ok, err = write_atomic(final_path, document)
    if not ok then
        error("canonical: chapter write failed: " .. tostring(err))
    end
    if state.css then
        write_atomic(dir .. "/styles/normalized.css", state.css)
    end

    -- 5. textmap (schema 1): raw -> canonical character offset mapping
    local textmap = {
        schema = 1,
        chapter_uid = uid,
        format = book.format or "epub",
        source_sha256 = Crypto.sha256_hex(raw_xhtml),
        canonical_sha256 = Crypto.sha256_hex(canonical_xhtml),
        edit_chain = { edits1 or {}, edits2 or {} },
    }
    write_atomic(textmap_path(dir, uid), json.encode(textmap))
    logger.info(LOG_MODULE, "chapter cached:", "book=", book_id, "uid=", uid)
    return final_path, textmap_path(dir, uid)
end

-- Read a cached chapter document + textmap.
function Canonical.get_chapter_document(settings, book, chapter)
    local dir = Canonical.book_dir(settings, book.book_id or book.bookId)
    local uid = tostring(chapter.chapterUid)
    local xhtml = read_file(chapter_path(dir, uid))
    if not xhtml then
        return nil, "not_cached"
    end
    local textmap_raw = read_file(textmap_path(dir, uid))
    return xhtml, textmap_raw and json.decode(textmap_raw) or nil
end

-- Store raw annotation payloads for later export-time injection.
function Canonical.write_annotations(settings, book, chapter, payload)
    local dir = Canonical.book_dir(settings, book.book_id or book.bookId)
    ensure_dir(dir .. "/annotations")
    local uid = tostring(chapter.chapterUid)
    return write_atomic(dir .. "/annotations/" .. uid .. ".json", json.encode(payload))
end

-- Pack cached chapters (+ assets + css) into an EPUB at `output_path`.
-- Chapter bodies come from the cache; asset references inside the XHTML
-- ("../assets/<hash>") resolve to OEBPS/assets/ in the archive.
--
-- opts.suffix      -- file name suffix (default "book")
-- opts.cover_data  -- optional cover image bytes
-- opts.css         -- stylesheet override (default: cached normalized.css)
function Canonical.export_epub(settings, book, chapters, output_path, opts)
    opts = opts or {}
    local book_id = book.book_id or book.bookId
    local dir = Canonical.book_dir(settings, book_id)

    local bodies = {}
    local assets = {}
    local seen_assets = {}
    for ci, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.chapterUid or ci)
        local xhtml = read_file(chapter_path(dir, uid))
        if not xhtml then
            return nil, "chapter_not_cached:" .. uid
        end
        bodies[uid] = xhtml
    end
    -- collect every cached asset (they are content-addressed and shared)
    local assets_dir = dir .. "/assets"
    local handle = io.popen("ls " .. string.format("%q", assets_dir) .. " 2>/dev/null")
    if handle then
        for name in handle:lines() do
            if not seen_assets[name] then
                seen_assets[name] = true
                local data = read_file(assets_dir .. "/" .. name)
                if data then
                    local ext = name:match("(%.%w+)$") or ""
                    local mime = ({
                        [".png"] = "image/png",
                        [".jpg"] = "image/jpeg",
                        [".gif"] = "image/gif",
                        [".webp"] = "image/webp",
                    })[ext] or "application/octet-stream"
                    table.insert(assets, {
                        href = "assets/" .. name,
                        data = data,
                        media_type = mime,
                    })
                end
            end
        end
        handle:close()
    end

    local css = opts.css or read_file(dir .. "/styles/normalized.css")
    local entries = Content.build_book_epub_entries(
        book, chapters, bodies, opts.suffix or "book", assets, css, opts.cover_data)
    Content.write_epub_archive(output_path, entries)
    logger.info(LOG_MODULE, "epub exported:", output_path)
    return output_path
end

return Canonical

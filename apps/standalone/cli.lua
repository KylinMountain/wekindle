#!/usr/bin/env luajit
-- Wereader standalone CLI (Linux/macOS).
--
-- Desktop-only bootstrap credentials may be put in ~/.wereader/secrets.lua:
--   return { cookies = { wr_gid = "...", wr_vid = "..." }, api_key = "..." }
-- (QR login will replace this once the LVGL UI lands.)
--
-- Commands:
--   account                      show account + credential status
--   shelf                        list bookshelf
--   bookinfo <book_id>           book metadata
--   progress <book_id>           remote reading progress
--   chapters <book_id>           table of contents (web catalog)
--   download <book_id> [uid]     download book (or single chapter) to EPUB

local here = arg[0]:match("(.*/)") or "./"
package.path = here .. "?.lua;"
    .. here .. "../../core/lua/?.lua;"
    .. here .. "../../platform/standalone/?.lua;"
    .. here .. "../../third_party/?.lua;"
    .. package.path

local bootstrap = require("bootstrap")
local json = require("weread.lib.json")
local Content = require("weread.lib.content")

local app = bootstrap.init()
local transport_sleep = function(s)
    local ffi = require("ffi")
    ffi.cdef("unsigned int usleep(unsigned int usec);")
    ffi.C.usleep(math.floor(s * 1000000))
end

-- Merge credentials from secrets.lua if present (manual seeding until
-- QR login exists).
local function seed_secrets()
    if os.getenv("WEREADER_PLATFORM") == "kindle" then
        -- Kindle credentials must enter through QR login and ISecretStore.
        -- Never load a plaintext seed from the USB-visible userstore.
        return
    end
    local path = app.data_dir .. "/secrets.lua"
    local file = io.open(path)
    if not file then
        return false
    end
    file:close()
    local chunk = loadfile(path)
    local ok, secrets = pcall(chunk)
    if not ok or type(secrets) ~= "table" then
        return false
    end
    app.settings:update_auth(secrets)
    return true
end

local command = arg[1]

local function usage()
    print([[
usage: cli.lua <command> [args]
  login                        QR login via WeChat scan
  account                      show account + credential status
  shelf                        list bookshelf
  bookinfo <book_id>           book metadata
  progress <book_id>           remote reading progress
  chapters <book_id>           table of contents (web catalog)
  download <book_id> [uid]     download book (or single chapter) to EPUB
  cache <book_id> [uid]        fetch chapters into the Canonical Cache
  export <book_id> [output]    pack cached chapters into an EPUB]])
    os.exit(command == nil and 0 or 1)
end

local commands = {}

function commands.login()
    local Login = require("login")
    Login.login(app.client, app.settings, transport_sleep)
end

function commands.account()
    local account = app.settings:get("account")
    print("name:      " .. (account.name or ""))
    print("user_vid:  " .. (account.user_vid or ""))
    print("cookies:   " .. (app.settings:is_cookie_configured() and "configured" or "MISSING"))
    print("api_key:   " .. (app.settings:is_api_configured() and "configured" or "MISSING"))
end

function commands.shelf()
    local result = app.client:gateway("/shelf/sync", {})
    local books = result.books or {}
    print(string.format("%d book(s):", #books))
    for _i, book in ipairs(books) do
        local flags = {}
        if book.finishReading == 1 then flags[#flags + 1] = "finished" end
        print(string.format("  %-30s %-20s %s",
            tostring(book.title or book.bookId):sub(1, 30),
            tostring(book.author or ""):sub(1, 20),
            table.concat(flags, ",")))
        print(string.format("    id: %s", tostring(book.bookId)))
    end
end

function commands.bookinfo(book_id)
    assert(book_id, "book_id required")
    local info = app.client:get_book_info(book_id)
    print(json.encode(info))
end

function commands.progress(book_id)
    assert(book_id, "book_id required")
    local progress = app.client:get_progress(book_id)
    print(json.encode(progress))
end

local function load_book(book_id)
    local info = app.client:get_book_info(book_id)
    local book = {
        book_id = book_id,
        title = info.title,
        author = info.author,
        cover = info.cover,
    }
    Content.ensure_reader_state(app.client, book)
    return book, info
end

function commands.chapters(book_id)
    assert(book_id, "book_id required")
    local book = load_book(book_id)
    local chapters = Content.fetch_catalog(app.client, book)
    for _i, ch in ipairs(chapters) do
        local paid = ch.paid == 1 and " [paid]" or ""
        print(string.format("  %4d. %s%s", ch.chapterIdx or 0, tostring(ch.title), paid))
    end
end

function commands.download(book_id, chapter_uid)
    assert(book_id, "book_id required")
    local book = load_book(book_id)
    local chapters = Content.fetch_catalog(app.client, book)
    local options = {}
    if chapter_uid then
        local selected
        for _i, ch in ipairs(chapters) do
            if tostring(ch.chapterUid) == tostring(chapter_uid) then
                selected = ch
                break
            end
        end
        assert(selected, "chapter not found: " .. tostring(chapter_uid))
        chapters = { selected }
        options.single_chapter = true
    end
    local done_ok, done_value
    app.downloader:start(book, chapters, chapter_uid and "chapter" or "book", {
        single_chapter = options.single_chapter,
        on_complete = function(success, value)
            done_ok, done_value = success, value
        end,
    })
    app.drain_tasks()
    print("")
    if done_ok then
        print("saved: " .. tostring(done_value))
    else
        print("download failed: " .. tostring(done_value))
        os.exit(1)
    end
end

function commands.cache(book_id, chapter_uid)
    assert(book_id, "book_id required")
    local Canonical = require("weread.lib.canonical")
    local book = load_book(book_id)
    local chapters = Content.fetch_catalog(app.client, book)
    Canonical.write_metadata(app.settings, book)
    Canonical.write_catalog(app.settings, book, chapters)
    local cached = 0
    for _i, ch in ipairs(chapters) do
        if chapter_uid and tostring(ch.chapterUid) ~= tostring(chapter_uid) then
            goto continue
        end
        local ok, err = pcall(function()
            Canonical.ensure_chapter(app.client, app.settings, book, ch, {})
        end)
        if ok then
            cached = cached + 1
            io.stdout:write(string.format("\27[Kcached %d/%d: %s\r", cached, #chapters, tostring(ch.title)))
        else
            print("\nchapter " .. tostring(ch.chapterUid) .. " failed: " .. tostring(err))
        end
        ::continue::
    end
    print(string.format("\ncached %d chapter(s) into canonical store", cached))
end

function commands.export(book_id, output)
    assert(book_id, "book_id required")
    local Canonical = require("weread.lib.canonical")
    local book = load_book(book_id)
    local chapters = Content.fetch_catalog(app.client, book)
    output = output or ((app.settings:get_download_dir()) .. "/" ..
        tostring(book.title or book_id) .. ".epub")
    local path, err = Canonical.export_epub(app.settings, book, chapters, output, {})
    if not path then
        print("export failed: " .. tostring(err))
        os.exit(1)
    end
    print("exported: " .. path)
end

if not command or not commands[command] then
    usage()
end

if command ~= "account" and command ~= "login" then
    seed_secrets()
    if not app.settings:is_cookie_configured() then
        io.stderr:write("no credentials; create " .. app.data_dir .. "/secrets.lua first\n")
        os.exit(2)
    end
end

commands[command](arg[2], arg[3])

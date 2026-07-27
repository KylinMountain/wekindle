-- End-of-book navigation dialog integration.
local EndOfBookDialog = require("weread.ui.end_of_book_dialog")

local M = {}

function M:showEndOfBookDialog(book_id)
    local file_path = self.ui.document and self.ui.document.file
    if not file_path then return false end

    local books = self.settings:get("books", {})
    local book = books[book_id]
    if not book or not self:ensureChaptersLoaded(book) then return false end

    local current_idx, current_ch, is_full_book = self:getChapterInfoFromFile(book, file_path)
    -- The chapter-nav row is shown only for single downloaded chapters (a mapped
    -- current chapter that is not part of a full-book EPUB); "next chapter"
    -- additionally requires a successor.
    local show_chapter_nav = current_idx ~= nil and not is_full_book
    local next_chapter = show_chapter_nav and book.chapters[current_idx + 1] or nil

    EndOfBookDialog.show({ show_chapter_nav = show_chapter_nav, has_next = next_chapter ~= nil }, {
        on_bookshelf = function()
            self:showBookshelf()
        end,
        on_search = function()
            self:showSearch()
        end,
        on_chapter_list = function()
            self:showChapterList(book)
        end,
        on_next = next_chapter and function()
            self:openChapter(book, next_chapter)
        end or nil,
        on_book_details = function()
            self:showCurrentBookDetails()
        end,
        on_read_stats = function()
            self:showReadStats()
        end,
        on_close_book = function()
            -- Mirror KOReader's ReaderStatus:openFileBrowser(): closing the
            -- reader alone exits the app when there is no file-manager stack, so
            -- reopen the file browser right after (positioned on the book file).
            local ui = self.ui
            if not ui then return end
            local file = ui.document and ui.document.file
            ui:onClose()
            if file and ui.showFileManager then
                ui:showFileManager(file)
            end
        end,
    })
    return true
end

return M

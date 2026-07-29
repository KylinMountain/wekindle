-- Read-only response shape assertions used by CI canaries and adapters.
-- They never mutate cache and return stable error codes for alert routing.

local SchemaGuard = {}

local function fail(code)
    return nil, "schema_changed:" .. code
end

function SchemaGuard.shelf(value)
    if type(value) ~= "table" then return fail("shelf_not_table") end
    if type(value.books) ~= "table" then return fail("shelf_books_missing") end
    for _, book in ipairs(value.books) do
        if type(book) ~= "table"
            or (book.bookId == nil and book.book_id == nil) then
            return fail("shelf_book_id_missing")
        end
    end
    return true
end

function SchemaGuard.catalog(value, book_id)
    local records = type(value) == "table" and (value.data or value) or nil
    if type(records) ~= "table" then return fail("catalog_not_table") end
    for _, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id or "") then
            local chapters = record.updated or record.chapterInfos
                or record.chapters
            if type(chapters) ~= "table" then
                return fail("catalog_chapters_missing")
            end
            return true
        end
    end
    return fail("catalog_book_missing")
end

function SchemaGuard.progress(value)
    if type(value) ~= "table" then return fail("progress_not_table") end
    local function find(node, depth)
        if type(node) ~= "table" or depth > 6 then return false end
        if tonumber(node.progress or node.readingProgress
            or node.bookProgress) then return true end
        for _, child in pairs(node) do
            if type(child) == "table" and find(child, depth + 1) then
                return true
            end
        end
        return false
    end
    if find(value, 0) then return true end
    return fail("progress_value_missing")
end

function SchemaGuard.mp_articles(value)
    if type(value) ~= "table" or type(value.reviews) ~= "table" then
        return fail("mp_reviews_missing")
    end
    return true
end

return SchemaGuard

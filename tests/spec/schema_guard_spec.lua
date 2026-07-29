local Guard = require("weread.lib.schema_guard")

assert(Guard.shelf{ books = { { bookId = "1" } } })
local ok, err = Guard.shelf{ books = { { title = "missing" } } }
assert(ok == nil and err == "schema_changed:shelf_book_id_missing")

assert(Guard.catalog({
    { bookId = "1", updated = { { chapterUid = 2 } } },
}, "1"))
ok, err = Guard.catalog({ { bookId = "other", updated = {} } }, "1")
assert(ok == nil and err == "schema_changed:catalog_book_missing")

assert(Guard.progress{ data = { book = { progress = 42 } } })
ok, err = Guard.progress{ data = { book = { title = "no progress" } } }
assert(ok == nil and err == "schema_changed:progress_value_missing")

assert(Guard.mp_articles{ reviews = {} })
ok, err = Guard.mp_articles{ result = {} }
assert(ok == nil and err == "schema_changed:mp_reviews_missing")

print("schema guard: 8 checks, 0 failures")

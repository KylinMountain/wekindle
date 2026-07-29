local CacheManager = require("cache_manager")

local root = "/tmp/weread-cache-manager-test"
os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root .. "/canonical/book " .. root .. "/book")

local function write(path, size)
    local file = assert(io.open(path, "wb"))
    file:write(string.rep("x", size))
    file:close()
end

write(root .. "/canonical/book/chapter.xhtml", 19)
write(root .. "/book/catalog.json", 11)

local manager = CacheManager:new{
    settings = { cache_dir = root },
    now = function() return 123 end,
}

local usage = manager:book_usage("book")
assert(usage >= 30)
local result = manager:clear_book("book")
assert(result.ok)
assert(result.removed_bytes >= 30)
assert(#result.removed_paths == 2)
assert(manager:book_usage("book") == 0)

local escaped = manager:clear_book("../../outside")
assert(escaped.ok)
assert(#escaped.removed_paths == 0)

local ok = pcall(function()
    CacheManager:new{ settings = { cache_dir = "/" } }:clear_book("book")
end)
assert(not ok, "root cache deletion must be rejected")

os.execute("rm -rf " .. root)
print("cache manager: 8 checks, 0 failures")

-- Canonical/legacy cache accounting and safe per-book cleanup.
--
-- Deletion is constrained to sanitized book directories below settings.cache_dir.
-- A directory is first renamed to a unique trash path; failed removal is rolled
-- back, so an interrupted cleanup never leaves a partially deleted live cache.

local Content = require("weread.lib.content")

local CacheManager = {}
CacheManager.__index = CacheManager

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function trim_trailing_slash(path)
    return tostring(path or ""):gsub("/+$", "")
end

local function default_measure(path)
    local pipe = io.popen("du -sk " .. shell_quote(path) .. " 2>/dev/null", "r")
    if not pipe then return 0 end
    local line = pipe:read("*l") or ""
    local kib = tonumber(line:match("^(%d+)")) or 0
    pipe:close()
    return kib * 1024
end

local function default_remove(path)
    local ok, why, code = os.execute("rm -rf " .. shell_quote(path))
    if type(ok) == "number" then return ok == 0 end
    return ok == true and (code == nil or code == 0), why or code
end

function CacheManager:new(options)
    options = options or {}
    assert(type(options.settings) == "table"
        and type(options.settings.cache_dir) == "string",
        "cache_manager: settings with cache_dir required")
    return setmetatable({
        settings = options.settings,
        measure = options.measure or default_measure,
        remove_tree = options.remove_tree or default_remove,
        now = options.now or os.time,
        sequence = 0,
    }, self)
end

function CacheManager:_paths(book_id)
    assert(book_id ~= nil and tostring(book_id) ~= "",
        "cache_manager: non-empty book id required")
    local root = trim_trailing_slash(self.settings.cache_dir)
    assert(root ~= "" and root ~= "/",
        "cache_manager: unsafe cache root")
    local name = Content.book_dir_name(book_id)
    return root, {
        root .. "/canonical/" .. name,
        root .. "/" .. name,
    }
end

function CacheManager:book_usage(book_id)
    local _root, paths = self:_paths(book_id)
    local total = 0
    for _, path in ipairs(paths) do
        total = total + math.max(0, tonumber(self.measure(path)) or 0)
    end
    return total
end

function CacheManager:clear_book(book_id)
    local root, paths = self:_paths(book_id)
    local removed_bytes = 0
    local removed_paths = {}
    local failures = {}

    for _, path in ipairs(paths) do
        assert(path:sub(1, #root + 1) == root .. "/"
            and not path:find("/../", 1, true)
            and path ~= root,
            "cache_manager: path escaped cache root")
        local size = math.max(0, tonumber(self.measure(path)) or 0)
        self.sequence = self.sequence + 1
        local trash = path .. ".delete-" .. tostring(self.now())
            .. "-" .. tostring(self.sequence)
        local renamed, rename_err = os.rename(path, trash)
        if renamed then
            local removed, remove_err = self.remove_tree(trash)
            if removed then
                removed_bytes = removed_bytes + size
                removed_paths[#removed_paths + 1] = path
            else
                os.rename(trash, path)
                failures[#failures + 1] = {
                    path = path,
                    error = tostring(remove_err or "remove_failed"),
                }
            end
        elseif size > 0 then
            failures[#failures + 1] = {
                path = path,
                error = tostring(rename_err or "rename_failed"),
            }
        end
    end

    return {
        ok = #failures == 0,
        removed_bytes = removed_bytes,
        removed_paths = removed_paths,
        failures = failures,
    }
end

return CacheManager

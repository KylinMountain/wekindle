-- Standalone IStorage adapter: key-value settings store over SQLite,
-- via LuaJIT FFI. Implements the KV port consumed by weread.lib.settings
-- (see core/contracts/ports.md):
--
--   store:readSetting(key, default) / store:saveSetting(key, value)
--   store:delSetting(key) / store:flush()
--
-- Values are JSON-encoded; reads return fresh tables (same semantics as
-- KOReader's LuaSettings). Writes batch into a transaction that flush()
-- commits. On vfat targets the database must use journal_mode=DELETE
-- (design doc §3.2); pass journal_mode = "delete" for those.

local ffi = require("ffi")
local json = require("weread.lib.json")

ffi.cdef[[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

int sqlite3_open(const char *filename, sqlite3 **ppDb);
int sqlite3_close(sqlite3 *db);
int sqlite3_exec(sqlite3 *db, const char *sql, void *callback, void *arg, char **errmsg);
const char *sqlite3_errmsg(sqlite3 *db);
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_bind_text(sqlite3_stmt *stmt, int index, const char *value, int n, void (*destructor)(void*));
int sqlite3_step(sqlite3_stmt *stmt);
const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int col);
int sqlite3_finalize(sqlite3_stmt *stmt);
]]

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101
local SQLITE_TRANSIENT = ffi.cast("void (*)(void*)", -1)

local C = ffi.load("sqlite3")

local SqliteStore = {}
SqliteStore.__index = SqliteStore

local function check_db(db, rc, context)
    if rc ~= SQLITE_OK then
        error(string.format("sqlite_store: %s failed: %s",
            context, ffi.string(C.sqlite3_errmsg(db))))
    end
end

-- opts.path          -- database file path (created if missing)
-- opts.journal_mode  -- "delete" (default; safe on vfat) | "wal" (ext4 only)
function SqliteStore:new(opts)
    opts = opts or {}
    assert(type(opts.path) == "string" and opts.path ~= "", "sqlite_store: path required")
    local handle = ffi.new("sqlite3 *[1]")
    if C.sqlite3_open(opts.path, handle) ~= SQLITE_OK then
        error("sqlite_store: cannot open " .. opts.path)
    end
    local self = setmetatable({
        db = handle[0],
        path = opts.path,
        _in_txn = false,
    }, self)
    local mode = opts.journal_mode or "delete"
    check_db(self.db, C.sqlite3_exec(self.db,
        "PRAGMA journal_mode = " .. mode .. ";"
        .. "PRAGMA synchronous = FULL;"
        .. "PRAGMA busy_timeout = 3000;"
        .. "CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        nil, nil, nil), "init")
    return self
end

function SqliteStore:_begin()
    if not self._in_txn then
        check_db(self.db, C.sqlite3_exec(self.db, "BEGIN IMMEDIATE;", nil, nil, nil), "begin")
        self._in_txn = true
    end
end

-- Roll back a failed transaction and reset the flag, so subsequent writes
-- start a fresh transaction instead of piling onto a doomed one.
function SqliteStore:_abort()
    if self._in_txn then
        C.sqlite3_exec(self.db, "ROLLBACK;", nil, nil, nil)
        self._in_txn = false
    end
end

function SqliteStore:_query_value(key)
    local stmt = ffi.new("sqlite3_stmt *[1]")
    check_db(self.db, C.sqlite3_prepare_v2(self.db,
        "SELECT value FROM kv WHERE key = ?;", -1, stmt, nil), "prepare select")
    C.sqlite3_bind_text(stmt[0], 1, key, #key, SQLITE_TRANSIENT)
    local rc = C.sqlite3_step(stmt[0])
    local value = nil
    if rc == SQLITE_ROW then
        local text = C.sqlite3_column_text(stmt[0], 0)
        if text ~= nil then
            value = ffi.string(text)
        end
    elseif rc ~= SQLITE_DONE then
        C.sqlite3_finalize(stmt[0])
        check_db(self.db, rc, "select")
    end
    C.sqlite3_finalize(stmt[0])
    return value
end

function SqliteStore:readSetting(key, default)
    local raw = self:_query_value(key)
    if raw == nil then
        return default
    end
    local ok, value = pcall(json.decode, raw)
    if not ok then
        return default
    end
    return value
end

function SqliteStore:saveSetting(key, value)
    self:_begin()
    local encoded = json.encode(value)
    local stmt = ffi.new("sqlite3_stmt *[1]")
    check_db(self.db, C.sqlite3_prepare_v2(self.db,
        "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?);", -1, stmt, nil),
        "prepare upsert")
    C.sqlite3_bind_text(stmt[0], 1, key, #key, SQLITE_TRANSIENT)
    C.sqlite3_bind_text(stmt[0], 2, encoded, #encoded, SQLITE_TRANSIENT)
    local rc = C.sqlite3_step(stmt[0])
    C.sqlite3_finalize(stmt[0])
    if rc ~= SQLITE_DONE then
        self:_abort()
        check_db(self.db, rc, "upsert")
    end
end

function SqliteStore:delSetting(key)
    self:_begin()
    local stmt = ffi.new("sqlite3_stmt *[1]")
    check_db(self.db, C.sqlite3_prepare_v2(self.db,
        "DELETE FROM kv WHERE key = ?;", -1, stmt, nil), "prepare delete")
    C.sqlite3_bind_text(stmt[0], 1, key, #key, SQLITE_TRANSIENT)
    local rc = C.sqlite3_step(stmt[0])
    C.sqlite3_finalize(stmt[0])
    if rc ~= SQLITE_DONE then
        self:_abort()
        check_db(self.db, rc, "delete")
    end
end

function SqliteStore:flush()
    if self._in_txn then
        local rc = C.sqlite3_exec(self.db, "COMMIT;", nil, nil, nil)
        if rc ~= SQLITE_OK then
            self:_abort()
            check_db(self.db, rc, "commit")
        end
        self._in_txn = false
    end
end

function SqliteStore:close()
    self:flush()
    if self.db ~= nil then
        C.sqlite3_close(self.db)
        self.db = nil
    end
end

return SqliteStore

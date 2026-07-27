-- weread-core logging port shim.
--
-- Inside KOReader this delegates to KOReader's `logger` module. Outside
-- KOReader (Linux simulator, unit tests, standalone host) it falls back to
-- a stderr logger so core modules never hard-fail on a missing host logger.
--
-- The standalone C++ host can replace this module via package.preload to
-- route logs into its own diagnostic pipeline (see core/contracts/ports.md).

local ok, koreader_logger = pcall(require, "logger")

if ok and type(koreader_logger) == "table" and type(koreader_logger.info) == "function" then
    return koreader_logger
end

local LEVELS = { dbg = 1, info = 2, warn = 3, err = 4 }
local min_level = LEVELS.warn

local function emit(level, ...)
    if LEVELS[level] < min_level then
        return
    end
    local parts = { ... }
    for i = 1, #parts do
        parts[i] = tostring(parts[i])
    end
    io.stderr:write(string.format("[weread:%s] %s\n", level, table.concat(parts, " ")))
end

local fallback = {}

function fallback.dbg(...) emit("dbg", ...) end
function fallback.info(...) emit("info", ...) end
function fallback.warn(...) emit("warn", ...) end
function fallback.err(...) emit("err", ...) end

function fallback.setLevel(level)
    if LEVELS[level] then
        min_level = LEVELS[level]
    end
end

return fallback

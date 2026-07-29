#!/usr/bin/env luajit
-- Scheduled read-only protocol canary. Credentials are supplied only through
-- CI secrets; output contains stage/error codes, never response bodies.

local root = arg[0]:match("^(.*)/tools/canary/") or "."
package.path = root .. "/apps/standalone/?.lua;"
    .. root .. "/core/lua/?.lua;"
    .. root .. "/platform/standalone/?.lua;"
    .. root .. "/third_party/?.lua;" .. package.path

local bootstrap = require("bootstrap")
local Guard = require("weread.lib.schema_guard")
local data_dir = os.getenv("WEREADER_CANARY_DATA_DIR")
    or "/tmp/wereader-protocol-canary"
local api_key = os.getenv("WEREADER_CANARY_API_KEY")
local book_id = os.getenv("WEREADER_CANARY_BOOK_ID")
if not api_key or api_key == "" then
    io.stderr:write("canary_not_configured\n")
    os.exit(2)
end
local app = bootstrap.init{ data_dir = data_dir }
app.settings:update_auth{ api_key = api_key }

local function check(name, operation, validator)
    local ok, response = pcall(operation)
    if not ok then
        io.stderr:write(name .. ":transport_error\n")
        return false
    end
    local valid, err = validator(response)
    if not valid then
        io.stderr:write(name .. ":" .. tostring(err) .. "\n")
        return false
    end
    io.stdout:write(name .. ":ok\n")
    return true
end

local passed = check("shelf", function()
    return app.client:gateway("/shelf/sync", {})
end, Guard.shelf)
if book_id and book_id ~= "" then
    passed = check("progress", function()
        return app.client:get_progress(book_id)
    end, Guard.progress) and passed
end
app:close()
os.exit(passed and 0 or 1)

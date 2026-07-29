-- Kindle IDevice adapter.
--
-- Power operations are reference counted so nested downloads cannot release
-- another task's suspend guard. Commands are injected in tests and all
-- production mutations are limited to the documented LIPC power property.

local Device = {}
Device.__index = Device

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function default_run(command)
    local ok, why, code = os.execute(command)
    if type(ok) == "number" then
        return ok == 0, ok
    end
    return ok == true and (code == nil or code == 0), code or why
end

local function default_read(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local value = file:read("*a")
    file:close()
    return value
end

local function default_read_command(command)
    local pipe = io.popen(command .. " 2>/dev/null", "r")
    if not pipe then return nil end
    local value = pipe:read("*a")
    local ok = pipe:close()
    if not ok then return nil end
    return value
end

local function trim(value)
    return value and value:gsub("^%s+", ""):gsub("%s+$", "") or nil
end

function Device:new(options)
    options = options or {}
    return setmetatable({
        run = options.run or default_run,
        read_file = options.read_file or default_read,
        read_command = options.read_command or default_read_command,
        suspend_reasons = {},
        suspend_count = 0,
        userstore = options.userstore or "/mnt/us",
    }, self)
end

function Device:_set_suspend_blocked(blocked)
    local value = blocked and "1" or "0"
    local ok, detail = self.run(
        "lipc-set-prop com.lab126.powerd preventScreenSaver " .. value)
    if not ok then
        return nil, "lipc_power_error:" .. tostring(detail or "unknown")
    end
    return true
end

function Device:prevent_suspend(reason)
    reason = tostring(reason or "anonymous")
    if self.suspend_count == 0 then
        local ok, err = self:_set_suspend_blocked(true)
        if not ok then
            return nil, err
        end
    end
    self.suspend_count = self.suspend_count + 1
    self.suspend_reasons[reason] = (self.suspend_reasons[reason] or 0) + 1
    return true
end

function Device:allow_suspend(reason)
    reason = tostring(reason or "anonymous")
    local reason_count = self.suspend_reasons[reason] or 0
    if reason_count == 0 then
        return true
    end

    self.suspend_reasons[reason] = reason_count - 1
    if self.suspend_reasons[reason] == 0 then
        self.suspend_reasons[reason] = nil
    end
    self.suspend_count = self.suspend_count - 1

    if self.suspend_count == 0 then
        local ok, err = self:_set_suspend_blocked(false)
        if not ok then
            -- Preserve the guard locally so cleanup can be retried.
            self.suspend_count = 1
            self.suspend_reasons[reason] =
                (self.suspend_reasons[reason] or 0) + 1
            return nil, err
        end
    end
    return true
end

function Device:release_all_suspend_guards()
    if self.suspend_count == 0 then
        return true
    end
    local ok, err = self:_set_suspend_blocked(false)
    if not ok then
        return nil, err
    end
    self.suspend_count = 0
    self.suspend_reasons = {}
    return true
end

function Device:with_suspend_guard(reason, operation)
    local ok, err = self:prevent_suspend(reason)
    if not ok then
        return nil, err
    end

    local result = { pcall(operation) }
    local released, release_err = self:allow_suspend(reason)
    if not released then
        return nil, release_err
    end
    if not result[1] then
        return nil, "operation_error:" .. tostring(result[2])
    end
    table.remove(result, 1)
    return unpack(result)
end

function Device:is_online()
    local state = trim(self.read_file("/sys/class/net/wlan0/operstate"))
    if state == "up" then
        return true
    end
    state = trim(self.read_file("/sys/class/net/usb0/operstate"))
    return state == "up"
end

function Device:free_space()
    local command = "df -kP " .. shell_quote(self.userstore)
        .. " 2>/dev/null | awk 'NR == 2 { print $4 * 1024 }'"
    local pipe = io.popen(command, "r")
    if not pipe then
        return nil, "df_unavailable"
    end
    local bytes = tonumber(trim(pipe:read("*a")))
    pipe:close()
    if not bytes then
        return nil, "df_parse_error"
    end
    return bytes
end

function Device:firmware_info()
    local value = self.read_file("/etc/prettyversion.txt")
        or self.read_file("/etc/version.txt")
    return trim(value) or "unknown"
end

-- Normalize the unstable string variants returned by Kindle powerd into the
-- two lifecycle states the application needs. Unknown output is non-fatal.
function Device:lifecycle_state()
    local raw = trim(self.read_command(
        "lipc-get-prop com.lab126.powerd state"))
    if not raw or raw == "" then return "unknown", raw end
    local lower = raw:lower()
    if lower:find("suspend", 1, true)
        or lower:find("screensaver", 1, true)
        or lower:find("sleep", 1, true) then
        return "suspended", raw
    end
    if lower:find("active", 1, true)
        or lower:find("ready", 1, true) then
        return "active", raw
    end
    return "unknown", raw
end

function Device:device_id()
    -- Never expose a raw Kindle serial through the IDevice adapter. A future
    -- SecretStore may consume a one-way device-bound derivation internally.
    return nil, "raw_device_id_forbidden"
end

return Device

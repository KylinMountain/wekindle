local Device = require("kindle.device")

local commands = {}
local should_fail_release = false
local power_state = "active"
local device = Device:new{
    run = function(command)
        commands[#commands + 1] = command
        if should_fail_release and command:match(" 0$") then
            return false, 7
        end
        return true
    end,
    read_file = function(path)
        if path == "/sys/class/net/wlan0/operstate" then
            return "up\n"
        end
        if path == "/etc/prettyversion.txt" then
            return "Kindle 5.test\n"
        end
    end,
    read_command = function(command)
        assert(command == "lipc-get-prop com.lab126.powerd state")
        return power_state
    end,
}

assert(device:prevent_suspend("download"))
assert(device:prevent_suspend("download"))
assert(device:prevent_suspend("export"))
assert(#commands == 1 and commands[1]:match(" 1$"))
assert(device.suspend_count == 3)

assert(device:allow_suspend("download"))
assert(device:allow_suspend("unknown"))
assert(#commands == 1 and device.suspend_count == 2)
assert(device:allow_suspend("download"))
assert(#commands == 1 and device.suspend_count == 1)

should_fail_release = true
local ok, err = device:allow_suspend("export")
assert(ok == nil and err:match("lipc_power_error"))
assert(device.suspend_count == 1)

should_fail_release = false
assert(device:release_all_suspend_guards())
assert(device.suspend_count == 0 and #commands == 3)
assert(commands[#commands]:match(" 0$"))

local value = assert(device:with_suspend_guard("test", function()
    return "done"
end))
assert(value == "done")
assert(device.suspend_count == 0)
assert(device:is_online())
assert(device:firmware_info() == "Kindle 5.test")
assert(device:lifecycle_state() == "active")
power_state = "goingToScreenSaver"
assert(device:lifecycle_state() == "suspended")
power_state = "suspended"
assert(device:lifecycle_state() == "suspended")
power_state = "mystery"
assert(device:lifecycle_state() == "unknown")

local raw, raw_err = device:device_id()
assert(raw == nil and raw_err == "raw_device_id_forbidden")

print("kindle device: 22 checks, 0 failures")

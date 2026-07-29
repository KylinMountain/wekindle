local function command_ok(command)
    local ok, why, code = os.execute(command)
    if type(ok) == "number" then
        return ok == 0
    end
    return ok == true and (code == nil or code == 0), why, code
end

local function read_all(path)
    local file = assert(io.open(path, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end

local tmp = os.tmpname()
local ok = command_ok("sh tools/device/probe_device.sh > " .. string.format("%q", tmp))
assert(ok, "device probe must run on a non-Kindle development host")

local report = read_all(tmp)
os.remove(tmp)

assert(report:find("report.format=wereader%-device%-probe%-v1"))
assert(report:find("report.privacy=serial%-mac%-ip%-credentials%-content%-omitted"))
assert(report:find("\nos.arch="))
assert(report:find("\nframebuffer.devices="))
assert(report:find("\ncapability.lipc_get="))
assert(report:find("\nreport.complete=yes"))

for line in report:gmatch("[^\n]+") do
    assert(line:match("^[a-z0-9_.]+="), "invalid report line: " .. line)
end

print("device probe: 7 checks, 0 failures")

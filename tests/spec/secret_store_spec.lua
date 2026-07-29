local SecretStore = require("secret_store")

local root = "/tmp/wereader-secret-store-test"
os.execute("rm -rf " .. root)

local counter = 0
local function deterministic_random(count)
    counter = counter + 1
    return string.rep(string.char(counter), count)
end

local store = SecretStore:new{
    dir = root,
    key_material = "reference-device-secret",
    random_bytes = deterministic_random,
    forbid_userstore = false,
}

assert(store:version("active") == 0)
assert(store:set("active", "api_key", "top-secret-api-key"))
assert(store:set("active", "cookies", {
    wr_gid = "private-cookie",
    wr_vid = "10001",
}))
assert(store:get("active", "api_key") == "top-secret-api-key")
assert(store:get("active", "cookies").wr_gid == "private-cookie")
assert(store:version("active") == 2)

local vault = assert(io.open(root .. "/vault.json", "rb"))
local encrypted = vault:read("*a")
vault:close()
assert(not encrypted:find("top-secret-api-key", 1, true))
assert(not encrypted:find("private-cookie", 1, true))

local mode_pipe = assert(io.popen(
    "(stat -f '%Lp' " .. root .. "/vault.json 2>/dev/null"
    .. " || stat -c '%a' " .. root .. "/vault.json)"))
local mode = mode_pipe:read("*l")
mode_pipe:close()
assert(mode == "600", "vault must use mode 0600, got " .. tostring(mode))

assert(store:delete("active", "api_key"))
assert(store:get("active", "api_key") == nil)
assert(store:version("active") == 3)

local tampered = assert(io.open(root .. "/vault.json", "rb"))
local payload = tampered:read("*a")
tampered:close()
payload = payload:gsub('"ciphertext":"(%x)', function(first)
    return '"ciphertext":"' .. (first == "0" and "1" or "0")
end, 1)
local damaged = assert(io.open(root .. "/vault.json", "wb"))
damaged:write(payload)
damaged:close()
local ok, err = pcall(function()
    return store:get("active", "cookies")
end)
assert(not ok and tostring(err):find("integrity check failed", 1, true),
    "tampered vault must fail closed")

local userstore_ok = pcall(function()
    SecretStore:new{
        dir = "/mnt/us/extensions/wereader/secrets",
        key_material = "reference-device-secret",
    }
end)
assert(not userstore_ok, "credential vault must reject /mnt/us")

os.execute("rm -rf " .. root)
print("secret store: 14 checks, 0 failures")

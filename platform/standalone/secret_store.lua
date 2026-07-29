-- Standalone ISecretStore adapter.
--
-- The Kindle bootstrap places this vault on rootfs (never /mnt/us), protects
-- the directory/file with 0700/0600, and derives an authenticated-encryption
-- key from /proc/usid without exposing that identifier through IDevice.
-- Desktop development uses a random per-install key stored beside the vault.

local bit = require("bit")
local Crypto = require("weread.lib.crypto")
local json = require("weread.lib.json")

local SecretStore = {}
SecretStore.__index = SecretStore

local ALLOWED_KEYS = {
    cookies = true,
    api_key = true,
    wr_ticket = true,
    wr_wrpa = true,
}

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_file(path, binary)
    local handle = io.open(path, binary and "rb" or "r")
    if not handle then
        return nil
    end
    local contents = handle:read("*a")
    handle:close()
    return contents
end

local function random_bytes(count)
    local handle = assert(io.open("/dev/urandom", "rb"),
        "secret_store: /dev/urandom is required")
    local value = handle:read(count)
    handle:close()
    assert(value and #value == count, "secret_store: short random read")
    return value
end

local function to_hex(value)
    return (value:gsub(".", function(byte)
        return string.format("%02x", byte:byte())
    end))
end

local function from_hex(value)
    assert(type(value) == "string" and #value % 2 == 0
        and not value:find("[^0-9a-f]", 1),
        "secret_store: invalid encrypted vault encoding")
    return (value:gsub("..", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function sha256_raw(value)
    return from_hex(Crypto.sha256_hex(value))
end

local function xor_pad(value, byte)
    local out = {}
    for index = 1, #value do
        out[index] = string.char(bit.bxor(value:byte(index), byte))
    end
    return table.concat(out)
end

local function hmac_sha256(key, message)
    if #key > 64 then
        key = sha256_raw(key)
    end
    key = key .. string.rep("\0", 64 - #key)
    local inner = sha256_raw(xor_pad(key, 0x36) .. message)
    return sha256_raw(xor_pad(key, 0x5c) .. inner)
end

local function counter_bytes(value)
    return string.char(
        bit.band(bit.rshift(value, 24), 0xff),
        bit.band(bit.rshift(value, 16), 0xff),
        bit.band(bit.rshift(value, 8), 0xff),
        bit.band(value, 0xff)
    )
end

local function crypt(key, nonce, input)
    local output, offset, counter = {}, 1, 1
    while offset <= #input do
        local stream = hmac_sha256(key,
            "wereader-secret-stream-v1\0" .. nonce .. counter_bytes(counter))
        local chunk = input:sub(offset, offset + #stream - 1)
        local bytes = {}
        for index = 1, #chunk do
            bytes[index] = string.char(
                bit.bxor(chunk:byte(index), stream:byte(index)))
        end
        output[#output + 1] = table.concat(bytes)
        offset = offset + #chunk
        counter = counter + 1
    end
    return table.concat(output)
end

local function constant_time_equal(left, right)
    if type(left) ~= "string" or type(right) ~= "string"
        or #left ~= #right then
        return false
    end
    local difference = 0
    for index = 1, #left do
        difference = bit.bor(
            difference, bit.bxor(left:byte(index), right:byte(index)))
    end
    return difference == 0
end

local function validate_name(value, label)
    assert(type(value) == "string" and value:match("^[%w_.-]+$"),
        "secret_store: invalid " .. label)
end

function SecretStore:new(opts)
    opts = opts or {}
    assert(type(opts.dir) == "string" and opts.dir ~= "",
        "secret_store: dir is required")
    if opts.forbid_userstore ~= false then
        assert(not opts.dir:match("^/mnt/us/?"),
            "secret_store: refusing to store credentials on /mnt/us")
    end
    assert(os.execute("mkdir -p " .. shell_quote(opts.dir)) == 0,
        "secret_store: cannot create vault directory")
    assert(os.execute("chmod 700 " .. shell_quote(opts.dir)) == 0,
        "secret_store: cannot protect vault directory")

    local random = opts.random_bytes or random_bytes
    local material = opts.key_material
    if not material and opts.device_key_path then
        material = read_file(opts.device_key_path, true)
        if material then
            material = material:gsub("%s+$", "")
        end
    end
    local key_path = opts.dir .. "/device.key"
    if not material and not opts.require_device_key then
        material = read_file(key_path, true)
        if not material then
            material = random(32)
            local handle = assert(io.open(key_path .. ".tmp", "wb"))
            handle:write(material)
            handle:close()
            assert(os.execute("chmod 600 " .. shell_quote(key_path .. ".tmp")) == 0)
            assert(os.rename(key_path .. ".tmp", key_path))
        end
    end
    assert(type(material) == "string" and #material >= 8,
        "secret_store: device-bound key material is unavailable")

    return setmetatable({
        dir = opts.dir,
        path = opts.dir .. "/vault.json",
        key_material = material,
        random = random,
    }, self)
end

function SecretStore:_empty()
    return {
        format = 1,
        salt = to_hex(self.random(16)),
        accounts = {},
    }
end

function SecretStore:_derive_key(salt)
    return hmac_sha256(self.key_material,
        "wereader-secret-key-v1\0" .. salt)
end

function SecretStore:_load()
    local encoded = read_file(self.path, true)
    if not encoded then
        return self:_empty()
    end
    local ok, envelope = pcall(json.decode, encoded)
    assert(ok and type(envelope) == "table" and envelope.format == 1,
        "secret_store: invalid vault envelope")
    local salt = from_hex(envelope.salt)
    local nonce = from_hex(envelope.nonce)
    local ciphertext = from_hex(envelope.ciphertext)
    local supplied_mac = from_hex(envelope.mac)
    local key = self:_derive_key(salt)
    local expected_mac = hmac_sha256(key,
        "wereader-secret-vault-v1\0" .. nonce .. ciphertext)
    assert(constant_time_equal(supplied_mac, expected_mac),
        "secret_store: vault integrity check failed")
    local plaintext = crypt(key, nonce, ciphertext)
    local payload_ok, payload = pcall(json.decode, plaintext)
    assert(payload_ok and type(payload) == "table"
        and type(payload.accounts) == "table",
        "secret_store: invalid vault payload")
    payload.format = 1
    payload.salt = envelope.salt
    return payload
end

function SecretStore:_save(payload)
    local salt = from_hex(payload.salt)
    local nonce = self.random(16)
    local key = self:_derive_key(salt)
    local plaintext = json.encode({ accounts = payload.accounts })
    local ciphertext = crypt(key, nonce, plaintext)
    local mac = hmac_sha256(key,
        "wereader-secret-vault-v1\0" .. nonce .. ciphertext)
    local envelope = json.encode({
        format = 1,
        salt = payload.salt,
        nonce = to_hex(nonce),
        ciphertext = to_hex(ciphertext),
        mac = to_hex(mac),
    })
    local temp = self.path .. ".tmp"
    local handle = assert(io.open(temp, "wb"))
    handle:write(envelope)
    handle:close()
    assert(os.execute("chmod 600 " .. shell_quote(temp)) == 0,
        "secret_store: cannot protect temporary vault")
    assert(os.rename(temp, self.path), "secret_store: atomic vault replace failed")
end

function SecretStore:get(account_id, key)
    validate_name(account_id, "account id")
    assert(ALLOWED_KEYS[key], "secret_store: key is not allowed")
    local account = self:_load().accounts[account_id]
    return account and account.values[key] or nil
end

function SecretStore:set(account_id, key, value)
    validate_name(account_id, "account id")
    assert(ALLOWED_KEYS[key], "secret_store: key is not allowed")
    local payload = self:_load()
    local account = payload.accounts[account_id]
        or { version = 0, values = {} }
    account.values[key] = value
    account.version = account.version + 1
    payload.accounts[account_id] = account
    self:_save(payload)
    return true
end

function SecretStore:delete(account_id, key)
    validate_name(account_id, "account id")
    assert(ALLOWED_KEYS[key], "secret_store: key is not allowed")
    local payload = self:_load()
    local account = payload.accounts[account_id]
    if account and account.values[key] ~= nil then
        account.values[key] = nil
        account.version = account.version + 1
        self:_save(payload)
    end
    return true
end

function SecretStore:version(account_id)
    validate_name(account_id, "account id")
    local account = self:_load().accounts[account_id]
    return account and account.version or 0
end

return SecretStore

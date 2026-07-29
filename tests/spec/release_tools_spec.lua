local root = "/tmp/wereader-release-tools-test"
os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root .. "/stage/sub")
local file = assert(io.open(root .. "/stage/sub/file.txt", "wb"))
file:write("stable\n")
file:close()
os.execute("chmod 755 " .. root .. "/stage/sub/file.txt")

local zip_tool = "python3 tools/packaging/deterministic_zip.py"
assert(os.execute(zip_tool .. " " .. root .. "/stage "
    .. root .. "/one.zip --epoch 0") == 0)
assert(os.execute(zip_tool .. " " .. root .. "/stage "
    .. root .. "/two.zip --epoch 0") == 0)
local function hash(path)
    local pipe = assert(io.popen(
        "(command -v sha256sum >/dev/null 2>&1"
        .. " && sha256sum " .. path
        .. " || shasum -a 256 " .. path .. ")"))
    local value = pipe:read("*a"):match("^(%x+)")
    pipe:close()
    return value
end
assert(hash(root .. "/one.zip") == hash(root .. "/two.zip"),
    "deterministic archives must be byte-identical")

assert(os.execute("python3 tools/packaging/generate_release_metadata.py"
    .. " --lock third_party/dependencies.lock"
    .. " --output-dir " .. root .. "/metadata"
    .. " --version 1.2.3 --abi kindle-armv7") == 0)
local json = require("weread.lib.json")
local sbom_file = assert(io.open(root .. "/metadata/sbom.spdx.json", "rb"))
local sbom = json.decode(sbom_file:read("*a"))
sbom_file:close()
assert(sbom.spdxVersion == "SPDX-2.3")
assert(#sbom.packages == 5)
for index = 2, #sbom.packages do
    local checksums = sbom.packages[index].checksums
    assert(type(checksums) == "table" and checksums[1]
        and checksums[1].algorithm == "SHA256"
        and #checksums[1].checksumValue == 64,
        "every locked dependency must carry a SHA-256 checksum")
end

local redactor = "platform/kindle/package/redact_stream.sh"
local input = assert(io.open(root .. "/sensitive.txt", "wb"))
local fake_secret = string.rep("s", 26)
input:write("Authorization: Bearer " .. fake_secret .. "\n")
input:write("wr_rt=" .. fake_secret .. "\n")
input:write("x-wrpa-0: " .. fake_secret .. "\n")
input:write("https://weread.qq.com/path?ticket=" .. fake_secret .. "\n")
input:write("peer=192.168.1.22\n")
input:write("ordinary line\n")
input:close()
assert(os.execute(redactor .. " < " .. root .. "/sensitive.txt > "
    .. root .. "/redacted.txt") == 0)
local output_file = assert(io.open(root .. "/redacted.txt", "rb"))
local output = output_file:read("*a")
output_file:close()
assert(not output:find(fake_secret, 1, true))
assert(not output:find("192.168.1.22", 1, true))
assert(output:find("ordinary line", 1, true))

local function write_file(path, contents)
    local handle = assert(io.open(path, "wb"))
    handle:write(contents)
    handle:close()
end

-- Exercise the updater against a disposable installation. A checksum failure
-- must leave the current version untouched; a verified archive must activate
-- atomically and leave a first-launch rollback marker.
local install = root .. "/install"
local current = install .. "/wereader"
assert(os.execute("mkdir -p " .. current .. " " .. root
    .. "/next/wereader/bin " .. root .. "/fake-bin") == 0)
assert(os.execute("cp platform/kindle/package/update.sh "
    .. current .. "/update.sh") == 0)
write_file(current .. "/old-marker", "old\n")
write_file(root .. "/next/wereader/launch.sh", "#!/bin/sh\nexit 0\n")
write_file(root .. "/next/wereader/menu.json", "{}\n")
write_file(root .. "/next/wereader/version.json",
    '{"version":"2.0.0","abi":"kindle-armv7"}\n')
write_file(root .. "/next/wereader/bin/luajit", "#!/bin/sh\nexit 0\n")
assert(os.execute(zip_tool .. " " .. root .. "/next/wereader "
    .. root .. "/update.zip --epoch 0") == 0)
write_file(root .. "/update.zip.sha256",
    hash(root .. "/update.zip") .. "  update.zip\n")
write_file(root .. "/wrong.sha256", string.rep("0", 64) .. "  update.zip\n")
write_file(root .. "/update.zip.minisig", "untrusted test signature\n")
write_file(root .. "/update-public.key", "untrusted test public key\n")
write_file(root .. "/fake-bin/minisign", "#!/bin/sh\nexit 0\n")
assert(os.execute("chmod 755 " .. current .. "/update.sh "
    .. root .. "/fake-bin/minisign") == 0)

local update_command = "PATH=" .. root .. "/fake-bin:$PATH "
    .. current .. "/update.sh " .. root .. "/update.zip "
local update_inputs = " " .. root .. "/update.zip.minisig "
    .. root .. "/update-public.key"
assert(os.execute(update_command .. root .. "/wrong.sha256"
    .. update_inputs .. " >/dev/null 2>&1") ~= 0)
local old_marker = io.open(current .. "/old-marker", "rb")
assert(old_marker, "checksum rejection must preserve the current install")
old_marker:close()

assert(os.execute(update_command .. root .. "/update.zip.sha256"
    .. update_inputs .. " >/dev/null") == 0)
local activated = io.open(current .. "/version.json", "rb")
assert(activated, "verified update must be activated")
local activated_version = activated:read("*a")
activated:close()
assert(activated_version:find('"version":"2.0.0"', 1, true))
local pending = io.open(current .. "/.update-pending", "rb")
assert(pending, "activated update must retain a rollback marker")
local previous = pending:read("*l")
pending:close()
assert(previous and previous:match("/wereader%.previous%."))
local previous_marker = io.open(previous .. "/old-marker", "rb")
assert(previous_marker, "the previous version must remain recoverable")
previous_marker:close()

-- First-launch failure must move the bad binary tree aside and restore the
-- updater's previous-version directory without touching the shared data.
local rollback = root .. "/rollback"
local rollback_current = rollback .. "/extensions/wereader"
local rollback_previous = rollback
    .. "/extensions/wereader.previous.20260728-120000"
assert(os.execute("mkdir -p " .. rollback_current .. "/bin "
    .. rollback_current .. "/app " .. rollback_previous) == 0)
assert(os.execute("cp platform/kindle/package/launch.sh "
    .. rollback_current .. "/launch.sh") == 0)
assert(os.execute("cp platform/kindle/package/redact_stream.sh "
    .. rollback_current .. "/redact_stream.sh") == 0)
write_file(rollback_current .. "/bin/luajit", "#!/bin/sh\nexit 9\n")
write_file(rollback_current .. "/app/app.lua", "return true\n")
write_file(rollback_current .. "/.update-pending", rollback_previous .. "\n")
write_file(rollback_previous .. "/restored-marker", "previous\n")
assert(os.execute("chmod 755 " .. rollback_current .. "/launch.sh "
    .. rollback_current .. "/redact_stream.sh "
    .. rollback_current .. "/bin/luajit") == 0)
assert(os.execute("WEREADER_KEEP_FRAMEWORK=1 WEREADER_DATA_DIR="
    .. rollback .. "/data " .. rollback_current
    .. "/launch.sh >/dev/null 2>&1") ~= 0)
local restored = io.open(rollback_current .. "/restored-marker", "rb")
assert(restored, "failed first launch must restore the previous version")
restored:close()
local failed_copy = assert(io.popen(
    "find " .. rollback .. "/extensions -maxdepth 1"
    .. " -type d -name 'wereader.failed.*' -print -quit"))
assert(failed_copy:read("*l"), "failed binary tree must be retained for diagnosis")
failed_copy:close()

os.execute("rm -rf " .. root)
print("release tools: 21 checks, 0 failures")

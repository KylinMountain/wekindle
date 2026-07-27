-- weread-core JSON port shim.
--
-- Resolution order:
--   1. `json`      — KOReader's bundled JSON module
--   2. `rapidjson` — LuaJIT rapidjson binding (KOReader alternative)
--   3. `dkjson`    — pure-Lua fallback for the Linux simulator and tests
--
-- The standalone C++ host is expected to provide a native `json` module via
-- package.preload before any weread-core module is loaded (see
-- core/contracts/ports.md).

local candidates = { "json", "rapidjson", "dkjson" }

for _, name in ipairs(candidates) do
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table"
        and type(mod.encode) == "function"
        and type(mod.decode) == "function" then
        return mod
    end
end

error("weread.lib.json: no JSON implementation available " ..
      "(tried json, rapidjson, dkjson); the platform layer must provide one")

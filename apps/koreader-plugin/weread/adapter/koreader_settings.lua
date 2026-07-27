-- KOReader IStorage adapter: builds weread-core Settings on top of
-- KOReader's LuaSettings + DataStorage paths.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Settings = require("weread.lib.settings")

local M = {}

local function ensure_dir(path)
    if not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
end

function M.new()
    local data_dir = DataStorage:getFullDataDir() .. "/weread"
    ensure_dir(data_dir)
    return Settings:new{
        store = LuaSettings:open(DataStorage:getSettingsDir() .. "/weread.lua"),
        data_dir = data_dir,
        ensure_dir = ensure_dir,
    }
end

return M

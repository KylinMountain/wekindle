-- Terminal QR login flow for the standalone app.
-- Ports the protocol from the KOReader plugin's qr_login.lua:
-- skills page -> getLoginUid -> QR display -> getLoginInfo polling
-- -> userInfo + apikeyGet -> settings:update_auth.

local Cookie = require("weread.lib.cookie")
local WeRead = require("weread.lib.protocol")
local QR = require("qr")

local BASE_URL = "https://weread.qq.com"
local SKILLS_PAGE_URL = BASE_URL .. "/r/weread-skills"
local LOGIN_UID_URL = BASE_URL .. "/api/auth/getLoginUid"
local LOGIN_INFO_URL = BASE_URL .. "/api/auth/getLoginInfo"
local USER_INFO_URL = BASE_URL .. "/api/userInfo"
local API_KEY_URL = BASE_URL .. "/api/skills/apikeyGet?only_show=1"

local SESSION_TIMEOUT_SECONDS = 300
local POLL_INTERVAL_SECONDS = 1.5

local M = {}

local function header_value(headers, name)
    local target = name:lower()
    for key, value in pairs(headers or {}) do
        if type(key) == "string" and key:lower() == target then
            if type(value) == "table" then
                return value[1]
            end
            return value
        end
    end
    return nil
end

local function merge_response_cookies(cookies, headers)
    local set_cookie = header_value(headers, "set-cookie")
    if set_cookie then
        return Cookie.merge_set_cookie(cookies or {}, set_cookie)
    end
    return cookies or {}
end

local function is_timeout_error(err)
    local text = tostring(err or ""):lower()
    return text:find("timeout", 1, true) ~= nil
        or text:find("wantread", 1, true) ~= nil
end

-- Phase 1 of the QR login: establish the cookie context and fetch the login
-- UID. Returns a context table for poll_once/complete.
function M.begin_login(client)
    -- 1. establish the login cookie context
    local _, page_code, page_headers = client:request_follow{
        url = SKILLS_PAGE_URL,
        method = "GET",
        skip_cookie = true,
        maxredirects = 5,
        timeout = { 10, 20 },
        headers = {
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = BASE_URL .. "/",
        },
    }
    if not page_code or page_code < 200 or page_code >= 300 then
        error("cannot open WeRead login page (HTTP " .. tostring(page_code) .. ")")
    end
    local cookies = merge_response_cookies({}, page_headers)

    -- 2. login UID
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = SKILLS_PAGE_URL,
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    local body, code = client:request{
        url = LOGIN_UID_URL,
        method = "GET",
        skip_cookie = true,
        timeout = { 10, 20 },
        headers = headers,
    }
    if not code or code < 200 or code >= 300 then
        error("getLoginUid failed (HTTP " .. tostring(code) .. ")")
    end
    local data = client:json_decode(body)
    if type(data.uid) ~= "string" or data.uid == "" then
        error("WeRead did not return a valid login UID")
    end

    return {
        cookies = cookies,
        uid = data.uid,
        confirm_url = BASE_URL .. "/web/confirm?uid=" .. WeRead.urlencode(data.uid),
        started = os.time(),
    }
end

-- One polling round. Returns "pending" | "success" | "expired" | "error",
-- plus the server payload (or error text).
function M.poll_once(client, ctx, otp)
    local url = LOGIN_INFO_URL .. "?uid=" .. WeRead.urlencode(ctx.uid) .. "&otp"
    if type(otp) == "string" and otp ~= "" then
        url = url .. "=" .. WeRead.urlencode(otp)
    end
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = SKILLS_PAGE_URL,
    }
    local cookie_header = Cookie.to_header(ctx.cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    local ok, body, code, resp_headers = pcall(function()
        return client:request{
            url = url,
            method = "GET",
            skip_cookie = true,
            timeout = { 8, 12 },
            headers = headers,
        }
    end)
    if not ok then
        if is_timeout_error(body) then
            return "pending"
        end
        return "error", body
    end
    if not code or code < 200 or code >= 300 then
        return "pending"
    end
    ctx.cookies = merge_response_cookies(ctx.cookies, resp_headers)
    local data = client:json_decode(body)
    if data.succeed == true then
        return "success", data
    end
    local logic_code = tostring(data.logicCode or "")
    if logic_code == "NEED_OTP" then
        return "need_otp"
    elseif logic_code == "LOGIN_TIMEOUT" or logic_code == "OTP_EXPIRED" then
        return "expired"
    elseif logic_code == "OTP_NOT_MATCH" then
        return "otp_mismatch"
    end
    return "pending"
end

-- client: weread.lib.client instance; sleep_fn: optional seconds sleep fn
function M.login(client, settings, sleep_fn)
    io.stdout:setvbuf("line")  -- QR/prompt must appear even when piped
    local ctx = M.begin_login(client)
    ctx.sleep_fn = sleep_fn

    -- 3. display the QR code
    print("\n用微信扫描下面的二维码登录微信读书：\n")
    print(QR.to_terminal(QR.encode_to_matrix(ctx.confirm_url)))
    print("\n" .. ctx.confirm_url .. "\n")

    -- 4. poll for confirmation (optionally with OTP on second round)
    local result
    local otp
    local deadline = os.time() + SESSION_TIMEOUT_SECONDS
    while os.time() < deadline do
        local status, payload = M.poll_once(client, ctx, otp)
        if status == "success" then
            result = payload
            break
        elseif status == "need_otp" or status == "otp_mismatch" then
            io.stdout:write(status == "need_otp"
                and "需要验证码，请输入微信读书 App 中显示的 4 位数字："
                or  "验证码不正确，请重新输入：")
            otp = io.read("l")
            if not otp then
                error("login cancelled")
            end
        elseif status == "expired" then
            error("二维码已过期，请重新运行 login")
        elseif status == "error" then
            error(payload)
        end
        if sleep_fn then
            sleep_fn(POLL_INTERVAL_SECONDS)
        end
    end
    if type(result) ~= "table" or result.succeed ~= true then
        error("login did not succeed")
    end

    -- 5. complete: userInfo + API key
    return M.complete(client, settings, ctx, result)
end

-- Final phase: exchange the poll result for account credentials + API key
-- and persist them.
function M.complete(client, settings, ctx, result)
    local web_login_vid = tostring(result.webLoginVid or "")
    local access_token = tostring(result.accessToken or "")
    local refresh_token = tostring(result.refreshToken or "")
    if web_login_vid == "" or access_token == "" then
        error("login response is missing account credentials")
    end

    local account_cookies = {}
    for k, v in pairs(ctx.cookies or {}) do
        account_cookies[k] = v
    end
    account_cookies.wr_vid = web_login_vid
    account_cookies.wr_skey = access_token
    account_cookies.wr_ql = "0"
    if refresh_token ~= "" then
        account_cookies.wr_rt = WeRead.urlencode(refresh_token)
    end

    local auth_headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = SKILLS_PAGE_URL,
        ["Cookie"] = Cookie.to_header(account_cookies),
        ["X-Vid"] = web_login_vid,
        ["X-Skey"] = access_token,
    }
    local function authenticated_get(url, stage)
        local b, c = client:request{
            url = url,
            method = "GET",
            skip_cookie = true,
            timeout = { 10, 20 },
            headers = auth_headers,
        }
        if not c or c < 200 or c >= 300 then
            error(stage .. " failed (HTTP " .. tostring(c) .. ")")
        end
        return client:json_decode(b)
    end

    local user_info = authenticated_get(
        USER_INFO_URL .. "?userVid=" .. WeRead.urlencode(web_login_vid), "userInfo")

    local api_key = ""
    for attempt = 1, 3 do
        local api_result = authenticated_get(API_KEY_URL, "apikeyGet")
        api_key = type(api_result.apikey) == "string" and api_result.apikey or ""
        if api_key ~= "" then
            break
        end
        if attempt < 3 and ctx.sleep_fn then
            ctx.sleep_fn(0.5)
        end
    end
    if api_key == "" then
        error("未返回官方 API Key。请先在微信读书 App 开启「微信读书 Skill」（我 → 设置 → 微信读书 Skill → 获取 API Key)，然后重新扫码。")
    end

    local account = {
        name = type(user_info.name) == "string" and user_info.name or "",
        user_vid = web_login_vid,
        login_method = "qr",
        login_time = os.time(),
    }
    settings:update_auth({
        cookies = account_cookies,
        api_key = api_key,
        wr_ticket = "",
        wr_wrpa = "",
        account = account,
    }, { replace_cookies = true })
    print("登录成功：" .. (account.name ~= "" and account.name or web_login_vid))
    return account
end


return M

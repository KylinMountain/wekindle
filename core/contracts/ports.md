# weread-core 端口接口契约

> 对应设计文档 §3.1「端口与适配器」与附录 A。weread-core 只依赖这里定义的接口；
> KOReader 插件、独立 C++ Host、测试 Mock 各自提供适配器实现。
>
> 本文档是 Lua duck-typing 约定：一个表（table）实现了列出的方法即视为实现了端口。
> 所有端口通过构造函数或 `options` 表注入，核心模块**禁止**直接 `require` 平台模块。

## 通用约定

- **错误返回**：同步接口返回 `nil, err`；`err` 为字符串错误码（见 §6.6 错误分类），
  可选第三个返回值为人可读详情。禁止把异常抛出到调用方栈之外（协程边界处必须 pcall）。
- **敏感数据**：任何端口实现不得在日志中输出 Cookie、API Key、`x-wrpa-*` Header。
- **大数据**：正文、图片等只传文件路径或句柄，不在 Lua/C++ 边界复制大字符串。
- **取消**：长操作接收 `cancel_token`（见 IScheduler），被取消时返回 `nil, "cancelled"`。

## ILogger — 已实现（`weread.lib.log`）

```lua
logger.dbg(...)  logger.info(...)  logger.warn(...)  logger.err(...)
logger.setLevel("dbg"|"info"|"warn"|"err")   -- 可选
```

- KOReader 适配：直接委托 KOReader `logger` 模块（shim 自动检测）。
- 独立 Host 适配：通过 `package.preload["logger"]` 注入 C++ 日志管道；
  未注入时 shim 退化为 stderr（warn 及以上）。

## IJson — 已实现（`weread.lib.json`）

```lua
json.encode(value) -> string
json.decode(text) -> value
```

- 解析顺序：`json`（KOReader）→ `rapidjson` → `dkjson`（开发/测试）。
- 独立 Host 应在加载任何核心模块前通过 `package.preload["json"]` 注入原生实现。

## IHttpClient — 待适配（当前 `weread.lib.client` 直连 socket.http）

```lua
http:request{
    method = "GET"|"POST",
    url = string,
    headers = { ["Name"] = "value", ... },
    body = string | nil,               -- 请求体；大请求体用 body_path
    body_path = string | nil,          -- 大请求体文件路径
    sink_path = string | nil,          -- 响应体落盘路径（流式下载）
    connect_timeout = seconds,
    total_timeout = seconds,
    max_bytes = number | nil,          -- 响应大小上限，超出返回 "too_large"
    credential_scope = string,         -- "weread" | "none"：跨域重定向时凭据作用域
    cancel_token = CancelToken | nil,
} -> response | nil, err

response = {
    status = number,                   -- HTTP 状态码
    headers = { [lower_name] = value }, -- 响应头（含 set-cookie 原始列表）
    body = string | nil,               -- 未指定 sink_path 时的响应体
}
```

语义要求：

- 跨域重定向必须移除 `Authorization`、`Cookie`、`Origin` 和 `x-wrpa-*`（设计文档 §6.6）。
- 只允许 HTTPS；实现方负责 TLS 证书校验，不提供「忽略证书错误」开关。
- KOReader 适配器：包装现有 `socket.http` + `socketutil`。
- 独立 Host 适配器：C++ libcurl 实现，经 LuaJIT FFI 暴露。

## IStorage

```lua
storage:transaction() -> txn
txn:put_metadata(key, value_json)     -- 元数据写入（暂存）
txn:stage_file(tmp_path, final_path)  -- 内容文件暂存
txn:commit() -> ok, err               -- 先 fsync 文件，后提交元数据
txn:rollback()
storage:get_metadata(key) -> value_json | nil
storage:read_file(path) -> string | nil, err
storage:write_file_atomic(path, data) -> ok, err   -- 临时文件 + rename
storage:free_space(path) -> bytes
storage:stat(path) -> { size=, mtime=, kind="file"|"dir" } | nil
```

一致性不变量：**先文件临时写、后数据库事务提交**（设计文档 §11.1）。
KOReader 适配器：LuaSettings + lfs。独立 Host：SQLite + 文件系统。
vfat 上数据库固定 `journal_mode=DELETE`（设计文档 §3.2）。

## ISecretStore

```lua
secrets:get(account_id, key) -> value | nil
secrets:set(account_id, key, value) -> ok, err
secrets:delete(account_id, key)
secrets:version(account_id) -> number
```

- 独立 Host 实现必须位于 rootfs ext 分区（非 `/mnt/us`），`0600`/`0700`，
  并用设备序列号派生密钥静态加密（设计文档 §12.1）。
- 允许写入的 key 白名单：`wr_skey`、`wr_rt`、`wr_vid`、`wr_ticket`、`api_key`、`x-wrpa-*`。

## IScheduler

```lua
scheduler:call_later(seconds, fn) -> CancelToken
scheduler:call_periodic(seconds, fn) -> CancelToken
scheduler:run_background(label, fn)   -- IO/CPU 任务离开主线程
token:cancel()
token:cancelled() -> bool
```

- KOReader 适配器：`UIManager:scheduleIn`（最小 0.1s，禁止 0）。
- 独立 Host：C++ 定时器堆 + 工作线程池，UI 线程只接收完成回调。

## IArchiver — 待适配（当前 `content.lua` 内嵌 `ffi/archiver`）

```lua
archiver:open_tar(path) -> archive | nil, err
archive:entries() -> iterator of { name=, size=, kind= }
archive:extract_to(dir, opts) -> ok, err
```

安全不变量（设计文档 §12.2）：拒绝绝对路径、`..` 穿越、符号链接、设备文件；
单文件与总解压大小有上限。

## IDevice — 仅独立 Host 需要（插件侧由 KOReader 提供）

```lua
device:prevent_suspend(reason) / device:allow_suspend(reason)
device:is_online() / device:on_connectivity_changed(fn)
device:free_space() / device:device_id()     -- 用于 SecretStore 密钥派生
device:firmware_info()
```

## IReaderEngine — Phase 1+ 需要

```lua
engine:open(xhtml_path) -> doc | nil, err
doc:page_count() -> number
doc:render_page(index) -> bitmap_handle
doc:xpointer_at(text_offset) -> string | nil
doc:text_offset_at(xpointer) -> number | nil
doc:close()
```

独立 Host 由 crengine 经 ReaderBridge 实现；xpointer 持久化时必须记录
引擎版本号，版本变化后回退 CanonicalPosition 重定位（设计文档 §9.3）。

## 适配器状态矩阵

| 端口 | 契约 | KOReader 适配器 | Mock 适配器 | Standalone 适配器 |
|---|---|---|---|---|
| ILogger | ✅ 本文档 | ✅ `weread.lib.log` shim | ✅ stderr fallback | Phase 1 |
| IJson | ✅ 本文档 | ✅ `weread.lib.json` shim | ✅ vendored dkjson | Phase 1（原生） |
| IHttpClient | ✅ 本文档 | ✅ `weread/adapter/socket_transport.lua` | ✅ `platform/mock/mock_transport.lua` | Phase 1 |
| IStorage | ✅ 本文档 | ⬜ settings 仍在插件侧 | ⬜ | Phase 1 |
| ISecretStore | ✅ 本文档 | ⬜ | ⬜ | Phase 2 |
| IScheduler | ✅ 本文档 | ⬜ downloader 仍直连 UIManager | ⬜ | Phase 1 |
| IArchiver | ✅ 本文档 | ✅ ffi/archiver fallback + `Content.set_zip_writer_factory` | ⬜ | Phase 1 |
| IDevice | ✅ 本文档 | n/a（KOReader 原生） | ⬜ | Phase 2 |
| IReaderEngine | ✅ 本文档 | n/a | ⬜ | Phase 1+ |

已迁入 core 的模块：protocol、crypto、cookie、position_mapper、reader_state、
book_reviews、read_stats、scan、annotations、thought_db、book_store、
progress_sync、client、content、read_report、thoughts。
仍在插件侧的模块：downloader、settings、qr_login、reader_lifecycle、
plugin_util、mixin、migrations、i18n（均为 KOReader 设备/UI/存储耦合层）。

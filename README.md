# Wereader

Kindle 上的独立微信读书客户端。设计文档见 [docs/Wereader_Standalone_Design_v0.1.md](docs/Wereader_Standalone_Design_v0.1.md)。

## 仓库结构

```
core/
  lua/weread/lib/    weread-core：平台无关的协议、内容、同步核心（LuaJIT）
  contracts/         端口接口契约（ports.md）
apps/
  koreader-plugin/   现有 KOReader 插件（vendored 自 finlater/weread.koplugin，
                     AGPL-3.0，作为 weread-core 的 KOReader 适配器）
  standalone/        独立应用：cli.lua（命令行）、app.lua（LVGL 图形界面）、
                     bootstrap.lua（适配器装配）、login.lua（QR 登录流）
platform/
  standalone/        libcurl/SQLite/ZIP/QR 的 LuaJIT FFI 适配器
  linux/             LVGL + crengine 桥（reader_bridge.lua、lv.lua）
  mock/              测试用端口 Mock 适配器
reader/
  crengine_bridge/   crengine C 桥（libcrbridge，KOReader crengine fork）
tests/
  spec/              核心模块单测（无需 KOReader 环境）
  fixtures/          协议固定向量（由 tools/fixtures 生成，勿手改）
tools/
  fixtures/          golden vector 生成器（以 Python 参考脚本为协议 oracle）
  build/             build_crbridge.sh（crengine 桥构建）
  smoke/             stub server 端到端冒烟
docs/                设计文档
```

## 构建

```sh
# Lua 层测试只需要 luajit（brew install luajit）
tests/run_all.sh          # 单元测试（17 个 spec）
tests/run_smoke.sh        # stub server 端到端冒烟

# crengine 桥（libcrbridge）依赖 cmake/ninja 与 brew 库：
# freetype harfbuzz fribidi libpng jpeg-turbo zstd libunibreak fontconfig xxhash gettext
tools/build/build_crbridge.sh

# LVGL（liblvgl，SDL2 + freetype）
cmake -G Ninja -S platform/linux/lvgl_build -B platform/linux/lvgl_build/build
cmake --build platform/linux/lvgl_build/build
```

## 运行

```sh
# 命令行（登录、书架、下载、导出）
luajit apps/standalone/cli.lua login
luajit apps/standalone/cli.lua shelf
luajit apps/standalone/cli.lua download <book_id>
luajit apps/standalone/cli.lua cache <book_id>
luajit apps/standalone/cli.lua export <book_id> out.epub

# LVGL 图形界面（登录 → 书架 → 阅读）
luajit apps/standalone/app.lua
luajit apps/standalone/app.lua --selftest   # CI 启动自检（300 帧后退出）

# 重新生成协议 golden vectors（以 Python 参考实现为 oracle）
python3 tools/fixtures/gen_protocol_vectors.py > tests/fixtures/protocol_vectors.lua
```

凭据存放在 `~/.wereader/`（SQLite）；Canonical Cache 在 `~/.wereader/cache/canonical/`。

## 许可证

本仓库包含的 `apps/koreader-plugin/` 为 AGPL-3.0-only 授权代码（保留原 LICENSE/NOTICE），
crengine 为 GPLv2+，LVGL 为 MIT，整体分发时需遵守相应条款，详见设计文档 §12.4。

# wekindle 任务交接文档

最后更新：2026-07-30

## 1. 项目是什么

把微信读书（WeRead）做成**独立的 Kindle 原生应用**，不依赖 Amazon 账号/服务。
背景：Kindle 中国 2023 停书店、2024 停云下载，国内存量 Kindle 成了没有官方内容源的
孤儿设备。目标用户就是这批已越狱的存量设备（越狱是分发前提，不是风险妥协）。

技术栈：LuaJIT（业务）+ LVGL（UI）+ crengine（排版，KOReader fork）+ FBInk（e-ink 驱动）
+ libcurl（网络）+ SQLite（本地存储）。协议核心 weread-core 提取自
`finlater/weread.koplugin`，桌面 CLI、KOReader 插件、独立 App 三个宿主共用。

仓库：`git@home:KylinMountain/wekindle.git`（个人项目，提交身份 KylinMountain
<kose2livs@gmail.com>）。

## 2. 当前状态（2026-07-30）

### 能工作的
- 桌面端全流程：登录（扫码）→ 书架 → 开书 → 阅读，28 个 spec 套件全绿（`sh tests/run_all.sh`）
- **真机（PW4）**：登录、书架封面网格（3 列、封面缓存、大字号、可滚动、可退出）、
  开书阅读（章节目录/翻页/排版/亮度）、崩溃后 launch.sh 恢复系统界面
- 登录态、书架、封面、章节均有本地缓存，支持离线

### 真机验证过但待复验的
- 熄屏唤醒重绘（代码已修，未在真机走完 suspend→wake 全流程）
- 触摸翻页/按钮（evdev 已通，但阅读页交互没系统过一遍）

### 明确待办（按优先级）
1. **KUAL 菜单入口不显示**（menu.json 已部署但 KUAL 列表没有；参照 KOReader 的
   extensions/koreader/menu.json 格式修，可能要 action 绝对路径 + exitmenu 字段）
2. 阅读页交互升级：点中央呼出工具栏（返回/目录/亮度/排版/进度条）、翻页热区、
   翻页防抖 300ms（见 `docs/ui-design-kindle.md`）
3. e-ink 刷新调优：翻页目前用 FBInk 默认波形（AUTO），应切 DU 提速；每 12 页全刷
   防残影已有（WK_AUTO_FULL_REFRESHES）
4. 清理调试打印（curl_transport 的 `[ct]`、kindle_host.c 的 `[wk]` DBG、cr_bridge 的
   `[crb]`）——崩溃抓完就可以撤，或改成环境变量开关
5. 产品命名：wereader/weread 有腾讯商标风险，待决（设计文档 待决 #9）

### 当前真机上的坑
- `preventScreenSaver` 调试时设过 1，记得测完还原：`lipc-set-prop com.lab126.powerd preventScreenSaver 0`
- 设备包在 `/mnt/us/extensions/wereader/`，数据在 `/mnt/us/extensions/wereader-data/`
- 启动入口 launch.sh 带 `-joff`（见下「坑 1」），会自动停/恢复 Kindle 框架

## 3. 仓库结构

```
core/lua/weread/lib/     weread-core 18 模块（协议/缓存/下载/设置），宿主无关
core/contracts/ports.md  9 个端口契约（IHttpClient/IStorage/IDevice/...）
apps/standalone/         独立 App（app.lua 主 UI、bootstrap、cli、login、book_service 等）
apps/koreader-plugin/    KOReader 插件宿主
platform/
  ui_backend.lua         显示后端选择（kindle → FBInk，其他 → SDL 桌面窗口）
  kindle/                backend.lua（FFI）、device.lua（LIPC/电源）、
    host/                kindle_host.c（FBInk+evdev+LVGL 显示驱动 + JPEG 解码）
    package/             launch.sh、menu.json、update.sh 等打包文件
  linux/                 lv.lua（LVGL FFI）、reader_bridge.lua（crbridge FFI）、lvgl_build/
  standalone/            curl_transport、sqlite_store、zip_writer、qr、secret_store
reader/crengine_bridge/  cr_bridge.cpp（crengine C API）、cr_test.cpp（诊断工具）
tools/build/             交叉编译脚本（见 §5）
tools/packaging/         打包/签名/发布脚本
tests/                   28 个 spec + fixtures + smoke
docs/                    设计文档、官方 APK 分析、UI 设计、本文档
```

## 4. 血泪换来的六个大坑（都修过，别重蹈）

### 坑 1：LuaJIT armv7 JIT 段错误
JIT 编译的 mcode 在 PW4 上段错误（core 显示 PC 在匿名可执行页）。**launch.sh 必须
`-joff`**。重活都在 C 层，性能无感。已固化。

### 坑 2：antiword stdio 符号拦截（开书必崩的根因，2026-07-30 修）
不定义 `CR3_ANTIWORD_PATCH=1` 时，antiword.h 把 `aw_rewind` 宏成 libc `rewind`，
wordfmt.cpp 的包装函数被导出成全局 `rewind` 符号。antiword 格式嗅探器对**每个文档**
都跑，拿的是 crengine 的假 `FILE*`（LVStream 指针强转）。链到哪个 `rewind` 取决于
ELF 加载顺序：cr_test 直链 libcrbridge（在 libc 前）→ 包装函数赢 → 不崩；app 经
LuaJIT FFI dlopen（在 libc 后）→ libc rewind 赢 → 假 FILE 崩。**桌面永远不会崩，
只有设备 app 上下文崩**。修复：crbridge CMakeLists `add_definitions(-DCR3_ANTIWORD_PATCH=1)`，
antiword 经 build 脚本 `-DCMAKE_C_FLAGS=-DCR3_ANTIWORD_PATCH=1`（third_party 不进仓库，
宏只能由构建脚本注入）。教训：**「cr_test 通过但 app 崩」先怀疑符号拦截/加载顺序**。

### 坑 3：LuaJIT FFI 回调名额
批量控件（423 格书架）每格一个回调 → 重建几次 `too many callbacks` 崩。
**批量控件共享一个回调 + user_data 传索引**（app.lua 的 state.cell_cb / state.toc_cb）。

### 坑 4：Lua 前向 local 声明
`local function` 定义在后、引用在前 → 引用静默绑定到全局 nil，运行时才炸
（build_shelf_grid、begin_reading 都踩过）。前置 `local x` 声明。

### 坑 5：系统 libcurl 与 LibreSSL
KOReader 带的是 LibreSSL 4.2.1（libssl.so.60），不是 OpenSSL 3——curl 必须用
LibreSSL 头编译，否则缺 `OSSL_LIB_CTX_*` 符号。设备 `/usr/lib/libcurl.so` 是坏的
（easy_cleanup 段错误），必须 `CURL_TRANSPORT_PATH` 显式指向包内 libcurl。
CA 用系统 `/etc/ssl/certs/ca-certificates-prod.crt`（launch.sh 已配）。

### 坑 6：fb stride ≠ 屏宽
PW4 fb0：1072 宽、stride 1088。fbink_print_raw_data 连续写会每行偏 16px，
kindle_host.c 用 `wk_blit_rows` 按行 mmap 拷贝。抓屏同样要按 1088 抓再裁。

## 5. 构建

### 桌面（macOS，开发主战场）
```sh
sh tools/build/build_crbridge.sh        # crbridge + antiword/chmlib（桌面）
cmake -G Ninja -S platform/linux/lvgl_build -B platform/linux/lvgl_build/build
cmake --build platform/linux/lvgl_build/build
sh tests/run_all.sh                     # 28 个 spec
luajit apps/standalone/app.lua          # SDL 窗口跑 app
```

### 设备（armv7 hard-float）
工具链一次性的准备（已完成，机器在 ~/x-tools/）：
- `~/x-tools/kindlehf` koxtoolchain kindlehf sysroot
- `~/x-tools/src` 各依赖源码（curl/FBInk/freetype/harfbuzz/libjpeg-turbo/libressl/...）
- `~/x-tools/koreader-libs` 从 KOReader 包抠的运行库（libfreetype/libharfbuzz/libssl 等）
- `~/x-tools/stage-hf` 我们编出来的库

```sh
sh tools/build/build_kindle_hf.sh       # 全部 HF 库（zlib/curl/fbink/lvgl/host/antiword/chmlib/crbridge）
# 单独重编 crbridge（改了 cr_bridge.cpp 后）：
. tools/build/xenv-kindlehf.sh  # 然后按 build_kindle_hf.sh 里 crbridge 段的 xcmake 调用
```
注意：build_kindle_hf.sh 会把 HF 的 libantiword.a/libchmlib.a 写进
third_party 构建目录（覆盖桌面版），桌面构建前要用 build_crbridge.sh 重建桌面版。
cr_test 是开书崩溃诊断工具（见 §7）。

## 6. 部署与真机访问

- SSH：`ssh -p 2222 root@192.168.1.6`（无密码，dropbear；WiFi 掉线=设备休眠，先
  `lipc-set-prop com.lab126.powerd preventScreenSaver 1`）
- 部署：改完的文件 cp 到 `/tmp/wereader-deploy/wereader/`（本地镜像），scp 到
  `/mnt/us/extensions/wereader/` 对应位置。**scp 会静默失败**：传到 .new 再 mv +
  md5 双端校验。
- 启动：`cd /mnt/us/extensions/wereader && ./launch.sh`（自动停框架/退出恢复）
- 调试开关：`WEREADER_AUTO_OPEN=1`（开详情）/ `read`（直接进阅读）/
  `WEREADER_NO_COVERS=1`（关封面管线）/ `WEREADER_AUTO_OPEN=read:<bookId>`
- 日志：`/mnt/us/extensions/wereader-data/logs/wereader.log`；崩溃报告在同目录 crash/
- 抓屏：`dd if=/dev/fb0 bs=1088 count=1448` → 裁 stride 转 PGM/PNG（脚本模式见
  会话里的 python 片段，docs 里也可以补一个 tools/device/shot.py）

## 7. 崩溃排查 playbook（这套流程已经跑通三次）

1. launch.sh 有 `ulimit -c unlimited`；设备上先
   `echo '/tmp/core-%e-%p' > /proc/sys/kernel/core_pattern`（vfat 写不了 core）
2. libcrbridge 带 SA_SIGINFO 崩溃处理（WEREADER_CRASH_HANDLER，HF 构建已开），
   signal/fault_addr/pc/lr 直接进 wereader.log
3. 拉 core 回 Mac：`lldb -c core binary` 读寄存器；
   `llvm-readobj --notes core` 解 NT_FILE 映射（**Offset 字段单位是页**，要 ×4096）；
   `llvm-addr2line -f -C -e lib.so 0x偏移` 符号化（部署的 .so 必须和分析的同一个 md5）
4. 设备 libc 和工具链 libc 不同 md5——符号要用 `scp /lib/libc-2.20.so` 拉设备的对
5. 二分顺序：cr_test（C++ 直调）→ ffi_test.lua（纯 FFI）→ app（全上下文），
   哪层开始崩就锁定哪层的问题
6. 堆检查：`MALLOC_CHECK_=3 MALLOC_PERTURB_=42` 环境变量（glibc 自带）

## 8. 设计文档索引

- `docs/Wereader_Standalone_Design_v0.1.md` 总体设计（已评修到 v0.2，命名待决 #9）
- `docs/official-ink-app-analysis.md` 官方微信读书墨水屏 APK 逆向（布局/字号/配色令牌）
- `docs/ui-design-kindle.md` UI/UX 设计 v0.1（导航结构、刷新策略表、性能预算、布局规格）
- `core/contracts/ports.md` 端口契约 + 适配器状态矩阵
- `docs/PHASE_STATUS.md` 各 Phase 状态（接手团队维护）

## 9. 建议的下一步顺序

1. KUAL 入口（小事但用户每次都问）
2. 阅读页工具栏 + 翻页热区（docs/ui-design-kindle.md §1/§4 有规格）
3. 熄屏唤醒真机复验 + 刷新波形调 DU
4. 撤调试打印、把设备包重新用 tools/packaging 正式打一次
5. 命名决策 → 正式发布流程（签名/更新/回滚已有 update.sh 框架）

## 10. 重要上下文（口头传统，文档里没有的）

- 用户要求：**UI 必须对齐官方微信读书墨水屏版**（APK 在 ~/Downloads/2.1.2.10245900_900.apk，
  分析已做）；「以你的审美不应该做成这样」—— 别交半成品 UI
- 用户对崩溃/卡死/白屏零容忍：任何路径都要能退回系统界面，launch.sh 的
  trap 恢复链不许破坏
- 设备 WiFi 不稳 = 休眠省电，不是硬件问题；调试时 preventScreenSaver 1，测完还原
- 对话语言：全程中文；提交信息英文；个人仓库 KylinMountain

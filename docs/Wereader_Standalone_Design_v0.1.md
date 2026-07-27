# Wereader：Kindle 独立微信读书客户端系统设计

> v0.2 Draft · 2026-07-27
>
> v0.2 变更：补充 Kindle 中国退市背景与越狱生态定位；修正 vfat 上 SecretStore/SQLite 设计；注释注入改为渲染/导出后处理层；明确按章模式的进度估算与跨章链接处理；补充 powerd 抑制、账号风控错误类、字体许可与国内分发渠道；待决事项 #2/#8/#9 给出倾向结论。


# 0. 决策摘要

## 0.1 一句话方案

构建一个可在越狱 Kindle 上直接启动的 **Wereader 独立应用**：以 `weread-core` 复用现有项目的登录、API、内容解码、划线与 EPUB 逻辑；以 **LVGL** 实现新的墨水屏产品界面；以 **crengine** 负责 XHTML/EPUB 排版；以 **FBInk + evdev + Kindle LIPC** 完成屏幕、输入、网络和电源适配。运行时不安装、不启动、也不展示 KOReader。

> [!DECISION] KOReader 的价值是已经整合过阅读引擎和设备兼容，但它不是不可替代组件。本项目只复用更底层、职责单一的开源库，产品外壳、导航、书架和阅读体验全部重做。

## 0.2 核心决策

| 决策项 | 结论 | 原因 |
|---|---|---|
| 产品形态 | 独立 Kindle 应用 | 用户点开即进入微信读书书架，不经过文件管理器或插件菜单 |
| KOReader | 不作为运行依赖 | 避免复杂菜单、通用阅读器产品逻辑和 UI 约束 |
| 主程序 | C++17 Native Host | 便于集成 crengine、FBInk、evdev 与 Kindle 系统接口 |
| 业务核心 | LuaJIT `weread-core` | 最大化复用现有 Lua 协议实现，并保持快速迭代能力 |
| UI | LVGL + 自定义 E-ink Theme | 组件、布局成熟，支持嵌入式与电子纸，界面可完全重做 |
| 阅读排版 | crengine | 直接复用成熟的 DOM/XML/CSS 电子书排版能力，而非自己重写通用排版引擎 |
| 内容模型 | Canonical Cache | 阅读器和 EPUB 导出共享同一份规范化章节、CSS、图片与位置映射 |
| API | 官方 Gateway + Web Reader 双适配器 | 官方接口负责元数据；Web Reader 负责完整正文与阅读上报 |
| 首发范围 | 单一参考 Kindle 型号 | 先跑通产品闭环，再扩展设备矩阵，避免一开始陷入固件碎片化 |

## 0.3 MVP 完成标志

> 以下口径对应 Phase 4 完成态；Phase 3 是「阅读闭环」的阶段性里程碑，见 §15。

- 从 KUAL 或等价启动入口直接打开 Wereader，首页就是“继续阅读 + 书架”。
- 微信扫码登录，获得 Web 会话与官方 Skill API Key。
- 加载书架、搜索、书籍详情和目录。
- 支持微信读书 EPUB 内部格式、TXT 内部格式以及公众号文章。
- 支持按章缓存、预取下一章、离线继续阅读和恢复位置。
- 支持整本或选定章节导出为通过校验的 EPUB 3，包含目录、封面、CSS 和本地图片。
- 支持真实阅读时长上报；进度同步在位置映射验证后启用。
- 退出后正确恢复 Kindle 原生界面，不需要重启设备。
- 整个运行路径中不需要 KOReader 安装包、进程或 UI。

## 0.4 文档结构

1. 背景与目标
2. 用户体验与产品边界
3. 总体架构
4. 技术栈与依赖
5. 现有项目复用方案
6. 微信读书 API 与认证
7. 内容获取与规范化
8. EPUB 导出设计
9. 阅读器与位置模型
10. Kindle 设备层
11. 数据、缓存与同步
12. 安全、合规与许可证
13. 测试、构建与发布
14. 分阶段实施与验收
15. 风险与待决事项

[[PAGE_BREAK]]

# 1. 背景与设计目标

## 1.0 为什么是 Kindle 存量设备 + 越狱生态

Kindle 中国已于 2023 年 6 月 30 日停止书店运营、2024 年 6 月 30 日停止云端下载。国内 Kindle 设备从此失去官方内容源，但这批设备存量巨大、墨水屏硬件素质至今不过时，且国内越狱社区（KUAL/MRPI 等）成熟。与此同时，微信读书是国内内容最完整的中文阅读生态。

**把微信读书带到这批被官方弃置的设备上，正是本项目的出发点。** 越狱不是需要妥协的风险，而是产品的分发前提；Amazon 服务的退出反而降低了固件碎片化风险——国内大量设备停留在可越狱固件区间，不再有官方服务驱动的强制升级压力。设备选型因此以「国内二手存量 + 越狱社区教程覆盖 + 可越狱固件区间」为硬指标，而不是追新机型。

## 1.1 当前项目已经具备什么

`finlater/weread.koplugin` 不是一个只有概念的原型。它已经具备以下关键资产：

- 微信扫码登录、Cookie 管理、官方 API Key 获取与续期。
- 官方 Gateway API：书架、搜索、书籍信息、目录、进度、统计、划线与想法。
- Web Reader API：完整章节正文、CSS、资源包、公众号文章和阅读时长上报。
- 微信读书 `_e()` 编码、请求签名、内容分片校验与解码。
- EPUB/TXT 内容判定、图片资源下载、URL 改写和 EPUB 3 组装。
- 划线与想法注入 EPUB、离线展示所需的数据结构。
- 一套“先用 Python 脚本验证协议，再移植到 Lua”的研究与回归方法。

现有代码明确区分两类 API：官方 Gateway 负责书架和元数据，Cookie 认证的 Web API 负责章节内容与阅读上报。[R1][R2] 现有验证脚本已经跑通过整本书、目录、CSS 和图片本地化的 EPUB 生成链路，因此本项目不是从零逆向协议，而是把已经验证的能力产品化。[R3]

## 1.2 当前体验的问题

当前形态是：

```text
Kindle → KOReader → 工具菜单 → 微信读书插件 → 书架 → 下载 EPUB → KOReader 阅读器
```

它的问题主要在产品层，而不是 API 层：

- 启动路径长，用户心智仍然是“先打开 KOReader”。
- 首页、返回栈和阅读结束后的去向由 KOReader 生命周期决定。
- 书架和搜索被实现成插件菜单，难以形成真正的应用级信息架构。
- KOReader 为通用文件阅读器设计，包含大量与微信读书无关的菜单和设置。
- 插件的 UI、调度、存储和设备能力直接依赖 KOReader 模块，无法独立运行。

## 1.3 目标

### 产品目标

- 做成一个“Kindle 上的微信读书客户端”，而不是“KOReader 里的微信读书工具”。
- 首页清楚、层级少、操作路径短，适配电子墨水屏而不是照搬手机 App。
- 默认按需缓存，热点操作不等待网络；需要时可以整本下载或导出 EPUB。
- 保留用户已有的微信读书书架、阅读时间、进度、划线与想法。
- 完全脱离 Amazon 账号与服务：设备无需登录 Amazon，微信扫码即可使用。

### 工程目标

- `weread-core` 与具体 UI、网络库、存储、设备和阅读引擎解耦。
- 同一核心同时允许现有 KOReader 插件继续使用，避免一次性大爆炸重写。
- 所有非公开 Web API 都有脚本验证、固定样本、协议断言和降级策略。
- 阅读缓存和 EPUB 导出使用同一规范化内容，防止两条链路逐渐分叉。
- 首个版本优先稳定运行在一台参考设备，再扩展到更多 Kindle 架构与固件。

### 非功能目标

- 缓存内容可完全离线阅读。
- 网络、下载、导出均可取消、可恢复、可诊断。
- 书籍正文、Cookie、API Key 和反滥用 Header 不进入日志。
- 应用崩溃或断电后，不损坏数据库、阅读位置或已完成章节。
- 运行时内存和刷新策略适合低功耗电子纸设备。

## 1.4 非目标

> [!SCOPE] 第一阶段不做“另一个 KOReader”。只服务微信读书内容和本应用导出的 EPUB，不追求 PDF、MOBI、DjVu、扫描件重排、Calibre、词典、SSH 等通用阅读器能力。

- 不绕过用户没有权限阅读的付费或受限章节。
- 不提供批量分享、公开下载或内容分发平台。
- 不在 MVP 中支持听书、音频专辑和复杂社交互动。
- 不在 MVP 中实现任意 EPUB 的全格式兼容；本应用导出的 EPUB 优先保证。
- 不承诺未实际测试的 Kindle 型号和固件版本。
- 不以闭源商业发布为前提；许可证与微信读书条款未审查完成前仅用于学习和个人使用。

# 2. 用户体验与产品边界

## 2.1 信息架构

应用只保留五个一级入口：

| 一级入口 | 主要内容 | 设计原则 |
|---|---|---|
| 首页 | 继续阅读、最近更新、下载状态 | 打开后一步进入上次阅读 |
| 书架 | 书籍、公众号、筛选和排序 | 不暴露文件目录概念 |
| 搜索 | 搜书、作者、公众号 | 结果直接进入详情或加入缓存 |
| 下载 | 正在下载、离线书、EPUB 导出 | 所有长任务集中管理 |
| 设置 | 账号、排版、同步、缓存、关于 | 高级设置不占用阅读主流程 |

## 2.2 首次登录流程

```text
首次启动
  → 检查网络
  → 获取登录 UID
  → 在 Kindle 显示二维码
  → 手机微信扫码确认
  → 必要时输入四位验证码
  → 获取 Web Cookie、账号信息和官方 API Key
  → 拉取书架
  → 进入首页
```

账号必须先在微信读书 App 中启用“微信读书 Skill”。如果服务端没有返回 API Key，应用给出明确操作指引，而不是只显示“登录失败”。

## 2.3 阅读流程

```text
书架 → 书籍详情 → 立即阅读
  → 确认本章缓存
  → crengine 打开规范化 XHTML
  → 后台预取下一章
  → 翻到章末自动切章
  → 关闭阅读器返回书籍详情或首页
```

阅读界面默认只有正文和页脚进度。单击中部才显示顶部返回栏和底部工具栏；左右区域翻页；长按进入划线或想法展示。所有动画关闭，弹层使用局部刷新。

## 2.4 EPUB 导出流程

用户在书籍详情选择“导出 EPUB”：

1. 选择整本、已缓存章节或章节范围。
2. 选择是否包含图片、划线与想法。
3. 应用检查阅读权限、存储空间和缺失章节。
4. 后台下载、规范化和打包，进度可暂停或取消。
5. 先写临时文件，校验通过后原子重命名到导出目录。
6. 导出文件不包含 Cookie、API Key、阅读上报参数或远程受保护资源 URL。

> [!WARNING] 整本导出必须是用户主动操作，不能作为“打开书籍”的默认行为。默认按章缓存既减少账号风控风险，也降低等待时间和存储压力。

# 3. 总体架构

[[ARCH_DIAGRAM]]

## 3.1 分层说明

### 产品界面层

使用 LVGL 构建书架、搜索、列表、弹窗、进度条、设置和阅读工具栏。该层只处理展示和交互，不直接调用微信读书 API，不直接读写数据库。

### 应用用例层

负责编排用户意图，例如：

- `LoginUseCase`
- `RefreshShelfUseCase`
- `OpenBookUseCase`
- `PrefetchChapterUseCase`
- `ExportEpubUseCase`
- `SyncProgressUseCase`

用例层负责取消、进度、错误转换和状态迁移，但协议细节由 `weread-core` 管理。

### weread-core

平台无关的业务核心，首选继续使用 LuaJIT：

- ID 编码、请求签名、参数构造。
- Cookie 合并和账号会话状态机。
- Gateway 与 Web API 的请求/响应模型。
- EPUB/TXT/公众号内容识别和解码。
- 注释 range 处理、HTML 注入和 TextMap 生成。
- 下载、重试、限流、阅读上报和冲突策略。
- EPUB 导出的文档模型与清单生成。

### 端口与适配器

`weread-core` 只依赖接口：

```text
IHttpClient     网络请求、Cookie、重定向、取消
IStorage        元数据、事务、文件和原子写
IScheduler      定时器、后台任务、取消令牌
IReaderEngine   打开、排版、定位、页图与 XPointer
IDevice         屏幕、输入、网络、电源、休眠
ISecretStore    API Key、Cookie 与敏感 Header
```

独立应用提供 Native 适配器；现有 KOReader 插件可以继续提供 KOReader 适配器。这样迁移过程中不会失去当前可用版本。

## 3.2 运行进程

首个版本建议保持**单进程 + 受控后台任务**：

- UI 主线程：LVGL 事件循环与界面状态。
- 网络工作线程：单并发或最多双并发下载，避免旧设备线程和内存压力。
- EPUB/图片工作线程：CPU 与 IO 操作，支持取消。
- crengine 渲染线程：由 ReaderBridge 串行访问，避免引擎并发不确定性；该线程同时负责后台预渲染下一页到 back buffer，这是翻页反馈预算（见 §13）能达标的关键手段。

SQLite 的日志模式不由性能压测决定，而由文件系统语义决定：数据库若位于 `/mnt/us`（vfat），固定使用 `journal_mode=DELETE`，因为 WAL 依赖的 mmap/共享内存语义在 vfat 上不可靠，掉电有真实损坏案例；只有数据库落在 ext 分区时才允许评估 WAL。正文和图片不写入数据库 BLOB，而是以内容文件存储，数据库只保存索引和状态。

## 3.3 为什么不是“重写全部底层”

本设计追求的是**产品独立**，不是为了形式上的“零依赖”而重写字体、Unicode、HTML/CSS、电子纸刷新和 TLS。不可省略的是这些能力，但提供它们的具体项目都可替换：

- KOReader UI 可由 LVGL 替换。
- KOReader ReaderUI 可由自有 ReaderShell 替换。
- KOReader 的文档排版封装可直接换成 crengine。
- KOReader Device/UIManager 可由 FBInk、evdev、LIPC 和自有事件循环替换。
- KOReader LuaSettings 可由 SQLite 和文件缓存替换。

# 4. 技术栈与依赖

## 4.1 推荐技术栈

| 层 | 依赖/技术 | 作用 | 选择理由 |
|---|---|---|---|
| Native Host | C++17 | 启动、线程、资源生命周期、原生库桥接 | 与 crengine 的 C++ 接口天然匹配，旧工具链兼容性优于更新标准 |
| 业务脚本 | LuaJIT 2.1 系列 | `weread-core`、状态机、协议快速迭代 | 现有项目是 Lua，迁移风险最低 |
| UI | LVGL（固定版本） | 书架、列表、弹层、设置、Reader Chrome | 轻量、可移植、支持电子纸、Flex/Grid 和 CJK [R7] |
| 阅读引擎 | CoolReader `crengine` | XHTML/EPUB DOM、CSS、字体、分页、定位 | 上游明确将其定位为 DOM/XML/CSS 电子书渲染库 [R6] |
| 屏幕输出 | FBInk | framebuffer、电子纸刷新、图片/区域输出 | 已支持 Kindle 与多种电子纸设备，提供 C API/FFI [R5] |
| 输入 | evdev / libevdev | 触摸、按键、旋转后的坐标变换 | 直接适配 Linux 输入设备，不引入桌面窗口系统 |
| 网络 | libcurl + TLS 后端 | HTTPS、重定向、超时、流式下载 | 成熟、可取消，便于实现安全的跨域 Header 策略 |
| 数据库 | SQLite | 书架索引、章节状态、位置、任务、迁移 | 事务可靠、部署简单、可离线查询 |
| 文件/归档 | libarchive + minizip-ng 或 libzip | tar 资源包、EPUB ZIP | 避免手写不安全的归档解析；EPUB 可控制 mimetype 存储方式 |
| QR | libqrencode | 生成登录二维码 | 不依赖 WebView 或浏览器 |
| 图片 | libpng、libjpeg-turbo、libwebp | 封面、正文图片、缩略图 | 与 crengine/FBInk 配合，覆盖微信读书常见资源 |
| 加密摘要 | OpenSSL libcrypto 或 mbedTLS | MD5、SHA-256、TLS | 替换纯 Lua 热路径；保留 Lua 实现作为测试 oracle |
| 构建 | CMake + Ninja + 交叉工具链 | Linux 模拟器和 Kindle 架构产物 | 统一依赖锁定、可复现构建和 CI |
| EPUB 校验 | epubcheck（开发/CI） | EPUB 3 结构与规范校验 | 防止“能打开但不标准”的导出文件进入发布 |

## 4.2 选型比较

| 方案 | 优点 | 主要问题 | 结论 |
|---|---|---|---|
| 完整 KOReader Runtime | 最快获得设备兼容和阅读能力 | 产品外壳、返回栈、菜单和复杂度不符合目标 | 不采用为最终架构 |
| Chromium + epub.js | Web UI 灵活，EPUB 生态成熟 | 体积、内存、启动和电子纸刷新成本过高 | 不适合旧 Kindle |
| Qt/Readium | UI 与排版能力完整 | 运行库重、交叉编译和固件兼容成本高 | 暂不采用 |
| 从零自研通用排版 | 完全控制 | Unicode、字体、CSS、分页和兼容边界巨大 | 不作为 MVP 前提 |
| crengine + LVGL + FBInk | 各层职责清晰，UI 可重做，设备和排版均有成熟基础 | 需要编写桥接和真实设备适配 | **推荐** |

## 4.3 依赖边界

- LVGL 只负责应用 UI，不承担书籍正文排版。
- crengine 只负责书籍文档加载、排版、页面和定位，不负责产品导航。
- FBInk 只负责 framebuffer 与电子纸刷新，不承担 Widget 系统。
- `weread-core` 不直接引用上述库，只通过端口接口调用。
- Linux 模拟器可以用 SDL 或 LVGL 桌面后端，但 SDL 不进入 Kindle 运行包。
- 可以借用 `koxtoolchain` 的交叉编译配方作为**构建工具**，但它不是运行依赖，也不会把 KOReader 带进产品。

# 5. 现有项目复用与重构

## 5.1 复用矩阵

| 现有文件/能力 | 复用级别 | 独立版处理 |
|---|---|---|
| `lib/weread.lua` | 高 | 保留编码、签名、URL 和 payload 构造，补齐固定向量测试 |
| `lib/cookie.lua` | 高 | 保留 Cookie 解析/合并；存储切换到 SecretStore |
| `lib/crypto.lua` | 中 | 作为纯 Lua 参考实现；生产可走 Native Crypto |
| `lib/client.lua` | 中 | 保留 API 语义；HTTP 传输替换为 `IHttpClient` |
| `lib/reader_state.lua` | 高 | 保留 INITIAL_STATE 提取与上下文模型，增强 schema 断言 |
| `lib/content.lua` | 高 | 拆成 Decode、Normalize、Asset、Export 四个模块；移除 KOReader Archiver |
| `lib/annotations.lua` / `thoughts.lua` | 高 | 保留 range 和 EPUB 注释模型，增加 TextMap 与导出开关 |
| `lib/downloader.lua` | 中 | 保留下载状态机思想；调度、进度 UI、休眠守卫由端口注入 |
| `lib/read_report.lua` | 中高 | 保留阅读上报状态机；文档位置和计时由独立 ReaderSession 提供 |
| `lib/book_store.lua` | 中 | 数据模型复用；持久化重写为 SQLite + 文件 |
| `lib/settings.lua` | 低 | KOReader LuaSettings 替换为 SettingsRepository |
| `main.lua` / `ui/*` | 低 | 独立应用全部重写；现有插件继续保留自己的适配器 |
| `docs/*` / `scripts/*` | 高 | 作为协议规范、golden fixture 生成器和人工验证工具继续维护 |

## 5.2 建议仓库结构

```text
wereader/
├── apps/
│   ├── standalone/              # C++ Host + LVGL 产品应用
│   └── koreader-plugin/         # 现有插件适配器，可独立发布
├── core/
│   ├── lua/weread/              # 协议、API、内容、同步、导出编排
│   ├── native/                  # LuaJIT bridge、crypto、archive helper
│   └── contracts/               # 端口接口与数据模型
├── platform/
│   ├── kindle/                  # FBInk、evdev、LIPC、电源、打包
│   ├── linux/                   # 桌面模拟器
│   └── mock/                    # 测试适配器
├── reader/
│   ├── crengine_bridge/
│   └── position_map/
├── tools/
│   ├── api-probes/              # 现有 Python 验证脚本
│   ├── epub-export/
│   └── fixtures/
├── packaging/
│   ├── kual/
│   └── update/
├── tests/
└── docs/
```

## 5.3 迁移原则

1. 先把 KOReader 依赖从业务模块边缘化，现有插件行为保持不变。
2. 任何协议重构都必须用现有 Python 脚本和固定样本做差分验证。
3. 独立版与插件版共享 `weread-core`，禁止复制出两套签名、解码和 Cookie 逻辑。
4. 新 UI 不直接读取当前插件的 `weread.lua` 配置，而是提供一次性迁移工具。
5. 先在 Linux 模拟器跑通，再进入 Kindle 真机调试，减少每次部署成本。

# 6. 微信读书 API 与认证设计

## 6.1 双 API 模型

微信读书能力被明确分成两组：

- **Official Agent Gateway**：Bearer API Key，适合书架、搜索、元数据、目录、进度查询、划线、评论和统计；不提供完整章节正文。[R2]
- **Web Reader Session**：Cookie、浏览器式 Header 和动态 Reader Context，负责完整 XHTML/TXT、CSS、图片资源、公众号文章和阅读上报。[R2]

这两组 API 必须是两个独立 Client，不能在一个通用 `request()` 中混用认证信息。

## 6.2 QR 登录协议

独立版复用现有登录链路，但移除 KOReader 的 `QRMessage`、`UIManager` 和 `Device` 依赖：

| 阶段 | 请求 | 结果 |
|---|---|---|
| 初始化 | `GET /r/weread-skills` | 建立登录 Cookie 上下文 |
| 获取 UID | `GET /api/auth/getLoginUid` | 返回二维码会话 UID |
| 展示二维码 | `https://weread.qq.com/web/confirm?uid=...` | 手机微信扫描并确认 |
| 轮询 | `GET /api/auth/getLoginInfo?uid=...&otp` | pending、验证码或成功凭据 |
| 用户信息 | `GET /api/userInfo?userVid=...` | 账号名称和 VID |
| API Key | `GET /api/skills/apikeyGet?only_show=1` | 官方 Skill API Key |
| 会话落盘 | 本地事务 | Cookie、API Key、账号和版本一起提交 |

登录成功后至少保存：`wr_vid`、`wr_skey`、`wr_rt`、API Key、账号名、登录时间；`wr_ticket` 与 `x-wrpa-*` 类状态按响应更新。所有敏感字段只允许进入 SecretStore，日志只记录长度、状态和错误码。

## 6.3 官方 Gateway 端点

统一入口：

```text
POST https://i.weread.qq.com/api/agent/gateway
Authorization: Bearer <api_key>
Content-Type: application/json
```

请求参数在 JSON 顶层，并携带 `api_name` 与 `skill_version`。

| API | 用途 | MVP |
|---|---|---|
| `/shelf/sync` | 书架、公众号入口和归档 | 必须 |
| `/store/search` | 搜索书籍、作者、公众号等 | 必须 |
| `/book/info` | 书籍元数据 | 必须 |
| `/book/chapterinfo` | 官方目录与章节元数据 | 必须 |
| `/book/getprogress` | 拉取远端阅读位置和时长 | 必须 |
| `/readdata/detail` | 周/月/年/总阅读统计 | 次要 |
| `/user/notebooks` | 笔记本概览 | 后续 |
| `/book/bookmarklist` | 用户划线文本 | 后续/导出可选 |
| `/review/list/mine` | 用户想法 | 后续/导出可选 |
| `/book/underlines` | 章节热门划线 range | 注释功能 |
| `/book/readreviews` | range 对应想法 | 注释功能 |
| `/book/bestbookmarks` | 热门划线 | 后续 |
| `/book/recommend` | 个性化推荐 | 后续 |
| `/book/similar` | 相似书 | 后续 |

## 6.4 Web Reader 端点

| API | 认证 | 用途 | 稳定性 |
|---|---|---|---|
| `POST /web/login/renewal` | Cookie | 续期 Web 会话并更新 Header/Cookie | 非公开，已验证 |
| `GET /web/reader/{bookHash}` | Cookie | 获取 `INITIAL_STATE`、`psvts`、token | 非公开，关键 |
| `POST /web/book/chapterInfos` | Cookie | Web 目录、格式、tar 资源 URL | 非公开，关键 |
| `POST /web/book/chapter/e_0` | Cookie + 签名 | EPUB 正文分片 | 非公开，关键 |
| `POST /web/book/chapter/e_1` | Cookie + 签名 | EPUB 正文分片 | 非公开，关键 |
| `POST /web/book/chapter/e_2` | Cookie + 签名 | EPUB CSS，`st=1` | 非公开，关键 |
| `POST /web/book/chapter/e_3` | Cookie + 签名 | EPUB 正文分片 | 非公开，关键 |
| `POST /web/book/chapter/t_0` | Cookie + 签名 | TXT 正文分片 | 非公开，关键 |
| `POST /web/book/chapter/t_1` | Cookie + 签名 | TXT 正文分片 | 非公开，关键 |
| `POST /web/book/read` | Cookie + 签名 | 阅读时长与位置上报 | 非公开，高风险 |
| `GET /web/mp/articles` | Cookie/Header | 公众号文章列表 | 非公开 |
| `GET /web/mp/content` | Cookie/Header | 公众号完整 HTML | 非公开 |

## 6.5 API Client 接口

```text
GatewayClient
  shelf_sync()
  search(query, scope, cursor)
  book_info(book_id)
  chapter_info(book_id)
  get_progress(book_id)
  get_underlines(book_id, chapter_uid)
  get_reviews(book_id, chapter_uid, ranges)

WebClient
  renew_session()
  get_reader_state(book_id, chapter_uid?)
  get_web_catalog(book_id)
  fetch_epub_shards(context)
  fetch_txt_shards(context)
  fetch_asset_tar(url)
  list_mp_articles(book_id, cursor)
  get_mp_content(review_id)
  report_read(payload)
```

## 6.6 错误分类与重试

| 错误类 | 示例 | 默认策略 |
|---|---|---|
| `NetworkUnavailable` | 无网络、DNS、TLS 超时 | 转离线，任务保留，可手动重试 |
| `AuthExpired` | `-2012 登录超时` | 先续期一次；失败后要求重新扫码 |
| `Unauthenticated` | `-2010 用户不存在` | 清理冲突 Cookie，重新登录 |
| `EntitlementDenied` | 未购买/无会员权限 | 不重试，章节标记为不可读 |
| `RateLimited` | HTTP 429 或业务限流 | 指数退避 + 抖动，降低并发 |
| `ProtocolChanged` | schema 缺字段、分片格式异常 | 停止批量任务，保留样本和诊断信息 |
| `ContentCorrupt` | MD5 不匹配、tar 损坏 | 重新拉取一次，仍失败则不提交缓存 |
| `StorageFull` | 临时文件或数据库写失败 | 立即停止预取，提示清理空间 |
| `AccountRiskControl` | 频繁验证码、强制改密、异常登录拦截 | 降低请求频率、暂停自动任务，明确提示用户；不做自动重试对抗 |

安全要求：重定向跨域时必须移除 `Authorization`、`Cookie`、`Origin` 和私有 Header；下载资源只允许 HTTPS，且响应大小设置合理上限。


# 7. 内容获取、解码与规范化

[[PIPELINE_DIAGRAM]]

## 7.1 Canonical Cache 是核心边界

独立应用不把“EPUB 文件”当作唯一内部数据结构。所有来源先进入统一的 Canonical Cache：

```text
CanonicalBook
├── metadata.json
├── catalog.json
├── styles/
│   └── normalized.css
├── chapters/
│   ├── <chapterUid>.xhtml
│   └── <chapterUid>.textmap
├── assets/
│   └── <sha256>.<ext>
└── annotations/
    └── <chapterUid>.json
```

阅读器直接使用规范化章节；EPUB Exporter 也从同一缓存打包。这样可以避免“阅读版内容”和“导出版内容”各自实现一次解码、图片改写和注释注入。

## 7.2 普通书：EPUB 内部格式

处理顺序必须固定：

1. 调用 `/web/login/renewal`，持久化成功响应的 Cookie 与 Header。
2. 请求书籍或章节 Reader HTML，解析 `window.__INITIAL_STATE__`。
3. 读取正式 `bookId`、`psvts`、`pclts`、token 和当前章节上下文。
4. 请求 `/web/book/chapterInfos`，获得目录、格式、章节层级和 `tar` 资源地址。
5. 先请求 `e_0` 探测格式；如果是编码分片，则进入 EPUB 流程。
6. 对正文请求 `e_0 + e_1 + e_3`，对 CSS 请求 `e_2` 且 `st=1`。
7. 对每个分片验证前 32 字符 MD5，失败时禁止提交缓存。
8. 合并正文分片、去首字符、逆转字符交换、Base64 URL 解码并修复 UTF-8。
9. 解析 XHTML，保留语义标签，移除脚本、事件属性、远程字体和危险 URL。
10. 进行图片 URL 改写与结构清洗，清洗过程同步产出「原始 HTML rune offset → 规范化文本 offset」映射表（TextMap 的数据来源）。
11. 下载章节 `tar`，安全解包图片，按 magic bytes 判断 MIME，使用内容哈希去重。
12. 写入临时目录，完成后以原子方式替换本章缓存。

> [!DECISION] 注释注入**不是** Canonical Cache 的构建步骤，而是 Reader 渲染与 Exporter 打包时的独立后处理层。Canonical XHTML 永远是不含注释的干净正文；注入时先把原始 range（原始 HTML 的 UTF-8 rune 索引）经清洗阶段产出的 offset 映射表换算，再在 DOM 上完成。这样导出的 NONE/FOOTNOTE/APPENDIX 三种模式和用户后续新增划线都不会使缓存章节失效。原有的顺序不变量仍然成立：任何直接消费原始 range 的换算必须基于改写/清洗之前建立的映射关系，否则划线会错位或破坏标签。[R4]

## 7.3 普通书：TXT 内部格式

当 `e_0` 返回包含 `bookId` 的 JSON 元数据而不是编码正文时，将书标记为 TXT：

- 正文来自 `t_0 + t_1`。
- 使用相同的 MD5、字符交换与 Base64 解码过程。
- 输入是纯文本和全角空格缩进，没有独立 CSS 分片。
- 按空行、段首缩进和章节标题生成安全 XHTML。
- 使用应用默认排版样式，不模拟不可知的网页 CSS。
- 保留原文 rune offset 到规范化文本 offset 的映射。

格式探测结果存入书籍元数据，除非目录版本或协议特征变化，否则不重复探测每一章。

## 7.4 公众号文章

公众号书籍以 `MP_WXS_` 开头，流程完全不同：

1. 从 `/shelf/sync` 识别公众号入口。
2. 调用 `/web/mp/articles` 分页获取 `reviewId`、标题、封面和发布时间。
3. 调用 `/web/mp/content?reviewId=...` 获取完整 HTML 页面。
4. 使用真实 HTML Parser 定位 `#js_content` 或 `rich_media_content`。
5. 移除脚本、广告、交互控件和页面级样式，仅保留正文语义结构。
6. 下载 `mmbiz.qpic.cn` 图片，本地化 URL，限制单图和总资源大小。
7. 每篇文章作为一个独立章节进入 Canonical Cache，也可以单篇导出 HTML 或合并为 EPUB。

## 7.5 HTML/CSS 白名单

建议允许：

- 块级：`p`、`h1-h6`、`blockquote`、`ul`、`ol`、`li`、`pre`、`hr`、`figure`、`figcaption`、`table` 基本结构。
- 行内：`span`、`strong`、`em`、`code`、`a`、`sup`、`sub`、`br`、`img`。
- EPUB 语义：`aside`、`epub:type`、`noteref`、`footnote`。
- 属性：`id`、`class`、安全的 `href/src`、`alt`、尺寸和必要的表格属性。

必须移除：

- `script`、`iframe`、`object`、`embed`、`form`、`video/audio` 自动播放。
- 所有 `on*` 事件属性。
- `javascript:`、`data:text/html` 和未知 scheme。
- 外部 CSS、远程字体和跟踪像素。
- 超大内联 base64，除非经过大小和 MIME 校验。

CSS 只保留排版相关属性，例如字体、字号、粗细、行高、边距、缩进、对齐、边框、分页、图片最大宽度。动画、fixed positioning、滤镜、远程 URL 和复杂交互属性全部丢弃。

## 7.6 任务状态机

```text
QUEUED
  → SESSION_RENEW
  → READER_CONTEXT
  → CATALOG
  → FORMAT_PROBE
  → CONTENT_FETCH
  → DECODE
  → ASSET_FETCH
  → NORMALIZE
  → COMMIT
  → DONE
```

`NORMALIZE` 阶段同时产出 offset 映射/TextMap；注释注入不属于缓存构建（见 §7.2 的 DECISION）。

任一步失败都保留已完成章节，但当前章节只在 `COMMIT` 后可见。取消任务时清除临时文件并释放“阻止休眠”引用计数。

# 8. EPUB 3 导出设计

## 8.1 功能范围

支持：

- 整本书导出。
- 已缓存章节导出。
- 章节范围导出。
- 公众号单篇或合集导出。
- 可选封面、图片、用户划线和想法。
- EPUB 3 `nav.xhtml`，同时生成 `toc.ncx` 兼容旧阅读器。
- 保留多级目录、作者、出版社、ISBN、语言、来源与导出时间。

不支持：

- 导出用户无权读取的章节。
- 导出未完成下载且校验失败的内容。
- 在 EPUB 内嵌登录状态、Cookie、远程受保护图片或可执行脚本。

## 8.2 EPUB 目录结构

```text
book.epub
├── mimetype                         # 第一个条目，store，不压缩
├── META-INF/
│   └── container.xml
└── OEBPS/
    ├── package.opf
    ├── nav.xhtml
    ├── toc.ncx
    ├── cover.xhtml
    ├── styles/
    │   └── weread.css
    ├── text/
    │   └── chapter_0001.xhtml ...
    └── images/
        └── <sha256>.<ext>
```

## 8.3 元数据映射

| EPUB 字段 | 微信读书来源 | 规则 |
|---|---|---|
| `dc:identifier` | `bookId` | 使用 `urn:weread:<bookId>`；另生成 UUID 作为导出实例 ID |
| `dc:title` | `title` | 必填，HTML 实体解码后转义 |
| `dc:creator` | `author` / `translator` | 作者主字段，译者作为 contributor |
| `dc:publisher` | `publisher` | 缺失则省略 |
| `dc:language` | 内容检测/默认 | 默认 `zh-CN`，不要按 UI 语言猜测其他语种 |
| `dc:source` | reader URL 或 bookId | 不包含认证参数 |
| `dcterms:modified` | 导出时间 | UTC ISO-8601 |
| cover | 书籍封面 | 下载后本地化，设置 `cover-image` property |
| 自定义 meta | `bookId`、catalog synckey | 仅保存非敏感追踪信息 |

## 8.4 目录与 Spine

- `chapterIdx` 决定线性阅读顺序。
- `level` 构建嵌套目录；非法跳级自动收敛到当前父级的下一层。
- 封面、版权页等 `wordCount=0` 项默认不进入正文 Spine，除非有有效 XHTML。
- 公众号合集按发布时间或用户选择排序，不伪造章节层级。
- 所有 manifest href 统一使用 POSIX 相对路径并进行 XML 转义。

## 8.5 图片与资源

- 使用 magic bytes 判断 PNG、JPEG、GIF、WebP，不信任 URL 后缀。
- 以 SHA-256 命名和去重，维护原 URL → 本地 href 映射。
- 按设置决定是否压缩或缩放超大图片；原图不覆盖，导出阶段生成派生资源。
- 图像最大宽度通过 CSS 限制为 `100%`，避免横向溢出。
- 不允许 ZIP/TAR 路径穿越，例如 `../`、绝对路径或符号链接。
- 任何无法本地化的远程受保护资源都应删除占位或显示替代文本，而不是把认证 URL 留在 EPUB。

## 8.6 划线与想法

现有项目已经验证一种兼容方案：把划线包装为 `epub:type="noteref"`，把想法写入隐藏的 `epub:type="footnote"`。[R4]

独立版提供三种导出模式：

| 模式 | 说明 |
|---|---|
| 不导出 | 默认，正文保持干净 |
| 标准脚注 | 划线可见，想法作为标准 footnote，兼容其他 EPUB 阅读器 |
| 附录 | 正文仅保留轻量标记，所有想法按章节汇总到书末附录 |

KOReader 专用的点击拦截不应写入通用 EPUB；导出文件必须在普通 EPUB 阅读器中仍然有合理行为。

## 8.7 构建、校验与原子提交

```text
准备临时目录
  → 写入 XHTML/CSS/图片
  → 生成 OPF/Nav/NCX
  → ZIP 打包（mimetype 首项且不压缩）
  → 基础自检
  → 开发/CI 运行 epubcheck
  → fsync 临时文件
  → 原子 rename 到目标路径
```

基础自检至少包括：

- 所有 Spine item 都在 manifest 中。
- 所有目录链接目标存在。
- XHTML 能被 XML Parser 读取。
- manifest MIME 与实际文件类型一致。
- EPUB 内没有 `weread.qq.com` 受保护资源 URL、Cookie 或 API Key。
- 章节数量、图片数量、输出大小和失败项被记录到导出报告。

## 8.8 Exporter 接口

```text
EpubExportOptions
  scope: FULL_BOOK | CACHED | RANGE | MP_COLLECTION
  chapter_ids: [...]
  include_cover: bool
  include_images: bool
  annotations: NONE | FOOTNOTE | APPENDIX
  output_path: path
  overwrite: bool

EpubExportResult
  status
  chapter_count
  asset_count
  skipped_chapters
  output_bytes
  validation_errors
```

# 9. 阅读器设计

## 9.1 ReaderShell 与 crengine

`ReaderShell` 是本产品自己的阅读体验；crengine 只是其内部排版器：

```text
ReaderShell
├── ReaderSession
├── ChapterNavigator
├── TypographySettings
├── PositionMapper
├── AnnotationController
├── PageCache
└── ReaderBridge(crengine)
```

ReaderShell 决定顶部栏、底部栏、手势、返回路径、预取和同步；crengine 负责加载 XHTML/EPUB、字体排版、分页、链接和 XPointer。

## 9.2 MVP 的文档打开方式

推荐 MVP 使用**按章文档模式**，而不是每次阅读前构造整本 EPUB：

- 每章保存为完整、可独立解析的 XHTML。
- ReaderBridge 打开当前章并生成页数。
- 到章末时应用切换到下一章文件。
- 当前章阅读时后台预取下一章和必要图片。
- 目录跳转由应用选择章节并打开对应 XHTML。
- 整本 EPUB 仅在用户明确导出时生成。

这一方案避免“部分 EPUB 被更新后正在打开的 ZIP 失效”，也允许只缓存少量章节。后续如 crengine 对目录级文档支持稳定，可引入内部 Book Bundle，但不改变 Canonical Cache。

按章模式有两个必须正面处理的后果：

- **全书进度是估算值**：全书页数只有在所有章节排版完成后才精确，未缓存章节只能按章节数或字数加权估算。UI 必须明确表达「约 x%」，避免用户把估算误差当成 bug。
- **跨章内部链接会断**：正文内 TOC、指向其他章节的 footnote/引用链接由 ReaderBridge 拦截并路由为「切换章节 + 定位」，而不是交给 crengine 按文件路径解析。

## 9.3 阅读位置模型

页码不能作为同步真相，因为字号、边距和屏幕变化会重新分页。位置必须包含三层：

```text
CanonicalPosition
  book_id
  chapter_uid
  source_rune_offset      # 微信读书语义位置
  normalized_text_offset # 清洗后纯文本位置
  quote_before/quote_after

RendererPosition
  xpointer                # crengine 内部定位
  page_index              # 仅用于当前排版缓存
  layout_fingerprint      # 字体、字号、边距、屏幕参数
```

每章生成 `TextMap`：

```text
source rune offset  ↔  normalized text offset  ↔  DOM text node  ↔  xpointer
```

当排版设置变化时，`page_index` 失效，但 CanonicalPosition 不变；应用重新用 TextMap 和上下文片段定位。只有在映射通过真实样本验证后，才把 `chapterOffset` 上报给微信读书。

`xpointer` 持久化时同时记录 crengine 版本号：crengine 升级后 XPointer 可能漂移，检测到版本变化时丢弃 xpointer，用 CanonicalPosition + TextMap 重定位。

## 9.4 阅读功能分级

| 功能 | MVP | 后续 |
|---|---|---|
| 翻页、章节切换 | 是 | — |
| 字号、行距、边距、字体 | 是 | 字体管理与预设同步 |
| 目录、返回、进度条 | 是 | 章节缩略图 |
| 恢复本地阅读位置 | 是 | 多设备冲突历史 |
| 图片查看 | 基础适配 | 缩放、旋转、图注 |
| 微信读书划线显示 | 只读 | 新建/编辑划线 |
| 想法弹层 | 只读 | 评论和互动 |
| 书内搜索 | 可延后 | 全书索引 |
| 导入任意 EPUB | 否 | 视需求评估 |
| PDF/MOBI | 否 | 不在产品主线 |

中文禁则（行首/行尾标点）需用真实书籍验证 crengine 的默认行为，不达标时在 ReaderBridge 的 CSS/文本预处理层修正；竖排不在 MVP 范围内。

## 9.5 电子纸刷新策略

- 列表滚动不做连续动画，按页或按固定步长跳转。
- 页面正文翻页使用局部或适合文本的刷新波形。
- 弹窗、选择状态和进度条只刷新脏矩形。
- 每 N 次翻页或残影阈值触发一次全刷，N 按设备实测配置。
- 关闭弹层时优先重绘其覆盖区域，不全屏闪烁。
- 进入/退出应用时保存和恢复 Kindle 原界面或主动请求系统重绘。
- 所有刷新模式经 `IDisplay` 抽象，未知设备默认使用安全全刷。

# 10. Kindle 设备层

## 10.1 Device HAL 接口

```text
IDisplay
  metrics()
  blit(buffer, region)
  refresh(region, waveform)
  snapshot()/restore()

IInput
  enumerate_devices()
  read_event()
  transform_coordinates(rotation)

IPower
  prevent_suspend(reason)
  allow_suspend(reason)
  on_suspend()/on_resume()

INetwork
  is_online()
  request_connection()
  on_connectivity_changed()

IPlatform
  device_id()
  firmware_info()
  free_space()
  launch_system_ui()
```

## 10.2 Kindle 实现

- **FBInk**：framebuffer 能力探测、图像输出、区域刷新、波形和旋转兼容。FBInk 上游声明支持 Kindle 全系列，但项目仍只承诺实际回归过的型号。[R5]
- **evdev/libevdev**：触摸屏和实体键；启动时扫描能力，避免硬编码 `/dev/input/eventX`。
- **LIPC/系统命令**：Wi-Fi 请求、休眠管理和必要的 Kindle 系统交互；所有调用集中在平台层。
- **原生电源与屏保抑制**：通过 LIPC 抑制原生 `powerd` 与屏保，防止应用在前台时被系统盖屏休眠，退出时恢复原状。路线选择「抑制 framework」而非 `stop framework`，以兑现「退出后无需重启即恢复原生界面」的承诺。
- **信号处理**：`SIGTERM/SIGINT` 触发保存位置、恢复屏幕和释放休眠锁。
- **看门狗**：后台任务异常不能永久阻止设备休眠。

## 10.3 Linux 模拟器

Linux 版本与 Kindle 使用同一 `weread-core`、数据库和 UI 代码，只替换：

- 显示：LVGL 桌面/SDL backend。
- 输入：鼠标和键盘。
- 电源与网络：Mock/desktop implementation。
- 阅读引擎：相同 crengine build。

模拟器用于 UI、API、内容、EPUB 和位置逻辑测试；电子纸波形、休眠、坐标旋转和系统恢复仍必须真机验证。

## 10.4 启动与打包

MVP 先使用 KUAL 或等价 Launcher：

```text
extensions/wereader/
├── menu.json
├── launch.sh
├── bin/wereader
├── lib/
├── share/
│   ├── fonts/
│   ├── hyph/
│   └── themes/
└── version.json
```

用户数据必须位于独立数据目录，不随升级覆盖：

```text
<user-data>/wereader/
├── wereader.db
├── cache/
├── exports/
├── logs/
└── crash/
```

`secrets/` 不在这个目录：`/mnt/us` 是 vfat，没有 POSIX 权限位，且 USB 挂载后明文可读，SecretStore 必须位于 rootfs ext 分区并做静态加密（见 §12.1）。`wereader.db` 在 vfat 上固定使用 `journal_mode=DELETE`（见 §3.2）。

`launch.sh` 只负责环境、库路径、日志重定向和进程启动。业务判断不写在 Shell 中。退出码区分正常退出、需要系统重绘、更新重启和崩溃。

## 10.5 设备支持策略

1. 先固定一台 reference device，记录 CPU 架构、固件、分辨率、framebuffer、触摸和内存。选型硬指标：国内二手存量大、越狱社区教程覆盖度高、市售设备固件停留在可越狱区间（PW3/PW4/PW5 代际优先，而非最新机型）。
2. 形成设备探测报告工具，自动导出不含账号数据的硬件信息。
3. 新设备进入支持列表前，必须通过启动、触摸、翻页、全刷、休眠、Wi-Fi、下载、退出恢复七类测试。
4. 产物按 ABI/架构分包，不能依赖“同为 ARM 就能运行”的假设。
5. 对未知设备显示明确提示，允许安全模式尝试，但不声明兼容。

# 11. 数据、缓存与同步

## 11.1 SQLite 数据模型

| 表 | 关键字段 | 用途 |
|---|---|---|
| `accounts` | account_id、user_vid、name、login_time | 非敏感账号元数据 |
| `secrets_ref` | account_id、secret_version、updated_at | 指向受限权限的 SecretStore，不保存明文 |
| `books` | book_id、title、author、format、cover、metadata_json | 书籍主数据 |
| `shelf_items` | book_id、sort、finish、read_update_time、archived | 书架状态 |
| `chapters` | book_id、chapter_uid、idx、level、word_count、paid、state | 目录与缓存状态 |
| `chapter_content` | chapter_uid、content_hash、path、css_hash、textmap_path | 规范化正文索引 |
| `assets` | asset_hash、mime、path、bytes、ref_count | 图片去重与清理 |
| `chapter_assets` | chapter_uid、asset_hash、role | 章节与资源关系 |
| `reading_positions` | book_id、chapter_uid、offset、xpointer、layout_hash、dirty | 本地位置与同步状态 |
| `download_jobs` | job_id、type、state、progress、error、updated_at | 可恢复长任务 |
| `exports` | export_id、book_id、path、options、state、report | EPUB 导出记录 |
| `settings` | key、value、schema_version | 应用设置 |

数据库迁移使用单调递增 schema version；每个版本有前向迁移和回滚备份策略。数据库与内容文件之间通过“先文件临时写、后数据库事务提交”保持一致。

## 11.2 缓存策略

- 默认缓存当前章、前一章和后两章，可按设备空间调整。
- 用户显式下载的书标记为 pinned，不参与自动 LRU 清理。
- 资源按哈希去重，删除书籍时通过引用计数清理无主资源。
- 下载前检查空间：预计正文、图片、临时文件和导出 ZIP 同时存在的峰值。
- 每章独立完成，整本任务失败不回滚已校验章节。
- 缓存上限、自动清理和“仅 Wi-Fi 预取”由用户设置。
- USB 挂载期间 `/mnt/us` 被系统独占，下载与导出任务自动暂停，卸载后恢复。

## 11.3 阅读时长上报

- 只在阅读界面前台、设备未休眠、用户最近有阅读活动时累计。
- 默认以 30 秒窗口上报，与现有项目行为保持一致。
- 网络断开时只记录真实待上报时长，设置最大积压窗口，避免数小时一次性异常上报。
- 进入后台、休眠、退出和切书时立即关闭当前计时片段。
- 上报失败不阻塞翻页；错误进入同步队列并在账号状态页可见。
- 禁止“启动应用即无限累计”的默认配置，以降低账号和数据准确性风险。

## 11.4 进度同步

### 拉取

通过 `/book/getprogress` 获得远端 `chapterUid`、`chapterOffset`、总进度和更新时间。

### 推送

使用 `/web/book/read`，payload 包含 book/chapter hash、章节索引、offset、摘要、进度、真实阅读秒数、时间戳、token 相关签名和 Reader Context。

### 冲突策略

| 情况 | 策略 |
|---|---|
| 仅远端更新 | 提示跳转或自动采用，取决于用户设置 |
| 仅本地更新 | 关闭书籍后推送 |
| 两端都更新且距离很小 | 采用更新时间较新者，保留另一位置历史 |
| 两端都更新且跨章/差距大 | 必须让用户选择，不静默覆盖 |
| 本地位置无法映射为可靠 offset | 只保存本地，不上传伪造进度 |

> [!DECISION] 双向进度同步不能只用“当前页/总页数”。必须先完成 source rune offset、规范化文本与 crengine XPointer 的映射验证。阅读时长可以先上线，进度上传作为单独验收项。

## 11.5 离线队列

同步队列记录幂等 key：`account + book + session + sequence`。网络恢复时按时间顺序处理，续期失败即暂停，不无限重试。每项保留最后错误、重试次数和下一次允许时间。

# 12. 安全、隐私、合规与许可证

## 12.1 凭据安全

- SecretStore 位于 rootfs ext 分区（而非 `/mnt/us`），文件权限 `0600`、目录 `0700`。vfat 不保证 POSIX 权限位，且 USB 挂载后任何电脑都能直接读取；在此之上再用设备序列号派生密钥对密钥文件做静态加密，作为权限失效时的第二道防线。
- 数据库只保存 secret reference 和状态，不在普通查询中暴露密钥。
- 不在日志、崩溃包、导出 EPUB、截图或诊断页面显示完整 Cookie/API Key。
- 日志脱敏规则覆盖 `wrk-`、`wr_skey`、`wr_rt`、`wr_vid`、`x-wrpa`、`thirdwx` 等模式。
- 使用独立 CA bundle 并验证 TLS 证书；不提供“忽略证书错误”开关。
- 跨域重定向清除认证 Header；只向 `weread.qq.com` 及明确资源域发送 Cookie。

## 12.2 内容安全

- 公众号 HTML 和章节 XHTML 进入严格白名单清洗。
- TAR/ZIP 解包拒绝绝对路径、路径穿越、设备文件、符号链接和超额解压。
- 下载设置单文件、单章节、单任务和全局空间上限，防止压缩炸弹。
- 资源提交前校验 MIME、长度与哈希。
- ReaderBridge 不执行 JavaScript，不加载远程脚本和远程字体。

## 12.3 微信读书条款与权限边界

官方 Skill API 相对稳定；完整正文和上报依赖非公开 Web Reader 接口，存在协议变化、账号限制和服务条款风险。产品必须：

- 只访问当前登录用户依法可读的内容。
- 明确标识“个人学习与技术研究”，不宣传批量内容导出或传播。
- 默认按需缓存，整本导出由用户显式触发。
- 对权限拒绝不尝试绕过，不伪造会员、价格或 paid 状态。
- 在 README、首次使用和导出界面提供风险与责任提示。
- 在公开发布或商业化前进行正式法律与平台条款审查。

## 12.4 开源许可证影响

| 组件 | 上游许可证 | 影响 |
|---|---|---|
| `weread.koplugin` 复用代码 | AGPL-3.0-only | 衍生代码需要遵守 AGPL、保留声明并提供对应源码 |
| FBInk | GPLv3+ | 以库形式集成仍是强 copyleft，必须纳入发布合规 [R5] |
| CoolReader/crengine | GPLv2-or-later | 组合时应选择兼容的 GPLv3 路径并保留上游声明 [R6] |
| LVGL | MIT | 许可宽松，保留版权与许可文本 [R7] |
| LuaJIT、libcurl、SQLite 等 | 各自上游许可 | 生成第三方清单与 NOTICE，逐项核对 |
| 内置中文字体（思源/Noto 等） | OFL-1.1 | 随包附许可文本；子集化属于允许的修改，仍需保留版权声明 |

现有 AGPL 项目、GPLv3+ FBInk 与 GPLv2-or-later crengine原则上都指向开源发布路线，但具体链接、分发、源码提供和许可证文本组合应由熟悉开源许可的人复核。本节不是法律意见。

# 13. 非功能需求与性能预算

下列是首台 reference device 的初始目标，不是未测试设备的承诺：

| 指标 | 初始目标 | 说明 |
|---|---|---|
| 冷启动到首页 | ≤ 4 秒 | 本地书架可先显示，网络刷新异步 |
| 缓存书打开 | ≤ 3 秒 | 不包括首次字体缓存构建 |
| 纯文本翻页反馈 | 中位数 ≤ 300 ms | 页面准备完成且不触发全刷 |
| 页面翻转网络依赖 | 0 | 下一章必须提前缓存或显示明确等待页 |
| 阅读态 RSS | 优先控制在 96 MB 内 | 具体根据参考设备调整 |
| 空闲写放大 | 最小化 | 阅读位置节流写入，重要事件立即提交 |
| 崩溃恢复 | 最近一次已提交位置可恢复 | 当前事务外的少量秒级进度允许丢失 |
| 下载并发 | 默认 1 | 资源小请求可受控提高到 2 |
| 电量策略 | 无动画、无忙轮询 | 定时器合并，后台无任务时阻塞等待 |

## 13.1 内存策略

- 一次只保留当前章排版、前后少量页缓存和必要图片。
- 大图流式解码或按屏幕尺寸生成缩略版本。
- 整本导出逐章处理，不把所有 XHTML 和图片一次性放入内存。
- Lua 与 Native 之间传路径/句柄，避免重复复制大字符串。
- 每个长任务记录内存峰值，超过阈值时降级为串行和小批次。
- 内置中文字体做子集化，默认覆盖常用字集，罕见字回退完整字体，避免一次性加载十几 MB 的 CJK 字库。

# 14. 测试、构建与发布

## 14.1 测试金字塔

| 层 | 内容 | 是否需要真实账号/设备 |
|---|---|---|
| Unit | `_e()`、签名、Cookie、分片解码、TextMap、HTML 清洗、目录树 | 否 |
| Golden | 固定脱敏响应 → 规范化 XHTML/EPUB 结构 | 否 |
| Contract | Gateway/Web schema、错误码、Header 行为 | 脱敏 fixture；更新时人工账号验证 |
| Integration | SQLite、缓存事务、Exporter、crengine 打开 | 否，Linux CI 可跑 |
| UI Snapshot | LVGL 页面与状态切换 | Linux 模拟器 |
| Device | framebuffer、触摸、波形、休眠、Wi-Fi、退出恢复 | 是 |
| Manual Account | QR 登录、正文、阅读上报、权限边界 | 是，凭据不进入 CI |

## 14.2 必须保留的协议向量

- `_e()` 已知输入输出。
- request sign 的布尔值、URL 编码和排序边界。
- EPUB 分片 MD5 校验、交换位置和 Base64 解码样本。
- TXT 内容样本。
- `INITIAL_STATE` 多种页面结构。
- Cookie renewal 后重复 Cookie 合并样本。
- `-2012`、`-2010`、空 `{}` 和 entitlement denied 样本。
- 注释 range 跨标签、HTML entity 和多字节中文样本。

## 14.3 EPUB 测试

- 每次变更运行结构自检和 `epubcheck`。
- 用至少两个独立阅读器打开导出文件，检查目录、图片、中文字体、脚注和章末跳转。
- 对导出 ZIP 做确定性检查：相同输入除时间字段外应得到稳定文件集合和哈希报告。
- 回归样本覆盖：纯文本书、图片丰富书、多级目录、TXT 网文、公众号文章、含划线/想法书籍。

## 14.4 CI/CD

- Linux x86_64 构建：单元、Golden、Exporter、UI 快照。
- Kindle 交叉构建：armv7/aarch64 等目标按实际支持矩阵生成，不在 CI 里宣称可运行。
- 第三方依赖使用固定 commit/tag 和 checksum。
- 生成 SBOM、LICENSES、NOTICE 与源码获取说明。
- 运行 secret scan，阻止真实 Cookie/API Key 和生成的版权内容进入仓库。
- 发布包包含版本、目标 ABI、依赖版本、最小固件和校验哈希。

## 14.5 更新与回滚

- 更新包签名并验证 hash。
- 安装前保留上一个可运行版本。
- 用户数据库和缓存使用独立目录，升级只执行可回滚迁移。
- 新版本首次启动失败时自动回退二进制，不回退已迁移数据库前必须有备份。
- 不在应用内静默更新；用户明确确认。
- 发布渠道考虑国内网络环境：GitHub Release 之外提供国内镜像（网盘/加速链接），安装文档面向 KUAL/MRPI 越狱社区流程，不假设用户能访问 Amazon 或 GitHub 原站。

# 15. 分阶段实施计划

## Phase 0：冻结协议与抽取核心

**交付物**

- 为现有 `_e()`、sign、Cookie、内容解码和 EPUB 构建补齐 Golden 测试。
- 定义 `IHttpClient`、`IStorage`、`IScheduler`、`IDevice`、`IReaderEngine`。
- 把 `lib/weread.lua`、`client` 语义、`content`、`annotations` 和 `read_report` 拆入 `weread-core`。
- 现有 KOReader 插件通过 Adapter 使用新核心，功能不退化。

**退出标准**

- 插件主要功能仍可运行。
- Python 参考脚本与 Lua core 对相同 fixture 产生一致结果。
- core 测试不需要 KOReader 环境。

## Phase 1：Linux 独立原型

**交付物**

- C++ Host、LuaJIT、SQLite、libcurl 和基础 LVGL UI。
- QR 登录、书架、搜索、详情、下载任务页。
- Canonical Cache 与 EPUB Exporter。
- Linux 模拟器中调用 crengine 打开规范化章节。

**退出标准**

- 不启动 KOReader 即可从登录走到阅读。
- 可导出包含图片和目录的有效 EPUB。
- 主要流程可自动测试和录制 UI 快照。

## Phase 2：Kindle 应用外壳

**交付物**

- FBInk 显示、evdev 输入、LIPC 网络/电源和 KUAL 包。
- 启动、退出、屏幕恢复、休眠唤醒。
- 在 reference device 上展示书架并打开本地测试章节。

**退出标准**

- 连续启动/退出不污染 Kindle 原生 UI。
- 触摸坐标、旋转、局部刷新和全刷稳定。
- 崩溃后休眠锁可释放。

## Phase 3：阅读 MVP

**交付物**

- 按章阅读、目录跳转、字体/字号/行距/边距。
- 本地位置、TextMap、章末切换和下一章预取。
- 离线阅读和缓存清理。
- 真实阅读时长上报。

**退出标准**

- 用户可完成“打开书架 → 读多章 → 退出 → 再次恢复”的完整闭环。
- 翻页不依赖网络，章末无死循环或丢位置。
- 休眠后恢复到正确页面。

## Phase 4：同步、注释与公众号

**交付物**

- 远端进度拉取、冲突提示和经过验证的位置上传。
- 微信读书划线/想法只读展示。
- 公众号列表、文章阅读和公众号 EPUB 合集。
- 阅读统计页面。

**退出标准**

- 位置 round-trip 在测试书样本上可接受。
- range 注释在中文、多标签和实体场景不偏移。
- 公众号文章无脚本、无远程依赖即可离线阅读。

## Phase 5：设备矩阵与发布硬化

**交付物**

- 设备探测工具、兼容矩阵、升级/回滚、SBOM、许可证包。
- 多 Kindle ABI 构建和真机回归。
- 诊断包、崩溃报告和协议变更告警。

**退出标准**

- 每个声明支持的设备都有固定测试记录。
- 发布包可复现、可校验、可回滚。
- 协议变化不会触发无限重试或损坏现有缓存。

# 16. MVP 验收清单

| 分类 | 验收项 | 通过条件 |
|---|---|---|
| 独立性 | 无 KOReader 运行依赖 | 删除/未安装 KOReader 时应用仍可启动、登录、阅读和导出 |
| 启动 | 直接入口 | KUAL/Launcher 点击后进入 Wereader 首页 |
| 登录 | QR + OTP | 登录成功、失败、取消、过期和重登路径完整 |
| 书架 | 同步与离线 | 在线刷新后断网仍能查看已缓存书架和详情 |
| 内容 | EPUB/TXT | 至少各一类真实书可连续阅读多章 |
| 公众号 | MP 内容 | 至少一篇文章可离线打开且图片正常 |
| 阅读 | 排版和位置 | 字号变化后仍能回到相近语义位置 |
| 缓存 | 按章与清理 | 预取、取消、失败恢复和空间不足行为明确 |
| EPUB | 标准输出 | 目录、封面、图片正确；epubcheck 无阻断错误 |
| 同步 | 阅读时长 | 仅真实前台阅读时间被上报 |
| 进度 | 安全上传 | 无可靠 offset 时不上传；有可靠映射时 round-trip 正确 |
| 电子纸 | 刷新 | 翻页、弹窗、列表和全刷无明显不可恢复残影 |
| 电源 | 休眠唤醒 | 下载守卫引用计数正确，异常退出不锁死休眠 |
| 安全 | 凭据与内容 | 日志、诊断包和 EPUB 中无密钥/Cookie/受保护远程 URL |
| 退出 | 系统恢复 | 返回 Kindle 原界面，无需重启 |

# 17. 主要风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| Web Reader 非公开接口变化 | 正文、图片或上报失效 | API Adapter 隔离；脚本 canary；schema 断言；feature flag；缓存优先 |
| 账号风控或条款风险 | 登录失效、账号限制 | 按需缓存、限流、真实时长、显式导出、个人使用提示 |
| Kindle 固件碎片化 | 黑屏、触摸错位、无法恢复 | 单参考设备起步；能力探测；安全模式；逐型号真机验收。国内存量设备固件分布相对稳定（官方服务已退出、无强制升级压力），碎片化风险低于全球市场 |
| 新机型无越狱路径 | 新购设备无法安装，用户增长受限 | 产品定位就是国内存量越狱设备；支持列表明确标注型号与固件区间；持续跟踪越狱社区进展 |
| crengine 集成复杂 | 字体、XPointer、分页问题 | 先 Linux PoC；封装 ReaderBridge；保留 Golden 章节和布局样本 |
| 位置映射不准 | 远端进度跳错 | 三层位置模型；上下文校验；不可靠时禁止上传 |
| 大书/大图占内存 | OOM、卡死 | 流式处理、按章提交、图片缩放、单并发、内存预算 |
| 归档与 HTML 输入不可信 | 路径穿越、资源滥用 | libarchive 安全策略、白名单清洗、大小上限、无 JS |
| GPL/AGPL 组合发布错误 | 无法合规分发 | 依赖锁定、LICENSES/SBOM、对应源码、发布前许可证审查 |
| 两套产品逐渐分叉 | 协议 bug 重复修复 | standalone 与 KOReader plugin 强制共享 `weread-core` |

# 18. 待决事项

以下事项不阻塞 Phase 0，但进入相应阶段前必须定案：

1. 首台 reference Kindle 的具体型号、固件和越狱/Launcher 环境。
2. 业务逻辑是否长期保留 LuaJIT，还是稳定后逐步迁移到 C++/Rust。**倾向长期保留 LuaJIT**（KOReader 已验证 ARM 可行性）；真正的成本在 Lua↔C++ FFI 边界——内存所有权、错误传递和大字符串拷贝。附录 A 的接口契约需尽早细化，约定大数据只传路径/句柄。
3. LVGL 与自研极简 Widget 层的首个 PoC 性能对比。
4. crengine 按章 XHTML 的 XPointer 与 source offset 映射精度。
5. EPUB 导出默认是否包含用户划线、想法和来源声明。
6. 公众号图片下载的总量、超时和隐私策略。
7. 缓存默认上限和不同存储容量设备的自动档位。
8. 进度冲突默认是提示、远端优先还是最近更新时间优先。**暂定「提示用户选择」**：多设备轮流阅读场景下「较新者胜」经常跳错，静默策略的事故成本最高。
9. 应用名称和图标是否使用“微信读书”商标，以及公开发布时的品牌边界。**建议 Phase 0 就定案**：名称决定包名、数据目录名和 KUAL 入口，后期改名成本高。
10. 商业化可能性是否存在；如存在，需要重新评估 GPL/AGPL 与平台条款。

# 19. 推荐的第一刀

不要先做漂亮首页，也不要先移植所有 Kindle 型号。第一刀应当是：

```text
现有插件
  → 抽出 weread-core
  → 用 Mock Adapter 在 Linux 单测
  → 用独立 libcurl/SQLite Adapter 跑通同一套 API
  → 从 Canonical Cache 导出 EPUB
  → crengine 打开该缓存章节
```

这一步完成后，项目已经证明“没有 KOReader 也能登录、取书、解码、导出和阅读”。随后 Kindle 层只是在真实 framebuffer、输入、电源和启动环境上替换 Adapter，而不是再重写一遍微信读书能力。

> [!DECISION] 项目的最小技术闭环不是“做出 Kindle 首页”，而是“同一个 weread-core 在 KOReader Adapter 和 Standalone Adapter 下得到一致内容”。这会决定后续是否能长期维护。

[[PAGE_BREAK]]

# 附录 A：关键接口草案

## A.1 内容服务

```text
ContentService.open_book(book_id)
ContentService.refresh_catalog(book_id)
ContentService.ensure_chapter(book_id, chapter_uid, options)
ContentService.prefetch(book_id, from_chapter_uid, count)
ContentService.get_chapter_document(book_id, chapter_uid)
ContentService.get_annotations(book_id, chapter_uid)
```

## A.2 阅读服务

```text
ReaderSession.open(book_id, canonical_position?)
ReaderSession.next_page()
ReaderSession.previous_page()
ReaderSession.open_chapter(chapter_uid, position?)
ReaderSession.current_position()
ReaderSession.apply_typography(settings)
ReaderSession.close()
```

## A.3 导出服务

```text
EpubExporter.plan(book_id, options)
EpubExporter.start(plan, progress_callback, cancel_token)
EpubExporter.validate(path)
EpubExporter.report(export_id)
```

## A.4 平台端口

```text
HttpRequest
  method, url, headers, body_stream
  connect_timeout, total_timeout
  redirect_policy, credential_scope
  cancel_token

StorageTransaction
  put_metadata()
  stage_file()
  commit()
  rollback()
```

# 附录 B：协议不变量

- Gateway 请求必须携带 `skill_version`，业务参数位于顶层。
- 完整章节内容不来自官方 Gateway，而来自 Web Reader 会话。
- `psvts` 来自当前 Reader HTML，不应长期缓存复用。
- `pc` 不能与过期上下文冲突；内容请求签名必须使用 JavaScript 布尔表示。
- EPUB 正文分片为 `e_0 + e_1 + e_3`，CSS 为 `e_2` 且 `st=1`。
- TXT 正文分片为 `t_0 + t_1`。
- 分片前 32 字符是剩余 body 的大写 MD5。
- tar 中的文件名和 URL 后缀不能作为 MIME 真相。
- 注释 range 是原始 HTML rune 索引；清洗/改写阶段必须同步产出 offset 映射，注释注入统一在映射之后的 DOM 层完成。Canonical Cache 中的章节 XHTML 不含用户注释。
- EPUB 的 `mimetype` 必须是 ZIP 第一个条目且不压缩。
- 进度上传不能由动态页码直接换算。

# 附录 C：资料来源

| 编号 | 资料 | 用途 |
|---|---|---|
| R1 | [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin) | 当前插件功能、许可证、菜单与项目范围 |
| R2 | [WeRead API reference](https://github.com/finlater/weread.koplugin/blob/main/docs/weread-api-reference.md) | Gateway/Web 端点、认证、内容与错误行为 |
| R3 | [fetch_weread_epub.py](https://github.com/finlater/weread.koplugin/blob/main/scripts/fetch_weread_epub.py) | 签名、分片解码、图片资源与 EPUB 生成验证 |
| R4 | [weread-annotations-flow.md](https://github.com/finlater/weread.koplugin/blob/main/docs/weread-annotations-flow.md) | 划线 range、noteref/footnote 与注释处理顺序 |
| R5 | [NiLuJe/FBInk](https://github.com/NiLuJe/FBInk) | Kindle framebuffer、电子纸刷新与 GPLv3+ 许可 |
| R6 | [buggins/coolreader](https://github.com/buggins/coolreader) | crengine 电子书排版能力、依赖与 GPLv2+ 许可 |
| R7 | [lvgl/lvgl](https://github.com/lvgl/lvgl) | 嵌入式 UI、电子纸支持、布局能力与 MIT 许可 |

# 附录 D：文档结论

Wereader 的独立化不是“把插件文件从 KOReader 目录搬出去”，而是把现有项目已经验证的微信读书能力抽成稳定核心，再补上三个明确边界：

1. **独立产品层**：新的书架、导航和阅读体验。
2. **独立阅读层**：crengine 提供排版，ReaderShell 提供产品行为。
3. **独立 Kindle 平台层**：FBInk、evdev、LIPC 和可恢复的应用生命周期。

完成后，KOReader 可以继续作为一个可选 Adapter，但不再是用户使用 Wereader 的前置条件，也不是独立应用的运行组成部分。

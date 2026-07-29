# Wereader 独立客户端 Phase 状态与验收台账

更新时间：2026-07-28

本文件以 `docs/Wereader_Standalone_Design_v0.1.md` 第 15、16 节为唯一验收口径。
只有可重复执行的测试、构建产物或真机记录才能标记为完成。

状态含义：

- ✅ 已完成：已有可重复证据，且 review 未发现阻断问题。
- 🟡 部分完成：主体已实现，但仍缺功能、自动化或目标环境证据。
- ⬜ 未完成：尚未实现，或没有足够证据证明已经实现。
- 🔴 阻塞：已尝试推进，但需要当前环境无法提供的外部条件。

## 总览

| 阶段 | 状态 | Review 结论 |
|---|---|---|
| Phase 0：冻结协议与抽取核心 | 🟡 | 核心、端口和 Golden 测试已具备；仍需真实 KOReader 回归记录。 |
| Phase 1：Linux 独立原型 | 🟡 | 登录到跨章阅读的独立链路和自动化已具备；原生 Host、UI 快照、`epubcheck` 仍缺。 |
| Phase 2：Kindle 应用外壳 | ⬜ | 尚无 FBInk、evdev、LIPC、KUAL 实现和真机记录。 |
| Phase 3：阅读 MVP | 🟡 | 跨章、位置恢复和预取已实现；目录跳转、排版设置、缓存清理、真实时长接线和休眠恢复未闭环。 |
| Phase 4：同步、注释与公众号 | 🟡 | 平台无关核心和 KOReader 页面已有较多实现；独立客户端 UI/用例和离线验收未闭环。 |
| Phase 5：设备矩阵与发布硬化 | ⬜ | 尚无设备探针、矩阵、可回滚发布包、SBOM、诊断包和多 ABI 构建。 |

## Phase 0：冻结协议与抽取核心

### 交付物

| 条目 | 状态 | 证据 | Review |
|---|---|---|---|
| `_e()`、sign、Cookie、内容解码、EPUB Golden 测试 | ✅ | `tests/spec/protocol_golden_spec.lua`、`tests/spec/content_epub_spec.lua`、`tests/spec/canonical_spec.lua` | 固定向量不依赖账号或 KOReader；Python 生成器作为参考实现。 |
| 定义五个平台端口 | ✅ | `core/contracts/ports.md` | `IHttpClient`、`IStorage`、`IScheduler`、`IDevice`、`IReaderEngine` 均有契约。 |
| 协议、内容、注释、上报拆入 core | ✅ | `core/lua/weread/lib/` | core 可由独立客户端和 KOReader adapter 共用。 |
| KOReader 插件改用新核心 | 🟡 | `apps/koreader-plugin/weread/adapter/`、`tests/spec/plugin_composition_spec.lua` | 组合测试通过，但还没有真实 KOReader/设备回归记录。 |

### 退出标准

| 条目 | 状态 | 证据或缺口 |
|---|---|---|
| 插件主要功能仍可运行 | 🟡 | 自动化组合测试通过；缺真实 KOReader 登录、书架、阅读回归。 |
| Python oracle 与 Lua core fixture 一致 | ✅ | `tools/fixtures/gen_protocol_vectors.py` 与 `tests/fixtures/protocol_vectors.lua`。 |
| core 测试不需要 KOReader | ✅ | `tests/run_all.sh` 可在普通 LuaJIT 环境运行。 |

## Phase 1：Linux 独立原型

### 交付物

| 条目 | 状态 | 证据 | Review |
|---|---|---|---|
| C++ Host、LuaJIT、SQLite、libcurl、基础 LVGL UI | 🟡 | `apps/standalone/app.lua`、`platform/standalone/`、`platform/linux/` | LuaJIT FFI 原型可运行；设计要求的统一 C++ Host 尚未实现。 |
| QR 登录、书架、搜索、详情、下载任务页 | ✅ | `apps/standalone/app.lua`、`book_service.lua`、`login.lua` | 包含离线回退、失败、取消和重试路径；真实账号仍需人工复核。 |
| Canonical Cache 与 EPUB Exporter | ✅ | `core/lua/weread/lib/canonical.lua`、`book_service.lua`、`platform/standalone/zip_writer.lua` | 单测覆盖目录、章节、资源和导出流程。 |
| Linux 模拟器调用 crengine 打开规范化章节 | ✅ | `platform/linux/reader_bridge.lua`、`tests/spec/standalone_reader_flow_spec.lua` | 自动化使用真实 `libcrbridge` 完成跨章和重启恢复。 |

### 退出标准

| 条目 | 状态 | 证据或缺口 |
|---|---|---|
| 不启动 KOReader，从登录走到阅读 | 🟡 | 独立 UI 和 stub 冒烟通过；仍需真实账号端到端记录。 |
| 导出含图片和目录的有效 EPUB | 🟡 | 内部结构测试通过；缺 `epubcheck` 和第二阅读器打开记录。 |
| 主要流程自动测试和 UI 快照 | 🟡 | 用例、集成、smoke、自检已覆盖；缺可比较的 LVGL UI 快照。 |

## Phase 2：Kindle 应用外壳

### 交付物

| 条目 | 状态 | 证据或缺口 |
|---|---|---|
| FBInk 显示 | ⬜ | 未实现。 |
| evdev 输入 | ⬜ | 未实现。 |
| LIPC 网络/电源 | ⬜ | 未实现。 |
| KUAL 包 | ⬜ | 未实现。 |
| 启动、退出、屏幕恢复、休眠唤醒 | ⬜ | 未实现，需真机。 |
| reference device 展示书架并打开测试章节 | ⬜ | 未实现，需识别并连接真机。 |

### 退出标准

| 条目 | 状态 | 证据或缺口 |
|---|---|---|
| 连续启动/退出不污染原生 UI | ⬜ | 需真机循环记录。 |
| 触摸、旋转、局刷、全刷稳定 | ⬜ | 需真机矩阵记录。 |
| 崩溃后释放休眠锁 | ⬜ | 需故障注入与真机记录。 |

## Phase 3：阅读 MVP

### 交付物

| 条目 | 状态 | 证据或缺口 |
|---|---|---|
| 按章阅读 | ✅ | `reader_session.lua` 与 `standalone_reader_flow_spec.lua` 覆盖真实 crengine 跨章。 |
| 目录跳转 | ⬜ | 尚无独立客户端交互入口。 |
| 字体、字号、行距、边距 | ⬜ | 尚无独立客户端设置和重排接线。 |
| 本地位置、TextMap、章末切换 | 🟡 | 本地页位置和比例恢复已实现；TextMap core 已有，尚未接入独立客户端。 |
| 下一章预取 | ✅ | `reader_session.lua` 产生预取目标，`app.lua` 执行单章预取。 |
| 离线阅读 | ✅ | 书架、详情、目录、章节均有本地回退。 |
| 缓存清理 | ⬜ | 尚无容量视图和清理策略。 |
| 真实阅读时长上报 | 🟡 | `core/lua/weread/lib/read_report.lua` 和测试存在；独立客户端前台生命周期尚未接线。 |

### 退出标准

| 条目 | 状态 | 证据或缺口 |
|---|---|---|
| 打开书架 → 读多章 → 退出 → 再次恢复 | ✅ | `tests/spec/standalone_reader_flow_spec.lua`。 |
| 翻页不依赖网络，章末无循环或丢位置 | ✅ | 阅读会话只访问 canonical 文件；跨章边界有自动化覆盖。 |
| 休眠后恢复正确页面 | ⬜ | 需要 LIPC 生命周期接线和真机验证。 |

## Phase 4：同步、注释与公众号

### 交付物

| 条目 | 状态 | 证据或缺口 |
|---|---|---|
| 远端进度、冲突提示、可靠位置上传 | 🟡 | `progress_sync.lua`、`position_mapper.lua` 与测试存在；独立客户端尚未接线。 |
| 划线/想法只读展示 | 🟡 | core 与 KOReader controller 已有；独立客户端尚未接线。 |
| 公众号列表、文章阅读、EPUB 合集 | 🟡 | core/KOReader 有实现和验证脚本；独立客户端尚未接线，离线包未验收。 |
| 阅读统计页面 | 🟡 | core 与 KOReader 页面已有；独立客户端尚未接线。 |

### 退出标准

| 条目 | 状态 | 证据或缺口 |
|---|---|---|
| 位置 round-trip 可接受 | 🟡 | 固定样本通过；缺真实书和真实账号样本。 |
| 中文、多标签、实体 range 不偏移 | ✅ | `tests/spec/scan_spec.lua`、`annotations` 相关 core 测试覆盖固定样本。 |
| 公众号无脚本、无远程依赖离线阅读 | 🟡 | 清洗/下载代码存在；缺独立客户端离线 E2E 和产物审计。 |

## Phase 5：设备矩阵与发布硬化

### 交付物

| 条目 | 状态 | 证据或缺口 |
|---|---|---|
| 设备探测工具 | ✅ | `tools/device/probe_device.sh`、`run_remote_probe.sh` 与 `device_probe_spec.lua`；输出默认脱敏。 |
| 兼容矩阵 | ⬜ | 待 reference device 探测与验收。 |
| 升级/回滚 | ⬜ | 待实现。 |
| SBOM、许可证包 | ⬜ | 待实现。 |
| 多 Kindle ABI 构建和真机回归 | ⬜ | 待确认 reference device ABI。 |
| 诊断包、崩溃报告、协议变更告警 | ⬜ | 待实现。 |

### 退出标准

| 条目 | 状态 | 证据或缺口 |
|---|---|---|
| 每个支持设备有固定测试记录 | ⬜ | 当前不声明任何支持型号。 |
| 发布包可复现、可校验、可回滚 | ⬜ | 尚无独立应用发布包。 |
| 协议变化不会无限重试或破坏缓存 | 🟡 | 部分错误/缓存测试存在；缺 canary 和故障注入闭环。 |

## MVP 验收摘要

| 分类 | 状态 | Review |
|---|---|---|
| 无 KOReader 运行依赖 | 🟡 | Linux 原型成立；Kindle 产物未成立。 |
| KUAL 直接入口 | ⬜ | 未实现。 |
| QR + OTP | 🟡 | 流程和错误状态存在；缺真实账号复核。 |
| 在线书架与离线回退 | ✅ | 自动化覆盖。 |
| EPUB/TXT 多章阅读 | 🟡 | canonical/crengine 多章覆盖；缺两类真实书人工记录。 |
| 公众号离线内容 | 🟡 | core 存在；独立客户端未闭环。 |
| 排版和语义位置 | 🟡 | 比例恢复已实现；排版设置与 TextMap 未接线。 |
| 缓存预取、取消、恢复、空间处理 | 🟡 | 预取/取消/失败恢复已有；清理和空间不足未实现。 |
| EPUB 标准输出 | 🟡 | 内部测试通过；缺 `epubcheck`。 |
| 真实前台阅读时长 | 🟡 | core 通过；独立客户端未接线。 |
| 安全进度上传 | 🟡 | core 通过；独立客户端和真实样本未验收。 |
| 电子纸刷新 | ⬜ | 未实现。 |
| 休眠锁 | ⬜ | 未实现。 |
| 凭据与内容安全 | 🟡 | 基础边界存在；缺 secret scan、诊断包审计和发布检查。 |
| 退出恢复系统 | ⬜ | 未实现。 |

## 当前可重复验证命令

```sh
tests/run_all.sh
tests/run_smoke.sh
luajit apps/standalone/app.lua --selftest
git diff --check
```

真机测试记录、性能数字、构建哈希和设备探测结果将在后续阶段写入
`docs/device-matrix/`，未记录的设备不进入“支持”列表。

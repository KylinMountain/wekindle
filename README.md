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
platform/
  mock/              测试用端口 Mock 适配器
tests/
  spec/              核心模块单测（无需 KOReader 环境）
  fixtures/          协议固定向量（由 tools/fixtures 生成，勿手改）
tools/
  fixtures/          golden vector 生成器（以 Python 参考脚本为协议 oracle）
docs/                设计文档
```

## 运行测试

```sh
# 核心单测（需要 luajit，不需要 KOReader）
tests/run_all.sh

# 重新生成协议 golden vectors（以 Python 参考实现为 oracle）
python3 tools/fixtures/gen_protocol_vectors.py > tests/fixtures/protocol_vectors.lua
```

## 许可证

本仓库包含的 `apps/koreader-plugin/` 为 AGPL-3.0-only 授权代码（保留原 LICENSE/NOTICE），
整体分发时需遵守相应条款，详见设计文档 §12.4。

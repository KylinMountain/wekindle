# Kindle 设备兼容矩阵

只有完成本目录记录模板中全部阻断项的设备，才会列入“支持”。
仓库当前尚未声明任何 Kindle 型号为正式支持。

## 探测

从开发机经 SSH 采集脱敏能力报告：

```sh
tools/device/run_remote_probe.sh root@KINDLE_IP 22 \
  docs/device-matrix/DEVICE_ID/probe.txt
```

也可把 `tools/device/probe_device.sh` 放到设备上，以 `sh` 直接运行。
探针只读取系统能力，默认不记录序列号、MAC、IP、凭据和用户内容。

## 支持状态

| 设备 | ABI | 固件 | 状态 | 最近验收 | 记录 |
|---|---|---|---|---|---|
| 暂无 | - | - | 未声明支持 | - | - |

## 单设备记录要求

每台 reference device 使用一个不含序列号的目录，例如
`pw5-armv7-firmware-x.y/`，至少包含：

- `probe.txt`：设备探测输出。
- `acceptance.md`：基于 `acceptance-template.md` 的人工/自动验收记录。
- `performance.txt`：冷启动、缓存书打开、翻页延迟、RSS 和空闲 CPU。
- `checksums.txt`：被测安装包与二进制 SHA-256。
- `logs-redacted.txt`：失败时的脱敏日志；成功记录可省略。

不得提交完整序列号、IP/MAC、Cookie、API Key、版权正文或未脱敏截图。

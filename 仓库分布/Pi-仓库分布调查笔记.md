# Pi 仓库分布调查笔记

> 调查对象：`https://github.com/earendil-works/pi`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`e86823096c5bad39e1ca282ec24bc5eb9bec745b`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 npm workspace、包清单、构建与测试入口
>
> 调查范围：模块、语言、文档、测试和平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-08-27）：Git 跟踪文件 1410 个；可识别源码 1220 文件 / 276701 行；文档 97 文件 / 33083 行；测试 531 文件 / 119624 源码行。提交频率：历史跨度 23 天共 430 次，折算 560.87 次/30天，近90天 430 次（浅克隆，历史可能不完整）。

## 结论摘要

Pi 是按可发布能力拆包的 TypeScript monorepo，而不是 GUI 客户端仓库。coding-agent、统一模型 API、TUI 与 agent runtime 四个包构成主体；server/client/protocol/session backend 提供可组合边界。测试文件/源码文件比为 42.5%，主要包都有独立测试区。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 1410 |
| 可识别源码 | 1220 文件 / 276701 行 |
| 文档 | 97 文件 / 33083 行 |
| 测试 | 531 文件 / 119624 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `packages/coding-agent` | 643 / 128,619 |
| `packages/ai` | 326 / 60,607 |
| `packages/tui` | 92 / 33,873 |
| `packages/agent` | 86 / 21,454 |

TypeScript 256,665 行（95.6%）。文档与测试也按同样包边界分布：coding-agent 64 文档/255 测试文件、AI 2/138、TUI 4/39、agent 5/26；`packages/session-backends`（sqlite-node）测试 12 文件/1,807 行、`packages/telemetry` 测试 2 文件/243 行（新增 telemetry conformance 测试与 sqlite 迁移/搜索测试）。

## 跨平台组织与边界

平台形态是 Node/Bun 可运行的 CLI/TUI、库和服务协议，没有本仓原生桌面或移动 GUI。根 workspace 和顺序构建脚本明确依赖层（`package.json:5-18`）；coding-agent 的 sandbox/container 文档包含 Linux 隔离方案，但那是可选执行边界，不表示产品只支持 Linux。

## 关键源码索引

- `package.json:5-34`：workspace、构建与全仓测试
- `README.md:17-42`：包职责
- `packages/coding-agent/`、`packages/ai/`、`packages/agent/`、`packages/tui/`：主体包

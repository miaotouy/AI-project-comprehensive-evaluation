# OpenCode 仓库分布调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`e03db9bc6908f75c9334d8aa997deeaac81c0298`（分支：`dev`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1` 口径），并复核 Bun workspace、应用/包清单、桌面与 CLI 发布说明
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-09-16）：Git 跟踪文件 6626 个；可识别源码 3626 文件 / 729988 行；文档 822 文件 / 225306 行；测试 1036 文件 / 193254 源码行。主线提交节奏：历史跨度 42 天共 385 次，折算 275 次/30天，近90天 385 次（浅克隆，历史可能不完整）。

## 结论摘要

OpenCode 是以 `packages` 为中心的 Bun/TypeScript monorepo，同时交付 CLI/TUI、桌面、Web、server、SDK、plugin、console 和共享 UI。源码规模最大的是核心 `packages/opencode` 与通用 app/core；文档数量大部分来自文档站及其多语言副本。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 6626 |
| 可识别源码 | 3626 文件 / 729988 行 |
| 文档 | 822 文件 / 225306 行 |
| 测试 | 1036 文件 / 193254 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `packages/opencode` | 681 / 180,809 |
| `packages/app` | 609 / 173,176 |
| `packages/core` | 479 / 68,031 |
| `packages/console` | 393 / 56,654 |
| `packages/ui` | 330 / 45,785 |
| `packages/tui` | 204 / 31,895 |
| `packages/sdk` | 44 / 30,332 |
| `packages/session-ui` | 115 / 26,679 |
| `packages/stats` | 94 / 27,241 |
| `packages/llm` | 105 / 20,518 |

TypeScript 682,451 行（93.5%），CSS 43,125 行（5.9%）。

## 文档与测试

文档仍主要集中在 `packages/web` 的多语言站点内容；`specs` 和根 README 另成开发/协议材料。测试文件增至 1036 个，增长主要来自 opencode 的 V2 配置兼容 fixtures、ACP 会话恢复、Provider 适配和 TUI 生命周期覆盖；核心测试分布仍集中在 opencode、core、app、LLM 与 TUI。

## 跨平台组织与边界

CLI/TUI 通过同一核心包支持 Windows、macOS、Linux；桌面应用在 `packages/desktop`，Web UI 在 `packages/app`/`packages/web`，是共享包的独立入口。README 给出三桌面系统发行物（`README.md:54-82`），根脚本分别启动 desktop 与 web（`package.json:10-11`）。

## 关键源码索引

- `package.json:5-28`：Bun workspace 与应用入口
- `packages/opencode/`、`packages/core/`：核心与协议实现
- `packages/desktop/`、`packages/app/`、`packages/tui/`：平台入口

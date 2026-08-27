# OpenCode 仓库分布调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`c2eacd72afc4a4984564c393e15ab30011057269`（分支：`dev`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1` 口径），并复核 Bun workspace、应用/包清单、桌面与 CLI 发布说明
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-08-27）：Git 跟踪文件 6535 个；可识别源码 3602 文件 / 724821 行；文档 820 文件 / 230953 行；测试 965 文件 / 190660 源码行。提交频率：历史跨度 23 天共 281 次，折算 366.52 次/30天，近90天 281 次（浅克隆，历史可能不完整）。

## 结论摘要

OpenCode 是以 `packages` 为中心的 Bun/TypeScript monorepo，同时交付 CLI/TUI、桌面、Web、server、SDK、plugin、console 和共享 UI。源码规模最大的不是 UI 包，而是核心 `packages/opencode` 和通用 app/core；文档数量大部分来自文档站及其多语言副本。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 6535 |
| 可识别源码 | 3602 文件 / 724821 行 |
| 文档 | 820 文件 / 230953 行 |
| 测试 | 965 文件 / 190660 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `packages/opencode` | 762 / 176,788 |
| `packages/app` | 642 / 172,930 |
| `packages/core` | 489 / 67,546 |
| `packages/console` | 557 / 54,093 |
| `packages/ui` | 1,694 / 45,785 |
| `packages/tui` | 241 / 31,850 |
| `packages/sdk` | 48 / 30,329 |
| `packages/session-ui` | 118 / 26,679 |
| `packages/stats` | 108 / 26,260 |
| `packages/llm` | 152 / 20,527 |

TypeScript 674,908 行（93.5%），CSS 42,284 行（5.9%）。

相对快照 b8bd889（6,407 文件）净增 103 个跟踪文件、源码约 +48,946 行，增量几乎全部来自 `packages/app`（+34 文件，i18n 新增约 40 个语言字典）、`packages/ui`（+34）与 `packages/desktop`（+35）的多语言翻译文件与 `desktop-native.ts` 语言探测；文档数（820）不变，行数 +29（zen 定价文档改写与 app/desktop/ui 新增 AGENTS.md 约定）。

## 文档与测试

文档中 `packages/web` 有 616 文件/207,379 行，包含多语言内容，是 820 份文档的主要来源；`specs` 和根 README 另成开发/协议材料。测试集中在 opencode（331 文件）、core（159）、app（233）、LLM（86）和 TUI（52），与核心包分布基本对应。

## 跨平台组织与边界

CLI/TUI 通过同一核心包支持 Windows、macOS、Linux；桌面应用在 `packages/desktop`，Web UI 在 `packages/app`/`packages/web`，是独立入口共享包而非同一外壳。README 给出三桌面系统发行物（`README.md:54-82`），根脚本分别启动 desktop 与 web（`package.json:10-11`）。

## 关键源码索引

- `package.json:5-28`：Bun workspace 与应用入口
- `packages/opencode/`、`packages/core/`：核心与协议实现
- `packages/desktop/`、`packages/app/`、`packages/tui/`：平台入口

# OpenCode 仓库分布调查笔记

> 调查对象：`../../opencode`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`b8bd88901a4870ef3a5752840f4e23e11d54e24e`（分支：`dev`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Bun workspace、应用/包清单、桌面与 CLI 发布说明
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 是以 `packages` 为中心的 Bun/TypeScript monorepo，同时交付 CLI/TUI、桌面、Web、server、SDK、plugin、console 和共享 UI。源码规模最大的不是 UI 包，而是核心 `packages/opencode` 和通用 app/core；文档数量大部分来自文档站及其多语言副本。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 6,407 |
| 可识别源码 | 3,477 文件 / 672,636 行 |
| 文档 | 820 文件 / 230,054 行 |
| 测试 | 955 文件 / 187,893 源码行 |

主要区域为 `packages/opencode`（762 文件/176,345 行）、`packages/app`（608/132,631）、`packages/core`（489/67,546）、`packages/console`（556/53,903）、`packages/ui`（1,660/39,019）、TUI、SDK 与 session UI。TypeScript 625,981 行（93.1%），CSS 42,265 行（6.3%）。

## 文档与测试

文档中 `packages/web` 有 616 文件/207,368 行，包含多语言内容，是 820 份文档的主要来源；`specs` 和根 README 另成开发/协议材料。测试集中在 opencode（331 文件）、core（159）、app（233）、LLM（86）和 TUI（52），与核心包分布基本对应。

## 跨平台组织与边界

CLI/TUI 通过同一核心包支持 Windows、macOS、Linux；桌面应用在 `packages/desktop`，Web UI 在 `packages/app`/`packages/web`，是独立入口共享包而非同一外壳。README 给出三桌面系统发行物（`README.md:54-82`），根脚本分别启动 desktop 与 web（`package.json:10-11`）。

## 关键源码索引

- `package.json:5-28`：Bun workspace 与应用入口
- `packages/opencode/`、`packages/core/`：核心与协议实现
- `packages/desktop/`、`packages/app/`、`packages/tui/`：平台入口

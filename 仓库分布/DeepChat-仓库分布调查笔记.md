# DeepChat 仓库分布调查笔记

> 调查对象：`../../deepchat`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`dc4177c2ac80905ebac985554a9f957aaca31ab8`（分支：`dev`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Electron 构建、插件运行时、测试树与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 是 Electron/Vue 应用、平台插件与完整测试树合仓的多运行时仓库。`src/main` 大于 renderer，而 `test/main` 与 `test/renderer` 合计也超过 31 万行；这使测试树成为与产品源码并列的主要仓库组成，而非少量附属文件。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 4,139 |
| 可识别源码 | 2,847 文件 / 828,949 行 |
| 文档 | 248 文件 / 45,252 行 |
| 测试 | 883 文件 / 327,758 源码行 |

主要区域为 `src/main`（742 文件/253,619 行）、`test/main`（542/229,390）、`src/renderer`（1,348/136,875）、`test/renderer`（249/83,018）和 `plugins/cua`（183/35,446）。主进程和插件承担 Agent、本地运行时及原生能力，renderer 相对更薄。

## 语言、文档与测试

TypeScript 647,627 行（78.1%）、Vue 99,165 行（12.0%）、JavaScript 33,657 行（4.1%）、Swift 25,408 行（3.1%）；Swift 主要来自 macOS 相关插件/辅助程序。文档集中在 `docs/architecture`（104 文件）、`docs/features`（49）和 `resources/skills`（38）。测试分为 main 542、renderer 249、插件 37、E2E 40，另有手工/评估入口。

## 跨平台组织与边界

Electron 构建明确覆盖 Windows、macOS、Linux 及多种架构；插件 bundle、DuckDB VSS 和辅助运行时也按平台分别生成（`package.json:58-73`）。平台差异不只位于打包层，还进入 `plugins` 与 `resources/runtime`；本次未运行原生插件。

## 关键源码索引

- `package.json:43-73`：应用、插件与三平台构建矩阵
- `src/main/`、`src/renderer/`、`src/shared/`：应用运行层
- `plugins/`、`test/`：平台扩展与测试树

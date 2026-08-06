# Cherry Studio 仓库分布调查笔记

> 调查对象：`../../cherry-studio`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`0001d730aeaf26b8d68baeeb54f258851e7a2aec`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 pnpm workspace、Electron 构建、包清单与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Cherry Studio 是 Electron 主应用与内部共享包合仓的 TypeScript monorepo。主进程（403,684 行）和 renderer（479,097 行）共同构成绝大多数业务代码；`packages/ui` 规模也达到 79,937 行。测试与实现大面积共置，按本次规则识别到的测试源码约占总源码 44.6%。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 7,828 |
| 可识别源码 | 6,650 文件 / 1,068,550 行 |
| 文档 | 497 文件 / 70,980 行 |
| 测试 | 1,814 文件 / 476,569 源码行 |

主要区域是 `src/renderer`（2,578 文件/479,097 行）、`src/main`（1,727/403,684）、`packages/ui`（2,166/79,937）、`src/shared`（311/40,631），以及 provider registry 与 AI core 两个约 1.7 万行的包。`v2-refactor-temp` 仍有 171 个跟踪文件，属于需单独识别的阶段性结构。

## 语言、文档与测试

TypeScript 1,051,905 行（98.4%），语言统一度很高。文档主要位于 `docs/references`（98 文件）、`v2-refactor-temp/docs`（154）与 `.agents/skills`（87）；后两类会显著抬高文档数量，但用途分别是重构材料与 Agent 指令，不等同于用户文档。测试集中在 renderer 832 文件、main 731、shared 82，以及内部包 95 余个。

## 跨平台组织与边界

桌面端使用同一 Electron 主应用覆盖 Windows、macOS、Linux，并对 x64/arm64 分别打包（`package.json:26-34`）。平台差异主要由主进程和原生依赖构建处理，没有本仓独立移动端入口。

## 关键源码索引

- `pnpm-workspace.yaml:1-13`：主应用与内部包范围
- `package.json:21-34`：三桌面平台构建矩阵
- `src/main/`、`src/renderer/`、`src/shared/`、`packages/`：主要边界

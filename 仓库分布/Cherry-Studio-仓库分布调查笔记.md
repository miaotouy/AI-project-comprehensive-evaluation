# Cherry Studio 仓库分布调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`6534fc9ecefec9c8f58c133de5539ea66bc7567f`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1` 在 HEAD 重算），并复核 pnpm workspace、Electron 构建、包清单与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-09-16）：Git 跟踪文件 9016 个；可识别源码 7726 文件 / 1343526 行；文档 422 文件 / 53014 行；测试文件 2404 个。行数为 Git 跟踪文本的物理行数，测试行数未在本轮重复拆算。

## 结论摘要

Cherry Studio 是 Electron 主应用与内部共享包合仓的 TypeScript monorepo。主进程（552,819 行）和 renderer（585,174 行）共同构成绝大多数业务代码；`packages/ui` 为 81,498 行。测试与实现仍大面积共置，但本轮没有把测试文件进一步换算为测试源码行占比。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 9016 |
| 可识别源码 | 7726 文件 / 1343526 行 |
| 文档 | 422 文件 / 53014 行 |
| 测试 | 2404 文件；测试源码行未重算 |

主要区域按量级依次为：

| 区域 | 文件 / 源码行 |
| --- | ---: |
| `src/renderer` | 2,933 / 585,174 |
| `src/main` | 2,200 / 552,819 |
| `packages/ui` | 1,738 / 81,498 |
| `src/shared` | 367 / 49,714 |
| provider registry | 193 / 20,702 |
| AI core | 87 / 17,710 |

provider registry 与 AI core 分别约 2.1 万行和 1.8 万行。`v2-refactor-temp` 已退役到只剩 3 份 breaking-change 文档，不再是显著的仓库量级来源。

## 语言、文档与测试

源码仍以 TypeScript/TSX 为绝对主体；本轮重算聚焦总量和模块量级，没有重新生成逐语言百分比。

文档主要位置：

| 位置 | 文件数 | 用途 |
| --- | ---: | --- |
| `docs` 与包内 docs | 主要集中区 | 用户、架构与开发参考 |
| `.agents/skills` | Agent 指令 | 作为文档计入统一口径 |
| `v2-refactor-temp` | 3 | 仅保留 breaking-change 记录 |

测试文件总量增至 2404 个，仍主要与 renderer、main 及内部包实现共置；本轮未按模块拆出测试文件明细。

## 跨平台组织与边界

桌面端使用同一 Electron 主应用覆盖 Windows、macOS、Linux，并对 x64/arm64 分别打包（`package.json:26-34`）。平台差异主要由主进程和原生依赖构建处理，没有本仓独立移动端入口。

## 关键源码索引

- `pnpm-workspace.yaml:1-13`：主应用与内部包范围
- `package.json:21-34`：三桌面平台构建矩阵
- `src/main/`、`src/renderer/`、`src/shared/`、`packages/`：主要边界

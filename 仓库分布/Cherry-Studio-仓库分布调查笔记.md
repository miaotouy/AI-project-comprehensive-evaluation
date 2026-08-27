# Cherry Studio 仓库分布调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`88cfe5dd2b77e63464be22968f66ebcb1d429483`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1` 在 HEAD 重算），并复核 pnpm workspace、Electron 构建、包清单与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-08-27）：Git 跟踪文件 8607 个；可识别源码 7328 文件 / 1247803 行；文档 562 文件 / 72361 行；测试 2141 文件 / 581597 源码行。主线提交节奏：历史跨度 826 天共 5293 次，折算 192.24 次/30天，近90天 1785 次（非浅克隆）。

## 结论摘要

Cherry Studio 是 Electron 主应用与内部共享包合仓的 TypeScript monorepo。主进程（432,627 行）和 renderer（495,622 行）共同构成绝大多数业务代码；`packages/ui` 规模也达到 80,009 行。测试与实现大面积共置，按本次规则识别到的测试源码约占总源码 45.4%。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 8607 |
| 可识别源码 | 7328 文件 / 1247803 行 |
| 文档 | 562 文件 / 72361 行 |
| 测试 | 2141 文件 / 581597 源码行 |

相对 `0001d730ae` 快照：跟踪文件 7,828 → 8,002，源码行 1,068,550 → 1,116,566（净增约 +48k 行，与区间内 1,171 个文件被修改、净 +56k 行的 diff 规模吻合），测试源码行 476,569 → 506,552（测试/源码占比 44.6% → 45.4%）。

主要区域按量级依次为：

| 区域 | 文件 / 源码行 |
| --- | ---: |
| `src/renderer` | 2,631 / 495,622 |
| `src/main` | 1,820 / 432,627 |
| `packages/ui` | 2,168 / 80,009 |
| `src/shared` | 316 / 42,199 |
| provider registry | 181 / 17,802 |
| AI core | 90 / 17,761 |

provider registry 与 AI core 是两个约 1.8 万行的内部包。`v2-refactor-temp` 仍有 181 个跟踪文件，但源码已清空（0 行可识别源码），只剩 `README.md`、`docs/` 与 `tools/data-classify` 等文档/工具；其文档仍计入上表的 166 个 v2-refactor-temp 文档文件。

## 语言、文档与测试

TypeScript 1,099,512 行（98.5%），语言统一度很高。

文档主要位置：

| 位置 | 文件数 | 用途 |
| --- | ---: | --- |
| `v2-refactor-temp` | 166 | 重构材料，不等同于用户文档 |
| `docs`（含 `docs/references`） | 111 | 用户与开发文档 |
| `.agents/skills` | 87 | Agent 指令 |
| `resources` | 33 | 资源 |

测试集中在 renderer 865 文件、main 779、shared 83、`packages/ui` 66，以及 aiCore 30、provider-registry 18 等内部包（合计约 115 个）。

## 跨平台组织与边界

桌面端使用同一 Electron 主应用覆盖 Windows、macOS、Linux，并对 x64/arm64 分别打包（`package.json:26-34`）。平台差异主要由主进程和原生依赖构建处理，没有本仓独立移动端入口。

## 关键源码索引

- `pnpm-workspace.yaml:1-13`：主应用与内部包范围
- `package.json:21-34`：三桌面平台构建矩阵
- `src/main/`、`src/renderer/`、`src/shared/`、`packages/`：主要边界

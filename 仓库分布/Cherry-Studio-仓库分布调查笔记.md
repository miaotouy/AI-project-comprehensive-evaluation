# Cherry Studio 仓库分布调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`e2fd716e569c73c1baa4ac226b6b0607792cdb9d`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1` 在 HEAD 重算），并复核 pnpm workspace、Electron 构建、包清单与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照：Git 跟踪文件 12625 个；可识别源码 9800 文件 / 1745263 行；文档 1005 文件 / 113792 行；测试文件 3443 个，其中可识别源码行 900894 行。

## 结论摘要

Cherry Studio 是 Electron 主应用与内部共享包合仓的 TypeScript monorepo，版本号 2.1.10。主进程（685843 行）与 renderer（684024 行）量级相当，两者合计构成绝大多数业务代码；`packages/ui` 为 89127 行。除 `src` 与 `packages` 外，仓库还分出 `native`（系统原生扩展）、`migrations`（SQLite 迁移产物）和 `resources`（内置 Agent、技能与数据预设）三个独立区域。测试与实现仍大面积共置，测试源码行已超过源码总量的一半。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 12625 |
| 可识别源码 | 9800 文件 / 1745263 行 |
| 文档 | 1005 文件 / 113792 行 |
| 测试 | 3443 文件 / 900894 源码行 |

主要区域按量级依次为：

| 区域 | 文件 / 源码行 |
| --- | ---: |
| `src/main` | 2,946 / 685,843 |
| `src/renderer` | 3,469 / 684,024 |
| `packages/ui` | 2,311 / 89,127 |
| `src/shared` | 451 / 57,504 |
| provider registry | 234 / 36,456 |
| `packages/agent-runtime-pi` | 71 / 22,234 |
| `packages/file-preview` | 137 / 20,228 |
| AI core | 97 / 18,654 |
| `packages/agent-behavior` | 101 / 16,239 |

provider registry 与 AI core 分别约 3.6 万行和 1.9 万行。渲染层原先自带的文件预览渲染与 Agent 运行时已抽出为内部包：`packages/file-preview` 承接 PDF、DOCX、PPTX、XLSX、RTF 与图片预览（HTML、Markdown 与源码预览仍留在桌面应用），`packages/agent-runtime-pi` 与 `packages/agent-behavior` 承接 Pi 运行时及其与具体 harness 无关的行为端口。`v2-refactor-temp` 目录在本次快照中已不存在。

## 语言、文档与测试

源码仍以 TypeScript/TSX 为绝对主体（9586 文件 / 1705009 行），JavaScript、CSS、Python、HTML、SQL 均在万行以下；本轮重算聚焦总量和模块量级，没有重新生成逐语言百分比。

文档主要位置：

| 位置 | 文件数 / 行数 | 用途 |
| --- | ---: | --- |
| `docs/website` | 371 / 30,291 | 官网与用户文档，按 i18n 语言分目录 |
| `docs/dev` | 151 / 32,695 | 架构与开发参考，按主题（ai、data、ipc、knowledge 等）分目录 |
| `.agents/notes` | 189 / 16,560 | Agent 提案与已实现记录，作为文档计入统一口径 |
| `.agents/skills` | 94 / 11,536 | Agent 指令与可复用技能 |
| `resources/skills`、`resources/builtin-agents` | 46 / 5,504 | 随应用分发的能力与角色定义 |

测试文件总量增至 3443 个，主体仍与实现共置：`src` 内 2718 个、`packages` 内 354 个，另有 `tests` 与 `scripts` 下的端到端与治理测试。本轮未按模块拆出测试文件明细。

## 跨平台组织与边界

桌面端使用同一 Electron 主应用覆盖 Windows、macOS、Linux，并对 x64/arm64 分别打包（`package.json:23-43`）。平台差异主要由主进程和原生依赖构建处理：`native/system-speech` 作为 workspace 包提供系统语音能力，`native/external-app` 以 node-gyp 加 Objective-C/C++ 源文件提供系统文件处理程序发现（`pnpm-workspace.yaml:1-3`）。本仓没有独立移动端入口。

## 关键源码索引

- `pnpm-workspace.yaml:1-3`：主应用、内部包与原生语音包范围
- `package.json:23-43`：三桌面平台构建矩阵（含 cn 版）
- `migrations/sqlite-drizzle.config.ts`：SQLite 迁移产物配置
- `src/main/`、`src/renderer/`、`src/shared/`、`packages/`、`native/`：主要边界

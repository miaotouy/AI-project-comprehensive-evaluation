# Pi 仓库分布调查笔记

> 调查对象：`https://github.com/earendil-works/pi`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 npm workspace、包清单、构建与测试入口
>
> 调查范围：模块、语言、文档、测试和平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

当前快照：Git 跟踪文件 3888 个；可识别源码 3164 文件 / 634,089 行；文档 260 文件 / 65,954 行；测试源码 1089 文件 / 272,338 行。统计只使用当前 Git 跟踪文件；行数为物理行，未运行构建与测试。

## 结论摘要

Pi 是按可发布能力拆包的 TypeScript monorepo。产品面仍是 CLI/TUI，另有新增的实验性应用 `apps/p2`（自带 Web host 与 TUI host）；运行时被拆成清晰的层：coding-agent 是产品入口，ai 负责统一模型 API，durable 是新的持久化 agent harness，chord 提供跨进程对象与插件运行时，codemode、mcp、env、schema 是各司其职的能力包。测试文件/源码文件比为 34.4%，测试行数约为源码行数的 43%，主要包都有独立测试区。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 3888 |
| 可识别源码 | 3164 文件 / 634,089 行 |
| 文档 | 260 文件 / 65,954 行 |
| 测试源码 | 1089 文件 / 272,338 行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `packages/coding-agent` | 839 / 155,990 源码行 |
| `packages/chord` | 919 / 130,510 源码行 |
| `apps/p2` | 648 / 98,664 源码行 |
| `packages/durable` | 271 / 86,195 源码行 |
| `packages/ai` | 471 / 73,986 源码行 |
| `packages/tui` | 126 / 36,080 源码行 |
| `packages/env` | 46 / 9,423 源码行 |
| `packages/mcp` | 53 / 7,521 源码行 |
| `packages/schema` | 259 / 7,513 源码行 |
| `packages/agent` | 21 / 6,343 源码行 |

TypeScript/TSX 共 599,852 行（TS 587,532 + TSX 12,320），约占可识别源码的 94.6%，是绝对主语言；另有 17 个 Rust 文件 / 5,389 行，全部在 `packages/env/daemon`（远端执行 daemon）。

包结构上，`durable` 承接会话与 turn 的持久化 harness，`codemode` 提供 QuickJS 中的工具脚本运行时，`env` 提供 SSH 远端执行环境，`mcp` 是独立 MCP 客户端，`schema` 是无 eval 的 JSON Schema 构建与校验。chord 是跨进程对象/插件框架，并作为 p2 的界面底座。

## 跨平台组织与边界

平台形态是 Node/Bun 可运行的 CLI/TUI、库，以及 p2 提供的自托管 Web 界面，没有原生桌面或移动 GUI。`apps/p2` 通过 `node --import ./src/source.ts src/hosts/server.ts` 启动本地 HTTP 服务（默认 8788 端口），代码分 hosts、plugins、voice-server 等目录，数据默认落在 `~/.pi/p2`；其 README 明确标注为实验性原型，数据格式与 API 随时变化。

根 workspace 覆盖 `packages/*` 与 `apps/*`，并显式列出示例依赖目录；构建脚本按 telemetry → schema → chord → tui → codemode → mcp → ai → durable → env → agent → coding-agent 的顺序串联，说明包之间存在单向依赖层。coding-agent 的 sandbox/container 文档包含 Linux 隔离方案，该方案只是可选执行边界中的一种。

## 关键源码索引

- `package.json`：workspace 清单、顺序构建与全仓测试入口
- `README.md`：包职责
- `packages/coding-agent/`、`packages/ai/`、`packages/durable/`、`packages/chord/`、`packages/tui/`：主体包
- `apps/p2/README.md`、`apps/p2/package.json`：自托管 Web 界面的运行方式与依赖

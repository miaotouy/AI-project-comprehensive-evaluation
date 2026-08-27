# LobeHub 仓库分布调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`7c559cbd4d92a54289bce3a8aab96e057d0ce8c5`（分支：`canary`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 pnpm workspace、应用/包清单、部署与桌面构建入口
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-08-27）：Git 跟踪文件 15350 个；可识别源码 12798 文件 / 2109721 行；文档 811 文件 / 164137 行；测试 3253 文件 / 863971 源码行。主线提交节奏：历史跨度 35 天共 766 次，折算 656.57 次/30天，近90天 766 次（浅克隆，历史可能不完整）。

## 结论摘要

LobeHub 是本组跟踪文件最多的 TypeScript monorepo，主 Web 应用、独立 server、Electron desktop、CLI 与大量业务/工具包共仓。代码没有只集中在单一 `src`：`apps/server`、`src/features`、database、store、model-runtime 和 routes 都是十万行级区域，显示其前后端与运行时边界已包化。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 15350 |
| 可识别源码 | 12798 文件 / 2109721 行 |
| 文档 | 811 文件 / 164137 行 |
| 测试 | 3253 文件 / 863971 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `apps/server` | 1,493 / 388,241 |
| `src/features` | 3,012 / 353,088 |
| `packages/database` | 686 / 172,169 |
| `src/store` | 836 / 166,097 |
| `packages/model-runtime` | 442 / 131,267 |
| `apps/desktop` | 415 / 66,685 |
| `src/routes` | 875 / 76,080（从 1,298 / 120,160 显著收缩） |

features 与 routes 此消彼长来自结构迁移：提交 `8de42d5c3` 把六个路由域移入 `src/features`，设置页各分区（provider/memory/hotkey/oauth-apps 等）也整体从 `src/routes/(main)/settings/` 归并到 `src/features/Settings/`。

新增可观察区域：

- `packages/model-bank`（191/49,800）
- `apps/cli`（182/44,988）
- `packages/context-engine`（175/37,772）
- `packages/heterogeneous-agents`（114/31,164）
- `src/services`（173/28,462）

## 语言、文档与测试

TypeScript 1,958,825 行（98.8%）。

文档主要位于 `docs/usage`（221 文件）、`docs/self-hosting`（150）、`.agents/skills`（173）；`changelog` 仍只有 2 个文件却占 47,939 行，是按行数观察文档时的异常集中点；新增 `docs/development`（42 文件，含 agent-goals-design 等设计文档）。

测试分布：server（612 文件）、database（193）、store（240）、features（524）、model-runtime（191）与 desktop（102）；`apps/cli` 测试也增长到 76 文件。

## 跨平台组织与边界

Web/自托管服务是主形态，另有 Docker 部署、独立 server、CLI 和 Electron desktop workspace（`pnpm-workspace.yaml`）。

后端 Hono 路由已从 `apps/server/src/hono/` 更名为 `router-hono/` 并合并（`e32e2efe2`）。

本范围内新增多个独立包，边界进一步包化：

- `packages/openapi`：由 hono-openapi 生成 openapi.yml（`3ea7afd5d`）
- `packages/sdk`：从 OpenAPI spec 生成 `@lobehub/sdk`（`e86908812`）
- `packages/connector-data`：twitter/notion/github 等 connector 数据源
- `packages/device-sandbox`：桌面本地沙箱执行环境（`e9b6d00ab`）
- `packages/builtin-tool-goal`：goal 工具

桌面通过 `apps/desktop` 的独立主进程包与 Web 前端桥接；本次未验证各桌面发行目标的运行结果。

## 关键源码索引

- `pnpm-workspace.yaml`：应用与包的 workspace 边界
- `package.json`：桌面构建入口
- `apps/`、`packages/`、`src/features/`、`src/store/`：主要模块树

# LobeHub 仓库分布调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`52756f6904f8d4a7b5cc46142847ee6d4887c9d5`（分支：`canary`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 pnpm workspace、应用/包清单、部署与桌面构建入口
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

当前快照（2026-09-16）：Git 跟踪文件 16,769 个；可识别源码 14,149 文件 / 2,381,054 行；文档 838 文件 / 166,531 行；测试 3,750 文件 / 985,640 源码行。主线提交节奏：浅克隆可见历史跨度 55 天，共 1,369 次 first-parent 提交，折算 746.73 次/30 天；历史不完整，不能据此推断项目全生命周期节奏。

## 结论摘要

LobeHub 是 TypeScript monorepo，主 Web 应用、独立 server、Electron desktop、CLI 与大量业务/工具包共仓。代码不集中在单一 `src`：`apps/server`、`src/features`、database、store、model-runtime 和 routes 都是十万行级区域，前后端与运行时已分别落在独立包中。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 16,769 |
| 可识别源码 | 14,149 文件 / 2,381,054 行 |
| 文档 | 838 文件 / 166,531 行 |
| 测试 | 3,750 文件 / 985,640 源码行 |
| 测试/源码文件比 | 26.5% |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `apps/server` | 1,811 / 492,624 |
| `src/features` | 3,689 / 436,259 |
| `packages/database` | 852 / 222,982 |
| `src/store` | 877 / 185,149 |
| `packages/model-runtime` | 453 / 134,602 |
| `apps/desktop` | 490 / 84,397 |
| `src/routes` | 881 / 74,466 |

路由与设置页的实现集中在 `src/features`：六个路由域移入其中，设置页各分区（provider/memory/hotkey/oauth-apps 等）也归并到 `src/features/Settings/`。

其他可观察区域：

- `apps/cli`（245/56,826）
- `packages/model-bank`（197/50,205）
- `packages/heterogeneous-agents`（169/50,159）
- `packages/context-engine`（189/40,161）
- `src/services`（206/30,059）
- `packages/mecha`（24/3,733）
- `packages/html-artifact`（16/2,758）

当前快照有三条明确的共享边界：Mecha 把 Agent 配置、上下文事实、工具规则和模型参数决策抽成浏览器/服务端共用内核；HTML Artifact 包承担本地资源收集、打包与发布契约；数据库 FTS repository 与服务端同步 worker 组成 PostgreSQL/Elasticsearch 可切换的全文检索层。后者位于 database 包内部，因此不作为一级 package 单列量级。

## 语言、文档与测试

TypeScript 2,348,142 行（98.6%），其次是 JavaScript 12,425 行和 Shell 8,185 行；其余可识别语言合计不足 0.6%。

文档主要位于 `docs/usage`（225 文件）、`.agents/skills`（183）、`docs/self-hosting`（154）；`changelog` 仍只有 2 个文档文件却占 47,939 行，是按行数观察文档时的异常集中点；`docs/development` 另有 44 文件，含设计文档。

测试分布：server（758 文件）、features（726）、store（263）、database（232）、model-runtime（196）、desktop（137）与 CLI（106）。测试/源码文件比为 26.5%；该值包含按目录和文件名模式识别的夹具与测试资源，不能等同于覆盖率。

## 跨平台组织与边界

Web/自托管服务是主形态，另有 Docker 部署、独立 server、CLI 和 Electron desktop workspace（`pnpm-workspace.yaml`）。

后端 Hono 路由位于 `apps/server/src/router-hono/`。

多个独立包构成主要边界：

- `packages/openapi`：由 hono-openapi 生成 openapi.yml
- `packages/sdk`：从 OpenAPI spec 生成 `@lobehub/sdk`
- `packages/connector-data`：twitter/notion/github 等 connector 数据源
- `packages/device-sandbox`：桌面本地沙箱执行环境
- `packages/builtin-tool-goal`：goal 工具
- `packages/mecha`：跨宿主 Agent 配置、上下文工程、工具规则与模型参数解析
- `packages/html-artifact`：HTML Artifact 资源收集、打包与发布核心
- `packages/database/src/repositories/ftsSearch`：Provider 中立全文搜索与 Elasticsearch 候选后端

桌面通过 `apps/desktop` 的独立主进程包与 Web 前端桥接；本次未验证各桌面发行目标的运行结果。

## 关键源码索引

- `pnpm-workspace.yaml`：应用与包的 workspace 边界
- `package.json`：桌面构建入口
- `apps/`、`packages/`、`src/features/`、`src/store/`：主要模块树

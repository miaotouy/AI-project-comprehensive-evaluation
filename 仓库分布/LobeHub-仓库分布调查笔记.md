# LobeHub 仓库分布调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 pnpm workspace、应用/包清单、部署与桌面构建入口
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

当前快照（2026-11-04）：Git 跟踪文件 23,321 个；可识别源码 20,605 文件 / 3,336,013 行；文档 927 文件 / 178,784 行；测试 6,272 文件 / 1,466,305 源码行。主线提交节奏：浅克隆可见历史跨度 257 天，共 238 次 first-parent 提交，折算 27.78 次/30 天；该节奏的统计窗口为这 257 天。

## 结论摘要

LobeHub 是 TypeScript monorepo，主 Web 应用、独立 server、Electron desktop、CLI、share 页面与大量业务/工具包共仓。代码不集中在单一 `src`：`apps/server`、`src/features`、database、store、model-runtime 和 routes 都是十万行级区域，前后端与运行时已分别落在独立包中。

`packages/` 在快照间继续扩张，新增的多是围绕 agent 运行时的专用包：`agent-runtime`、`agent-manager-runtime`、`agent-tracing`、`agent-signal`、`agent-address-linq`/`agent-address-mail`、`canvas`/`canvas-runtime`、`secret-channel`、`widget-spec`、`tool-view-model`、`i18n-extractor`、`alint`，以及一组新的 `builtin-tool-*`（attachments/channel/dashboard/video-generation）。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 23,321 |
| 可识别源码 | 20,605 文件 / 3,336,013 行 |
| 文档 | 927 文件 / 178,784 行 |
| 测试 | 6,272 文件 / 1,466,305 源码行 |
| 测试/源码文件比 | 30.4% |

顶层三个源码区：`src` 9,391 文件 / 1,149,806 行，`packages` 6,725 / 1,142,955，`apps` 4,519 / 961,823；其后是 `scripts`（267 / 36,214）与 `.agents`（456 / 21,420）。

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `apps/server` | 3,229 / 746,817 |
| `src/features` | 5,685 / 671,104 |
| `packages/database` | 1,317 / 333,729 |
| `src/store` | 1,295 / 268,677 |
| `packages/model-runtime` | 557 / 153,098 |
| `apps/desktop` | 617 / 109,756 |
| `apps/cli` | 457 / 94,976 |
| `src/routes` | 926 / 73,710 |

`src/features` 已扩张到 186 个顶层目录，承担路由页面的业务实现（Agent 构建、技能商店、任务、目标、频道、文档等）；设置页各分区（provider/memory/hotkey/oauth-apps 等）也归并在这里。

其他可观察区域：

- `packages/heterogeneous-agents`（278/67,874）
- `packages/model-bank`（217/53,264）
- `packages/context-engine`（208/42,978）
- `src/services`（262/40,467）
- `packages/types`（253/36,614）
- `packages/openapi`（200/36,395）
- `packages/agent-runtime`（110/32,338）
- `packages/conversation-flow`（102/14,377）
- `packages/mecha`（31/5,561）
- `packages/html-artifact`（16/2,758）

当前快照的共享边界：Mecha 把 Agent 配置、上下文事实、工具规则和模型参数决策抽成浏览器/服务端共用内核；HTML Artifact 包承担本地资源收集、打包与发布契约；数据库 FTS repository 与服务端同步 worker 组成 PostgreSQL/Elasticsearch 可切换的全文检索层，位于 database 包内部，因此不作为一级 package 单列量级。

## 语言、文档与测试

TypeScript 20,127 文件 / 3,283,524 行（98.4%），其次是 JavaScript 173 文件 / 26,294 行、Shell 50 / 9,143、SQL 204 / 8,595；其余可识别语言合计不足 0.5%。

文档主要位于 `docs`（539 文件 / 61,305 行，含 usage、self-hosting、development、wiki 子域）、`changelog`（2 文件 / 47,939 行，按行数观察文档时的异常集中点）和 `.agents`（283 文件 / 44,745 行，含 skills 与验收脚本说明）。

测试分布：`packages` 1,939 文件 / 516,503 行、`apps` 1,802 / 506,181、`src` 2,321 / 415,834、`scripts` 67 / 10,706、`e2e` 62 / 8,534。按区域看 server 与 database 最重（1,376 / 400,635 与 547 / 200,694）；测试/源码文件比为 30.4%，该值包含按目录和文件名模式识别的夹具与测试资源，口径为文件数量比。

## 跨平台组织与边界

Web/自托管服务是主形态，另有 Docker 部署、独立 server、CLI、share 页面和 Electron desktop workspace（`pnpm-workspace.yaml`）。

后端 Hono 路由位于 `apps/server/src/router-hono/`，服务层位于 `apps/server/src/services/`，另有 `modules`、`workflows`、`runtimeConfig` 等并列目录。tools 治理在快照间换成了 `alint`（`packages/alint` 与根 `alint.config.toml`/`alint.audit.toml`），lint 栈从 `eslint.config.mjs` 迁到 `oxlint.config.mts`，并新增 bundle 边界与类型检查配置；`CLAUDE.md` 被移除，agent 协作说明集中在 `.agents/`。

多个独立包构成主要边界：

- `packages/openapi`：由 hono-openapi 生成 openapi.yml
- `packages/sdk`：从 OpenAPI spec 生成 `@lobehub/sdk`
- `packages/agent-runtime`：agent 循环与工具调用运行时
- `packages/conversation-flow`：消息树解析与展示流水线
- `packages/connector-data`：twitter/notion/github 等 connector 数据源
- `packages/device-sandbox`：桌面本地沙箱执行环境
- `packages/builtin-tool-goal` 等 `builtin-tool-*`：按能力拆分的工具包，数量继续增加
- `packages/mecha`：跨宿主 Agent 配置、上下文工程、工具规则与模型参数解析
- `packages/html-artifact`：HTML Artifact 资源收集、打包与发布核心
- `packages/database/src/repositories/ftsSearch`：Provider 中立全文搜索与 Elasticsearch 候选后端

`apps/` 保持六个 workspace：`auth`、`cli`、`desktop`、`server`、`share`、`workbench`。桌面通过 `apps/desktop` 的独立主进程包与 Web 前端桥接；本次未验证各桌面发行目标的运行结果。

## 关键源码索引

- `pnpm-workspace.yaml`：应用与包的 workspace 边界
- `package.json`：桌面构建入口
- `oxlint.config.mts`、`alint.config.toml`、`lint.bundleBoundaries.mjs`：lint 与包边界治理
- `apps/`、`packages/`、`src/features/`、`src/store/`：主要模块树

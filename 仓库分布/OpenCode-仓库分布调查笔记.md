# OpenCode 仓库分布调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1` 口径），并复核 Bun workspace、package.json 入口与各包职责；未运行构建与测试
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；不覆盖各功能实现细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-11-04，版本 2.2.5）：Git 跟踪文件 9221 个；可识别源码 5942 文件 / 约 109 万行；文档 877 文件 / 约 25.3 万行；测试 1965 文件 / 约 38.8 万行。仓库为浅克隆：主线首提交 2026-08-04，跨度 92 天共 1771 次首个父提交，折算约 578 次/30 天，近 90 天 1738 次。

## 结论摘要

OpenCode 是一个以 packages 目录划分模块的 Bun/TypeScript monorepo，共 36 个包，依赖按 Schema → Core/Protocol → Server 分层，客户端由 Client 包生成，SDK 再把三者组合成对外接口；仓库同时交付 CLI/TUI、Solid Web App、Electron 桌面、console 与 stats 两个站点、GUI 插件运行时和共享 UI。源码规模最大的是 Web App（`packages/app`）与运行时核心（`packages/core`），终端界面、AI 能力、GUI 插件运行时紧随其后；文档大部分来自 `packages/web` 的多语言站点与 `services/www`。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 9221 |
| 可识别源码 | 5942 文件 / 1,089,965 行 |
| 文档 | 877 文件 / 252,824 行 |
| 测试 | 1965 文件 / 388,300 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `packages/app` | 940 / 222,950 |
| `packages/core` | 937 / 205,862 |
| `packages/tui` | 551 / 115,553 |
| `packages/ai` | 776 / 87,593 |
| `packages/gui-plugins` | 876 / 59,386 |
| `packages/ui` | 1,716 / 59,038 |
| `packages/session-ui` | 198 / 41,044 |
| `packages/codemode` | 105 / 33,679 |
| `packages/cli` | 216 / 26,722 |
| `packages/console` | 215 / 25,096 |

TypeScript 约 102.2 万行（93.8%），CSS 47,671 行（4.4%），Rust 13,923 行（1.3%），其余 Astro、JavaScript、Shell、SQL 合计不足 1%。

## 包结构与分层

包之间的依赖方向由仓库 AGENTS 约定收紧：Schema 位于最底层，被 Core 与 Protocol 依赖，这两者再被 Server 依赖；Client 只依赖 Schema 与 Protocol；SDK 组合 Client、Core 与 Server。各包的职责分工如下：

| 包 | 职责 |
| --- | --- |
| `packages/core` | 运行时核心：会话、工具、权限、provider、MCP、插件、Skill、PTY、调度等 Effect 服务 |
| `packages/protocol`、`packages/server` | HTTP 契约 |
| `packages/ai` | 生成式能力 |
| `packages/app` | Solid Web App |
| `packages/session-ui` | 会话渲染组件 |
| `packages/ui` | 共享 UI |
| `packages/tui` | 终端界面 |
| `packages/desktop` | 桌面壳 |
| `packages/gui-plugins` | GUI 插件运行时 |

其余成员包括下面这些包：

- `packages/merman`
- `packages/latex`
- `packages/patchmark`
- `packages/process-daemon`
- `packages/plugins`
- `packages/plugin-browser`
- `packages/stories`
- `packages/simulation`
- `packages/posts`
- `packages/theme`
- `packages/util`

## 文档与测试

文档主要落在 `packages/web` 的多语言站点（562 文件 / 约 19 万行），`services/www` 与 `packages/plugins` 另有补充，插件文档集中在后者。测试共 1965 文件，主要集中在以下几个包：

| 包 | 测试文件 |
| --- | ---: |
| `packages/ai` | 518 |
| `packages/core` | 396 |
| `packages/app` | 315 |
| `packages/tui` | 210 |
| `packages/codemode` | 45 |

## 跨平台组织与边界

跨平台的各个表面都收在 `packages` 目录下：CLI 与 TUI 打进同一个 CLI 包，根脚本 `dev` 直接运行 `packages/cli/src/index.ts`，TUI 和 Web App 一样用 Solid/TypeScript 实现。Web App 落在 `packages/app`，桌面应用落在 `packages/desktop`，后者是一层 Electron 壳，渲染进程复用 app 包、主进程位于 `packages/desktop/src/main`。`packages/web` 是官网与文档站，`packages/console` 与 `packages/stats` 是另外两个独立子站点。根 `package.json` 还为各目标分别注册了 dev 脚本，涵盖 live、desktop、web、console 与 www。

## 关键源码索引

- `package.json:1-60`：版本、Bun workspace 与各入口脚本
- `AGENTS.md`：包依赖方向与 Effect 风格约定
- `packages/core/src/`：运行时核心服务
- `packages/app/src/`、`packages/tui/src/`、`packages/desktop/src/`：三个客户端表面
- `packages/protocol/src/`、`packages/server/src/`、`packages/client/src/`、`packages/sdk/src/`：契约与客户端分层

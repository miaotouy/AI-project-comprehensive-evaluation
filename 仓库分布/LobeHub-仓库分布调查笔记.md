# LobeHub 仓库分布调查笔记

> 调查对象：`../../lobehub`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`5952f4c3f29ed3bb08dda6fd5fd64d6fffd4d3ae`（分支：`canary`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 pnpm workspace、应用/包清单、部署与桌面构建入口
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 是本组跟踪文件最多的 TypeScript monorepo，主 Web 应用、独立 server、Electron desktop、CLI 与大量业务/工具包共仓。代码没有只集中在单一 `src`：`apps/server`、`src/features`、database、store、model-runtime 和 routes 都是十万行级区域，显示其前后端与运行时边界已包化。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 14,047 |
| 可识别源码 | 11,620 文件 / 1,893,137 行 |
| 文档 | 792 文件 / 160,615 行 |
| 测试 | 2,876 文件 / 772,106 源码行 |

主要区域为 `apps/server`（1,453 文件/375,932 行）、`src/features`（2,399/284,652）、`packages/database`（652/161,644）、`src/store`（820/159,888）、`packages/model-runtime`（442/130,233）、`src/routes`（1,298/120,160）和 `apps/desktop`（412/65,555）。

## 语言、文档与测试

TypeScript 1,870,741 行（98.8%）。文档主要位于 `docs/usage`（221 文件）、`docs/self-hosting`（150）、`.agents/skills`（172）；`changelog` 仅 2 个文件却有 47,939 行，是按行数观察文档时的异常集中点。测试分布在 server（592 文件）、database（184）、model-runtime（191）、store（233）、features（416）与 desktop（100），跨越主要区域。

## 跨平台组织与边界

Web/自托管服务是主形态，另有 Docker 部署、独立 server、CLI 和 Electron desktop workspace（`pnpm-workspace.yaml:2-7`）。桌面通过 `apps/desktop` 的独立主进程包与 Web 前端桥接，不是把全部服务端代码复制进桌面目录；本次未复核各桌面发行目标的运行结果。

## 关键源码索引

- `pnpm-workspace.yaml:2-7`：应用与包的 workspace 边界
- `package.json:63-73`：桌面构建入口
- `apps/`、`packages/`、`src/features/`、`src/store/`：主要模块树

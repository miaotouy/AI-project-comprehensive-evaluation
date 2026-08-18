# Hermes Agent 仓库分布调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`76d832d3857551a029c4b39c23945eb47c16fe5b`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 Python/npm 工作区、应用入口、平台说明与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行安装、应用与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes Agent 是本组中运行面和配套资产最广的混合 monorepo：Python Agent/CLI/gateway/tools 与 TypeScript 桌面、Web、TUI 同仓，还包含 skills、插件和文档站。测试源码 821,783 行，约占全仓可识别源码 39.2%；文档 1,528 文件，其中大量来自技能包和多语言站点。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 8,748 |
| 可识别源码 | 6,270 文件 / 2,094,425 行 |
| 文档 | 1,528 文件 / 462,283 行 |
| 测试 | 3,604 文件 / 821,783 源码行 |

产品区域量级：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `apps/desktop` | 1,561 / 324,484 |
| `hermes_cli` | 196,956 行 |
| `agent` | 114,650 行 |
| `tools` | 112,750 行 |

测试按 gateway（151,809 行）、tools（122,570）、CLI（121,689）、agent（92,536）与桌面应用（90,878）分别成树，模块覆盖可见。

## 语言、文档与测试

Python 1,567,851 行（74.9%）、TypeScript 461,514 行（22.0%）。

文档主要由 `website`（710 文件，其中 docs 与 i18n 两个子目录分别为 393 与 316）、`optional-skills`（415）和 `skills`（334）组成；技能说明占比很高，独立主题数不能由 1,528 直接推出。

测试文件/源码文件比为 57.5%，是本组最高值，但该比例同样包含夹具和测试资源。

## 跨平台组织与边界

README 明确区分 Linux/macOS/WSL2、原生 Windows 和 Android/Termux 安装（`README.md:37-59`）。Python 核心跨平台，npm workspace（`package.json:5-10`）把其余部分组织为独立成员：

- `apps/*`
- `ui-tui` 及 `ui-tui/packages/*`
- `web`
- `tests-js`

桌面壳、Web 和 TUI 是独立入口，共享 Agent/gateway 协议而非一个响应式 UI。

## 关键源码索引

- `pyproject.toml`：Python 核心、平台条件依赖与可选能力
- `package.json:5-10`：npm workspace（Web/TUI/桌面/共享 TS 测试包）
- `apps/desktop/`、`hermes_cli/`、`agent/`、`gateway/`、`tests/`：主要边界

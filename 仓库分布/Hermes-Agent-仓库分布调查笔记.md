# Hermes Agent 仓库分布调查笔记

> 调查对象：`../../hermes-agent`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`01a1037d1e6d7b6eb96a786ef282c3aea4818194`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Python/npm 工作区、应用入口、平台说明与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行安装、应用与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes Agent 是本组中运行面和配套资产最广的混合 monorepo：Python Agent/CLI/gateway/tools 与 TypeScript 桌面、Web、TUI 同仓，还包含 skills、插件和文档站。测试源码 762,934 行，约占全仓可识别源码 38.3%；文档 1,509 文件，其中大量来自技能包和多语言站点。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 8,524 |
| 可识别源码 | 6,025 文件 / 1,993,974 行 |
| 文档 | 1,509 文件 / 461,094 行 |
| 测试 | 3,423 文件 / 762,934 源码行 |

产品区域中 `apps/desktop` 为 1,506 文件/311,084 行，`hermes_cli` 189,340 行，`agent` 110,783 行，`tools` 104,611 行。测试按 gateway（143,174 行）、tools（111,588）、CLI（111,356）、agent（88,092）以及桌面应用（86,043）分别成树，模块覆盖可见。

## 语言、文档与测试

Python 1,484,128 行（74.4%）、TypeScript 448,716 行（22.5%）。文档主要由 `website/docs`（381 文件）、`website/i18n`（317）、`optional-skills` 与 `skills` 组成；技能说明占比很高，独立主题数不能由 1,509 直接推出。测试文件/源码文件比为 56.8%，是本组最高值，但该比例同样包含夹具和测试资源。

## 跨平台组织与边界

README 明确区分 Linux/macOS/WSL2、原生 Windows 和 Android/Termux 安装（`README.md:37-59`）。Python 核心跨平台，npm workspace 再组织 `apps/desktop`、`web` 与 `ui-tui`（`package.json:6-18`）；桌面壳、Web 和 TUI 是独立入口，共享 Agent/gateway 协议而非一个响应式 UI。

## 关键源码索引

- `pyproject.toml`：Python 核心、平台条件依赖与可选能力
- `package.json:6-24`：Web/TUI/桌面工作区
- `apps/desktop/`、`hermes_cli/`、`agent/`、`gateway/`、`tests/`：主要边界

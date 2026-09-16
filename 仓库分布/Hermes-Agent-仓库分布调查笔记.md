# Hermes Agent 仓库分布调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`682a95258ce9e877cfb607a5ada6436183efdebb`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 Python/npm 工作区、应用入口、平台说明与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行安装、应用与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

当前快照：Git 跟踪文件 13,516 个；可识别源码 9,948 文件 / 2,739,531 行；文档 1,673 文件 / 493,958 行；测试 5,812 文件 / 1,381,872 源码行。主线历史在当前浅克隆中覆盖 42 天、9,751 次 first-parent 提交，折算 6,965 次/30 天；该节奏受浅克隆边界影响，不代表项目完整历史。

## 结论摘要

Hermes Agent 把 Python Agent/CLI/gateway/tools 与 TypeScript 桌面、Web、TUI 放在同一仓库，另含 skills、插件和文档站。测试源码 1,381,872 行，约占全仓可识别源码 50.4%；文档 1,673 文件，其中大量来自技能包和多语言站点。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 13,516 |
| 可识别源码 | 9,948 文件 / 2,739,531 行 |
| 文档 | 1,673 文件 / 493,958 行 |
| 测试 | 5,812 文件 / 1,381,872 源码行 |

产品区域量级：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `apps/desktop` | 2,639 / 596,485 |
| `hermes_cli` | 370 / 187,370 |
| `agent` | 224 / 100,446 |
| `tools` | 257 / 94,028 |

测试按 CLI（261,874 行）、gateway（234,427）、agent（217,832）、tools（183,447）与桌面应用等区域分别成树。

## 语言、文档与测试

Python 1,899,875 行（69.4%）、TypeScript 752,790 行（27.5%）。

文档主要由 `website`（775 文件）、`optional-skills`（546）和 `skills`（262）组成；技能说明占比很高，独立主题数不能由 1,673 直接推出。

测试文件/源码文件比为 58.4%，但该比例同样包含夹具和测试资源。

## 跨平台组织与边界

README 明确区分 Linux/macOS/WSL2、原生 Windows 和 Android/Termux 安装（`README.md:37-59`）。Python 核心跨平台，npm workspace（`package.json:5-10`）把其余部分组织为独立成员：

- `apps/*`
- `ui-tui` 及 `ui-tui/packages/*`
- `web`
- `tests-js`

桌面壳、Web 和 TUI 是独立入口，共享 Agent/gateway 协议，各自实现界面。

## 关键源码索引

- `pyproject.toml`：Python 核心、平台条件依赖与可选能力
- `package.json:5-10`：npm workspace（Web/TUI/桌面/共享 TS 测试包）
- `apps/desktop/`、`hermes_cli/`、`agent/`、`gateway/`、`tests/`：主要边界

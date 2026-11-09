# Hermes Agent 仓库分布调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（按扩展名与目录规则统计文件数和行数，`git grep -c` 逐文件计数），并复核 Python/npm 工作区、应用入口、`AGENTS.md` 的代码组织约定与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行安装、应用与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

当前快照：Git 跟踪文件 22,277 个；可识别源码 16,530 文件 / 3,926,257 行；文档 1,551 文件 / 450,056 行；测试 7,620 文件 / 1,594,365 行。主线历史在当前克隆中覆盖 2025-07-22 至 2026-11-03 共 469 天、29,465 次 first-parent 提交，折算约 1,884 次/30 天。

## 结论摘要

Hermes Agent 把 Python Agent/CLI/gateway/tools 与 TypeScript 桌面、Web、TUI 放在同一仓库，另含 skills、插件、插件目录和文档站。测试约占全仓可识别源码行数的 40.6%，低于源码本身的增速；文档 1,551 文件，其中技能包与文档站占八成以上。

仓库的代码组织遵循一条成文约定：每个"巨型文件"是 facade（只保留公共入口与其他包引用的名字），实现按主题拆到同名前缀的兄弟模块（如 `hermes_state.py` 与 63 个 `hermes_state_*.py`）。`pm/`（依赖与环境管理器）、`hermes_platform/`（机器事实与可执行文件解析）、`native/fts5_cjk`（SQLite 全文检索扩展）与 `locales/`（TUI 与桌面共用词典）同样在仓库内。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 22,277 |
| 可识别源码 | 16,530 文件 / 3,926,257 行 |
| 文档 | 1,551 文件 / 450,056 行 |
| 测试 | 7,620 文件 / 1,594,365 行 |

产品区域量级（仅源码扩展名）：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `apps/desktop` | 4,624 / 971,273 |
| `hermes_cli` | 814 / 309,949 |
| `agent` | 415 / 150,205 |
| `tools` | 368 / 130,212 |
| `gateway` | 348 / 129,760 |
| `ui-tui` | 629 / 120,243 |

测试按 CLI（约 26 万行）、gateway、agent、tools 与桌面应用等区域分别成树，`tests/` 与 `tests-js/` 合计 7,620 个源码文件；`tests/hermes_cli`、`tests/gateway`、`tests/agent` 是本快照增长最快的测试子树。

`plugin-catalog/` 是插件目录条目的数据目录，978 个 JSON/YAML/Markdown 文件、22,567 行，不含可执行源码，因此不计入源码统计。

## 语言、文档与测试

Python 2,632,227 行（67.0%）、TypeScript 1,153,846 行（29.4%）、JavaScript 75,315 行（1.9%），其余为样式、脚本与少量原生代码。

文档主要由 `website`（700 文件 / 241,922 行）、`optional-skills`（514 / 143,801）和 `skills`（240 / 49,742）组成；技能说明占比高，独立主题数不能由 1,551 直接推出。

测试文件与源码文件比为 46.1%，测试行占源码行 40.6%；这一比例包含夹具与测试资源，覆盖率需由插桩运行单独测量。

## 代码组织约定

`AGENTS.md:101-118` 定义了全仓通行的 facade + siblings 布局：facade 保留公共入口，主题实现放在 `<stem>_<topic>.py` 兄弟模块；兄弟模块在函数内部延迟导入 facade，避免模块级循环；补丁要打在"生产代码读取的位置"。

同一节还给出按单元收紧的规模门禁（`scripts/code_health/config.py`）：新函数复杂度不超过 20、函数不超过 300 行、嵌套不超过 6 层、文件不超过 2,000 行，已超限单元只能下降。内部移动不保留 re-export 垫片，移动符号须同 PR 修正所有文档与 `AGENTS.md` 引用。

这条约定直接决定了目录形态：`run_agent.py` 是 AIAgent facade，回合循环在 `agent/turn_*.py`；`gateway/run.py` 是 facade，阶段实现是 `run_*.py`；`cli.py` 是 HermesCLI facade，混入实现是 `hermes_cli/cli_*_mixin.py`；`hermes_state.py` 是 SessionDB facade，63 个 `hermes_state_*.py` 覆盖会话、消息、压缩、搜索、锁、迁移、工作线程等主题。

## 跨平台组织与边界

README 明确区分 Linux/macOS/WSL2、原生 Windows 与 Android/Termux 安装路径（`README.md:35-56`）。Python 核心跨平台，npm workspace（`package.json:6-12`）把其余部分组织为独立成员：

- `apps/*`（桌面壳与 bootstrap 安装器、共享层）
- `ui-tui` 及 `ui-tui/packages/*`
- `web`（dashboard SPA）
- `tests-js`

桌面壳、Web 和 TUI 是独立入口，共享 Agent/gateway 协议，各自实现界面；`tui_gateway` 作为 Ink TUI 的 Python JSON-RPC 后端同时服务桌面端。Python 侧要求 `>=3.11,<3.15`，所有直接依赖精确锁定版本（`pyproject.toml:12-30`）。

## 关键源码索引

- `AGENTS.md:71-118`：项目结构与 facade + siblings 约定、规模门禁
- `pyproject.toml`：Python 核心、平台条件依赖与可选能力（依赖精确锁定、Python 版本窗口）
- `package.json:6-12`：npm workspace（Web/TUI/桌面/共享 TS 测试包）
- `hermes_state*.py`：SessionDB facade 与 63 个主题兄弟模块
- `pm/`、`hermes_platform/`、`native/fts5_cjk/`、`locales/`、`plugin-catalog/`：本快照新增的顶层区域
- `apps/desktop/`、`hermes_cli/`、`agent/`、`gateway/`、`tools/`、`tests/`：主要边界

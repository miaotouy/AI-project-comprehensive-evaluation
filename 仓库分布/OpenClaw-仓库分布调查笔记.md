# OpenClaw 仓库分布调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`55a554e78a83af031760ef247e26d5be9e24329d`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（逐文件字节计数，排除 `node_modules` 与构建产物），并复核 pnpm workspace、Gateway/CLI/TUI、Control UI、apps 与 extensions 入口
>
> 调查范围：模块、语言、文档、测试、渠道扩展与平台组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 是以本地 Gateway 为控制平面的多渠道个人 AI 助手仓库。`src` 承担 Gateway、会话、工具和 CLI 主链，`extensions` 承担消息渠道与插件，`ui` 与 `apps` 提供 Control UI、桌面及移动伴侣应用，`packages` 提供共享 SDK/协议。当前快照有 63,787 个 Git 跟踪文件、55,362 个可识别源码文件 / 12,650,472 行源码。

仓库仍以 TypeScript 单语言为主（约 87.4% 源码行），但工程配套区域明显变厚：`scripts` 逼近百万行、`config` 与 `qa` 成为独立大区，并在根目录新增 Rust crate、`custodian-skills`、`security`、`patches`、`deploy` 等目录。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 63,787 |
| 可识别源码 | 55,362 文件 / 12,650,472 行 |
| 文档 | 2,384 文件 / 631,954 行 |
| 测试 | 23,788 文件 / 6,408,658 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `src` | 28,963 / 6,491,060 |
| `extensions` | 12,742 / 2,396,951 |
| `ui` | 7,349 / 1,828,985 |
| `apps` | 3,123 / 1,004,188 |
| `scripts` | 3,087 / 941,993 |
| `test` | 2,607 / 750,671 |
| `packages` | 1,585 / 259,293 |
| `docs` | 1,494 / 454,046 |
| `config` | 1,233 / 20,037 |
| `qa` | 621 / 52,083 |
| `.agents` | 303 / 77,968 |
| `crates` | 48 / 24,282 |

根 `package.json` 与 `pnpm-workspace.yaml` 声明 pnpm 工作区，发布入口为 `openclaw.mjs`；`cli-invocation.mjs`、`cli-root-options.mjs`、`cli-parent-lifetime.mjs` 等根级 `.mjs` 与对应 `.d.mts` 承担 CLI 启动期的参数与生命周期约定。扩展目录按渠道和能力拆分，共 192 个一级扩展目录，主运行时仍由 `src` 统一调度。`crates` 承载 Rust 侧实现（如原生辅助能力），`qa`、`custodian-skills`、`skills` 存放质量资产与可执行知识。

## 语言、文档与测试

TypeScript 11,055,207 行（约 87.4%），Swift 490,980 行，Kotlin 259,741 行，JS 350,048 行，TSX 375,371 行，CSS 116,401 行。Swift/Kotlin 主要服务 companion app 与平台集成，TypeScript 覆盖 Gateway、工具、UI、扩展和测试。

文档共 2,384 个文件 / 631,954 行（`docs`、`.agents`、扩展目录、`skills` 与根级说明文件共同贡献），其中 `docs/` 约 45 万行。测试共 23,788 个文件 / 6,408,658 行，分布跟随 `src`（12,194 个文件）、`extensions`（4,408）、`ui`（3,267）与顶层 `test`（2,607）；测试按同目录 `*.test.ts` 与独立 `test/` 树两种方式组织。未运行测试。

## 跨平台与工程配套

README 与安装脚本覆盖 macOS、Linux、Windows/WSL；Gateway、CLI、TUI、Control UI 和桌面/移动 companion apps 通过共享协议连接。`apps`、`ui`、`extensions`、`crates`、`deploy`、`.github/workflows` 和 `scripts` 分别承担平台应用、控制界面、渠道插件、原生组件、发行与自动化配套。工程侧另有 `patches`（依赖补丁）、`security`（安全策略与审计材料）、`config`（运行期配置模板）与 `qa`（质量校验资产）。工具默认在主机执行，沙箱由配置选择，属于运行时边界而非单独仓库。

## 已确认边界与未验证事项

- 统计包含扩展、翻译、文档、技能、测试、配置模板与发布资源；这些资产显著影响文件数与行数。
- 主线提交历史为浅克隆（45,495 次提交，当前可见跨度 2026-08-15 至 2026-11-04），不代表完整历史；跨快照的仓库演化只能基于可见窗口判断。
- 行数为逐文件字节计数，不排除生成物（如 `config/` 下的模板与快照），因此与按语言工具链统计的口径存在差异。
- 本次未运行 Gateway、渠道适配、桌面/移动应用构建或端到端测试，也未验证 Rust crate 是否参与默认构建。

## 关键源码索引

- `package.json`、`pnpm-workspace.yaml`、`openclaw.mjs`：工作区与发布入口
- `cli-invocation.mjs`、`cli-root-options.mjs`、`cli-parent-lifetime.mjs`：CLI 启动期参数解析与父进程生命周期
- `src/`：Gateway、Agent、会话、工具与 CLI 主链
- `extensions/`：消息渠道和可选能力扩展（192 个一级目录）
- `ui/`、`apps/`：Control UI 与 companion apps
- `packages/`：共享 SDK 与协议
- `crates/`、`config/`、`qa/`、`patches/`：原生组件、配置模板、质量资产与依赖补丁
- `docs/`、`test/`：文档与测试资产

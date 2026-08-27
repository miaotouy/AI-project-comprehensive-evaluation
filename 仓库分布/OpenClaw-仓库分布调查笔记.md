# OpenClaw 仓库分布调查笔记

> 调查对象：`https://github.com/openclaw/openclaw`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`c64a640f5df5bc72537357417c54647c050cb863`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 pnpm workspace、Gateway/CLI/TUI、Control UI、apps 与 extensions 入口
>
> 调查范围：模块、语言、文档、测试、渠道扩展与平台组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenClaw 是以本地 Gateway 为控制平面的多渠道个人 AI 助手仓库。`src` 承担 Gateway、会话、工具和 CLI 主链，`extensions` 承担消息渠道与插件，`ui` 与 `apps` 提供 Control UI、桌面及移动伴侣应用，`packages` 提供共享 SDK/协议。当前快照有 34,147 个跟踪文件、30,474 个源码文件 / 9,092,080 行源码，是本次统计对象中规模最大的仓库之一。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 34,147 |
| 可识别源码 | 30,474 文件 / 9,092,080 行 |
| 文档 | 1,295 文件 / 259,536 行 |
| 测试 | 12,690 文件 / 5,028,997 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `src` | 14,971 / 4,536,635 |
| `extensions` | 9,016 / 2,321,506 |
| `ui` | 2,947 / 785,732 |
| `apps` | 2,141 / 576,093 |
| `test` | 1,065 / 335,655 |
| `packages` | 993 / 188,663 |

根 `package.json` 与 `pnpm-workspace.yaml` 声明 pnpm 工作区，发布入口为 `openclaw.mjs`。扩展目录按渠道和能力拆分，主运行时仍由 `src` 统一调度。

## 语言、文档与测试

TypeScript 8,296,513 行（约 91.3%），Swift 386,660 行，Kotlin 172,126 行；JavaScript 与 CSS 为次要配套语言。Swift/Kotlin 主要服务 companion app 与平台集成，TypeScript 覆盖 Gateway、工具、UI、扩展和测试。

文档共 1,295 个文件，`docs` 占 788 个文件 / 200,284 行，`.agents`、扩展目录和 skills 还包含大量可执行知识与说明资产。测试文件集中在 `src`（6,174）、`extensions`（3,155）、`ui`（1,089）、`test`（1,065）和 `apps`（592），与主要运行面基本对应；本次未运行测试。

## 跨平台与工程配套

README 与安装脚本覆盖 macOS、Linux、Windows/WSL；Gateway、CLI、TUI、Control UI 和桌面/移动 companion apps 通过共享协议连接。`apps`、`ui`、`extensions`、`deploy`、`.github/workflows` 和 `scripts` 分别承担平台应用、控制界面、渠道插件、发行与自动化配套。工具默认在主机执行，沙箱由配置选择，属于运行时边界而非单独仓库。

## 已确认边界与未验证事项

- 统计包含扩展、翻译、文档、技能、测试和发布资源；这些资产显著影响文件数与行数。
- 主线提交历史为浅克隆（3,536 次提交，历史跨度 11 天），不代表完整历史。
- 本次未运行 Gateway、渠道适配、桌面/移动应用构建或端到端测试。

## 关键源码索引

- `package.json`、`pnpm-workspace.yaml`、`openclaw.mjs`：工作区与发布入口
- `src/`：Gateway、Agent、会话、工具与 CLI 主链
- `extensions/`：消息渠道和可选能力扩展
- `ui/`、`apps/`：Control UI 与 companion apps
- `docs/`、`test/`：文档与测试资产

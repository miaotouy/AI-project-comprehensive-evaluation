# Codex 仓库分布调查笔记

> 调查对象：`https://github.com/openai/codex`
>
> 调查更新日期：2026-09-18
>
> 代码快照：`7498521d288b9b3b96ffba4eedf089d8d6e06a84`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1` 口径），并复核 Cargo workspace、Bazel 构建、pnpm workspace、发布工作流与各运行时入口
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-09-18）：Git 跟踪文件 8282 个；可识别源码 5492 文件 / 1898622 行；文档 637 文件 / 23791 行；测试 991 文件 / 452925 源码行。提交节奏：本地为浅克隆，first-parent 窗口仅覆盖 2026-09-08 至 2026-09-18 的 500 次主线提交，不能代表长期节奏。

## 结论摘要

Codex 是 OpenAI 的本地编码 Agent（Codex CLI）仓库，主体是单个 Rust Cargo workspace（约 149 个成员 crate），并叠加 Bazel 构建、pnpm 工作区与多语言 SDK/打包层。仓库形态可概括为“原生 CLI/TUI 运行时 + app-server 协议面 + 跨语言 SDK 与安装器”：Rust 占可识别源码约 95%，Python 与 TypeScript 主要承担 SDK、脚本和由协议生成的绑定，不是应用主体。与调查中多数 Electron/TypeScript 客户端不同，它的体积和复杂度集中在原生核心、按操作系统的沙箱实现、协议契约以及为多平台发行服务的工程配套上。

## 统计口径与仓库形态

统计只覆盖当前 commit 的 Git 跟踪文件，规则见[调查指南](调查指南.md)，由[统计仓库.ps1](统计仓库.ps1) 生成底稿。顶层目录分工如下：

| 顶层目录 | 文件数 | 角色 |
| --- | ---: | --- |
| `codex-rs` | 7765 | Rust workspace 主体：CLI、TUI、core、app-server、沙箱、协议与各能力 crate |
| `sdk` | 123 | Python SDK、Python 运行时打包、TypeScript SDK |
| `scripts` | 60 | 打包、安装、MCP 一致性、仓库自检等 Python/Shell 脚本 |
| `.github` | 113 | CI、发布、策略与自动化工作流 |
| `third_party` | 60 | v8、voice、wezterm、wine、powershell 的 Bazel 构建胶水 |
| `tools` | 31 | `argument-comment-lint` 等仓库内开发工具 |
| `bazel` | 23 | Bazel 平台、规则、模块与工具链定义 |
| `.codex` | 18 | 仓库自带的环境定义与 Agent skills |
| `codex-cli` | 7 | npm 包 `@openai/codex` 的包装与容器脚本 |
| `patches` | 31 | Bazel 规则、rusty_v8 与 Windows 工具链补丁 |
| `docs` | 15 | 面向用户/贡献者的独立文档 |
| 根目录文件 | 33 | 构建入口与仓库级配置 |

构建编排有三层：Cargo 负责开发态编译与测试，Bazel（`MODULE.bazel`、`BUILD.bazel`、`defs.bzl`、`bazel/`）负责可复现发行与 v8/voice 等原生依赖，pnpm 工作区只包含 `codex-cli`、`sdk/typescript` 与 `codex-rs/responses-api-proxy/npm` 三个发布包。`justfile` 是统一任务入口。

## 1. 模块分布与量级

源码几乎全部落在 `codex-rs`（1,829,654 行，占可识别源码 96%）。主要区域按物理行排序：

| 区域 | 文件 / 行数 | 说明 |
| --- | ---: | --- |
| `codex-rs/core` | 792 / 397535 | Agent 主循环、模型交互、会话与工具编排核心 |
| `codex-rs/tui` | 2326 / 369994 | 终端界面；文件数被 1,149 个 `.snap` 快照与动画帧夹具抬高 |
| `codex-rs/app-server` | 317 / 179822 | 面向 IDE/客户端/SDK 的 JSON-RPC 服务端 |
| `codex-rs/exec-server` | 157 / 57568 | 执行服务与协议 |
| `codex-rs/ext` | 288 / 57197 | 15 个能力扩展 crate（mcp、skills、web-search、image-generation、memories、goal 等） |
| `codex-rs/core-plugins` | 87 / 45667 | 核心插件宿主 |
| `codex-rs/app-server-protocol` | 1106 / 43101 | 协议契约区：310 份 JSON schema + 726 份生成 TypeScript 绑定 |
| `codex-rs/cli` | 103 / 37826 | `codex` 二进制入口与子命令 |
| `codex-rs/rmcp-client` | 100 / 35142 | MCP 客户端 |
| `codex-rs/thread-store` | 69 / 33659 | 会话线程持久化 |
| `codex-rs/windows-sandbox-rs` | 115 / 29294 | Windows 沙箱实现 |
| `codex-rs/network-proxy` | 63 / 29098 | 网络代理与出站控制 |
| `sdk/python` | 87 / 27507 | Python SDK（含文档、示例与测试） |

Cargo workspace 的 `members` 列表有 149 项，按能力域拆得很细：既有 `core`、`tui`、`app-server` 这样的产品面，也有 `linux-sandbox`、`windows-sandbox-rs`、`mxc-sandbox`、`bwrap` 的平台沙箱，`config`、`protocol`、`app-server-protocol` 的契约层，`ollama`、`lmstudio`、`model-provider`、`models-manager` 的模型接入，以及大量 `utils/*` 小 crate。目录深度普遍为 1 至 2 层，模块边界基本与 crate 边界一致。

## 2. 语言分布与运行时分工

| 语言 | 文件 | 行数 | 占可识别源码 |
| --- | ---: | ---: | ---: |
| Rust | 4405 | 1805616 | 95.1% |
| Python | 198 | 63664 | 3.4% |
| TypeScript | 750 | 11369 | 0.6% |
| C | 6 | 5970 | 0.3% |
| Shell | 36 | 5145 | 0.3% |
| PowerShell | 8 | 2441 | 0.1% |

Rust 承担产品主体。Python 的 198 个文件里，除 SDK 与运行时打包外还有 `scripts/` 下的仓库自检、MCP 一致性、安装与打包脚本；TypeScript 的 750 个文件中有 726 个位于 `app-server-protocol/schema/typescript`，是由协议 schema 生成的类型绑定，平均行数很低，真正的应用级 TS 只有 `sdk/typescript` 的二十余个源文件。因此 TypeScript 在本仓不代表前端运行时，而是协议消费方。C 的 6 个文件来自 v8/voice 等原生构建胶水，PowerShell 集中在 Windows 安装与构建脚本。

## 3. 文档分布

独立文档树很小：根 `docs/` 只有 15 份（getting-started、config、sandbox、exec、execpolicy、skills、slash_commands、authentication、install、contributing 等），说明完整文档托管在 `developers.openai.com/codex`。637 份文档文件的绝大多数位于 `codex-rs` 内，构成以代码为中心的知识分布：

- 每个 crate 的 README 共 42 份，是最主要的实现说明来源。
- `codex-rs/skills`、`.codex/skills` 与 `codex-rs/memories` 贡献可执行技能与记忆说明，属于能力资产而非开发文档。
- `codex-rs/tui` 的文档计数被动画帧与快照夹具放大，不能按独立主题数理解。
- `third_party/voice` 附带运行时许可与说明。

## 4. 测试分布

测试共 991 文件 / 452,925 源码行，测试文件与源码文件比约 18.0%，但测试行数接近源码的四分之一，说明测试在仓库中占比很高。分布以 crate 内共置为主：

| 区域 | 测试文件 / 源码行 |
| --- | ---: |
| `codex-rs/core` | 234 / 169410 |
| `codex-rs/app-server` | 172 / 121656 |
| `codex-rs/tui` | 215 / 64902 |
| `codex-rs/exec-server` | 34 / 16179 |
| `codex-rs/rmcp-client` | 24 / 10630 |
| `sdk/python` | 21 / 6594 |
| `scripts/mcp_conformance` | 4 / 4670 |

`justfile` 的 `test` 目标统一使用 cargo nextest；`codex-rs/tui` 用 insta `.snap` 做终端渲染快照，`app-server` 与 `exec-server` 各有协议与集成测试。SDK 侧 Python 与 TypeScript 分别维护独立测试与一致性夹具。

## 5. 跨平台与发布组织

发行目标从工作流静态确认：macOS 的 `aarch64-apple-darwin` 与 `x86_64-apple-darwin`，Linux 的 `x86_64-unknown-linux-musl` 与 `aarch64-unknown-linux-musl`（发行物刻意采用 MUSL 静态链接），Windows 由独立的 `rust-release-windows.yml` 承载；每个目标还产出配套的 app-server 工件。安装渠道包括 `install.sh`/`install.ps1`（默认从 `releases.openai.com` 下载并回退 GitHub Releases）、npm `@openai/codex`、Homebrew cask 与 winget 打包脚本。

平台差异没有做成前端探测，而是按操作系统各写沙箱 crate：Linux 用 `linux-sandbox` 与 `bwrap`（另 vendored bubblewrap），Windows 用 `windows-sandbox-rs` 与 `windows-sandbox-service`，macOS 用 `mxc-sandbox`，另由 `sandboxing`、`process-hardening`、`arg0` 统一编排。Bazel 侧为 Windows 工具链、v8 与原生依赖维护了 30 份补丁。

## 6. 工程配套与结构特征

仓库的工程配套密度显著高于同类客户端项目：`.github/workflows` 有 33 个文件，覆盖 Rust CI（含 nextest 平台矩阵与全量作业）、Bazel、cargo-deny、codespell、blob 体积策略、CLA、issue 自动化、Python SDK 与 python-runtime 的独立构建/发布、r2 发布、rusty-v8 与 v8 canary 等。`justfile` 暴露了格式化、clippy、nextest、Bazel 构建/测试、`build-for-release` 与配置/schema 生成等入口；`tools/argument-comment-lint` 是仓库自有的 lint 工具，`third_party/` 为 v8、voice、wezterm、wine、powershell 提供 Bazel 集成。

结构上有几处明显的可观察特征：协议契约被单独抽成 `app-server-protocol`，并由它生成 JSON schema 与 TypeScript 绑定，供 app-server、IDE 与 SDK 共用；`app-server-protocol/schema` 与 `tui` 的快照/帧夹具使“文件数”明显高于“源码量”，阅读时应按源码行而非文件数判断模块规模；`ext/*` 把 MCP、skills、web-search、memories 等能力做成并列扩展 crate，与 core 解耦。

## 7. 设计取舍与已确认边界

Rust 单 workspace 加 Bazel 双构建，适合“原生 CLI 为核心、需要跨平台发行与可复现构建”的产品定位：开发态用 Cargo/nextest 迭代，发行态用 Bazel 统一原生依赖与目标平台。app-server 作为唯一协议面，使 CLI、TUI、IDE 扩展、Python/TypeScript SDK 消费同一套请求/通知定义，代价是协议 schema 与生成绑定成为需要持续同步的契约。按操作系统分写沙箱而非抽象成单一接口，能直接使用各平台原生机制，也意味着每新增一个平台都要补一整套沙箱与加固实现。

本仓不包含图形桌面应用与编辑器扩展本体（README 指向 IDE 安装页与 Codex App 页面），也不包含云端 Agent；这些属于本仓之外的发行面。README 所述平台支持与工作流中的发行矩阵只代表构建配置存在，不代表各平台功能等价。

## 8. 未验证事项

未运行任何构建或测试，因此 Bazel 与 Cargo 两条构建路径的实际可复现性、发行工件内容、跨平台功能等价性均未验证。沙箱实现只做静态目录与 crate 确认，未在任一操作系统观察其运行时行为。发布矩阵与安装渠道来自工作流和 README，未实际执行发布或安装。本地为浅克隆，提交历史与主线节奏只反映最近窗口，不能用于评估长期更新频率。

## 9. 关键源码索引

- `codex-rs/Cargo.toml`：149 个成员的 workspace 清单与共享依赖
- `codex-rs/cli/Cargo.toml`、`codex-rs/cli/src/main.rs`：`codex` 二进制入口
- `codex-rs/core/`：Agent 核心运行时
- `codex-rs/app-server-protocol/schema/`：协议 JSON schema 与生成 TypeScript 绑定
- `codex-rs/tui/`：终端界面
- `sdk/python/`、`sdk/typescript/`：两套 SDK
- `codex-cli/package.json`：npm 包 `@openai/codex`
- `.github/workflows/rust-release.yml`、`rust-release-windows.yml`：发行目标矩阵
- `justfile`：构建、测试与 schema 生成任务入口

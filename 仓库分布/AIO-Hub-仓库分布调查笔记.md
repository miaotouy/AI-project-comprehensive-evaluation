# AIO Hub 仓库分布调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：Git 跟踪文件机械统计（按扩展名与文件名/目录识别源码、文档与测试，行数按 `\n` 计数），并复核 workspace、Tauri 配置、构建脚本与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

Git 跟踪文件 3944 个；可识别源码 3178 文件 / 约 920422 行；文档 477 文件 / 约 99013 行；测试 635 文件 / 约 119197 源码行。主线历史从 2025-07-24 延续至 2026-11-02，首主线提交数 5394，近 90 天 728 次（非浅克隆）。行数沿用该类目统一口径，按 Git 跟踪文件统计，含空行与注释。

## 结论摘要

AIO Hub 是一个多端仓库：Vue/TypeScript 前端承担主体业务，Rust/Tauri 提供桌面外壳，移动端另有独立工作区。源码高度集中在 `src/tools`，该区域约 56.0 万行，占全仓可识别源码约 61%；工具实现与随工具就地维护的 Markdown 说明共处同一物理目录，“工具实现”和“工具说明”因此在目录上重叠。该区域下设子智能体（`sub-agent`）工具目录，48 份 `ARCHITECTURE.md` 按工具就地维护。其余工作区成员的分布如下：

- `packages/`：`agent-preset-core`、`model-metadata-core`、`tool-icons` 三个工作区包
- `src-tauri/crates`：`code-formatter`、`desktop-entry` 两个本地 crate
- workspace 边界：`llm-core` 与上述三个包，共四个成员

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 3944 |
| 可识别源码 | 3178 文件 / 约 920422 行 |
| 文档 | 477 文件 / 约 99013 行 |
| 测试 | 635 文件 / 约 119197 源码行 |

统计口径：源码按扩展名识别并计入测试文件（测试单独再计一次），文档按 Markdown 等文本格式计数，测试按文件名模式与测试目录识别。扩展名与识别规则如下：

```text
源码：.vue/.ts/.tsx/.rs/.js/.css/.scss/.html/.kt/.kts/.cs
文档：.md/.mdx/.rst/.adoc/.asciidoc/.txt
测试：*.test.*、*.spec.*，以及 __tests__/、tests/ 目录
```

主要区域按量级依次为：

| 区域 | 文件 / 源码行 |
| --- | ---: |
| `src/tools` | 1,915 个源码文件 / 约 560,363 行 |
| `mobile/src` | 303 个源码文件 / 约 60,691 行 |
| `src-tauri/src` | 99 个源码文件 / 约 61,408 行 |
| `src/views` | 83 个源码文件 / 约 37,018 行 |
| `src/services` | 55 个源码文件 / 约 15,616 行 |
| `src/llm-apis` | 85 个源码文件 / 约 15,540 行 |

`packages/` 是四包 workspace，根 `package.json:22-26` 把 `packages/*`、`plugins/*` 与 `mobile` 一并纳入 workspace，四个包的行数如下：

| 包 | 行数（约） |
| --- | ---: |
| `llm-core` | 1.78 万 |
| `model-metadata-core` | 1984 |
| `agent-preset-core` | 1665 |
| `tool-icons` | 595 |

`src-tauri/Cargo.toml:31-32` 则以 path 依赖引入 `crates/code-formatter` 与 `crates/desktop-entry` 两个本地 crate。

`src/tools` 下现有 49 个一级条目，其中 48 个是带 `ARCHITECTURE.md` 的工具模块；`weather` 目录当前只有一份功能规划文档，尚未形成工具模块。工具域中体量较大的包括 llm-chat、media-generator、rich-text-renderer、agent-manager、tool-calling、git-committer、window-automator 等，各工具的架构说明与实现同目录维护。

## 语言、文档与测试

TypeScript 约 472,093 行（51.3%）、Vue 约 370,062 行（40.2%）、Rust 约 69,916 行（7.6%），三者对应共享逻辑/业务逻辑、组件模板和 Tauri 原生层。其余语言（JavaScript、CSS、Kotlin 等）合计不足 1%。

文档主要位置：

| 位置 | 文件数 |
| --- | ---: |
| `docs` | 256 |
| `src` | 174 |
| `mobile` | 20 |
| `其他位置` | 27 |

`docs` 内的文档以用户手册和工具说明为主，各子目录篇数分布如下：

| 目录 | 篇数（约） |
| --- | ---: |
| `docs/user-guide` | 129 |
| `docs/design` | 37 |
| `docs/Plan` | 37 |
| `docs/guide` | 28 |
| `docs/architecture` | 22 |

`src` 下的文档几乎全部是随工具的 `ARCHITECTURE.md`、协议说明与计划文档。

测试分布落在五个区域：

| 区域 | 文件数 | 源码行 |
| --- | ---: | ---: |
| `src` | 388 | 74,340 |
| `tests/` | 115 | 22,726（Tauri E2E 与专项验收） |
| `mobile` | 69 | 10,233 |
| `packages` | 35 | 8,089 |
| `scripts` | 28 | 3,809 |

测试/源码文件比约 20%。`tests/tauri-e2e` 是独立于前端单测的桌面端到端验收层；`packages` 与 `scripts` 各自带测试，说明工作区包和性能/解析脚本也被纳入回归范围。

## 跨平台组织与边界

桌面端由根目录的 `src` 前端与 `src-tauri` 原生层共同承载，产出覆盖 Windows、macOS、Linux；移动端在 `mobile/` 下自成一套源码加 Tauri 壳，Android 与 iOS 的构建命令集中于 `package.json:43、66-69`。两端共用同一 workspace 和 `packages/*` 中的协议、元数据包，启动入口各自独立。桌面发布物按 `README.md:286-291` 的矩阵分发：Windows 为 exe 与 portable，macOS 为 dmg，Linux 为 deb、AppImage 与 flatpak。

工程配套方面，`.github/workflows` 覆盖桌面构建、iOS/Android 构建、AppImage/flatpak 验证、PR 检查与文档站部署；`scripts/` 约 142 个文件，包含构建、性能基准、安全扫描、图标/文档校验等入口。本次未实际构建各平台。

## 关键源码索引

- `package.json:22-26`：workspace 声明（`packages/*`、`plugins/*`、`mobile`）
- `package.json:43-118`：桌面/移动/包级构建、检查与测试入口
- `src-tauri/Cargo.toml:31-32`：本地 crate 依赖
- `README.md:286-291`：桌面发布物矩阵
- `mobile/src-tauri/tauri.conf.json`：移动端独立 Tauri 应用
- `src/tools/*/ARCHITECTURE.md`：48 份按工具的架构入口

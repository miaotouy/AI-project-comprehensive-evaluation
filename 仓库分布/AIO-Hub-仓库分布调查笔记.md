# AIO Hub 仓库分布调查笔记

> 调查对象：`../../aio-hub`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`023bc63ac10201bf0f663bf49d642fd55c29a3d0`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（按扩展名与文件名/目录识别源码、文档与测试，行数按 `\n` 计数），并复核 workspace、Tauri 配置、构建脚本与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 是以 Vue/TypeScript 前端为主体、Rust/Tauri 为桌面壳，并带独立移动端工作区的多端仓库。源码集中度依然很高：`src/tools` 单一区域约 44.9 万行，占全仓可识别源码约 62%；它同时包含大量随工具就地维护的 Markdown，因此“工具实现”和“工具说明”在物理目录上重叠。

## 统计与模块分布

| 指标 | 数量（旧快照值） |
| --- | ---: |
| Git 跟踪文件 | 3,003（2,521） |
| 可识别源码（含测试文件） | 2,365 文件 / 727,591 行（1,942 / 618,683） |
| 文档 | 372 文件 / 73,314 行（332 / 65,431） |
| 测试 | 343 文件 / 60,405 行（102 / 20,608） |

统计口径与旧笔记一致：源码按 `.vue/.ts/.tsx/.rs/.js/.css/.scss/.html/.kt/.kts/.cs` 扩展名识别（含测试文件，测试单独再计一次）；文档为 `.md`；测试按 `*.test.*`/`*.spec.*` 文件名或 `__tests__/`、`tests/` 目录识别。本次提交范围内新增约 482 个跟踪文件，主要来自移动端（`mobile/` 测试与组件）、桌面端 `tests/tauri-e2e` 新目录、recall/knowledge-base 重构与 llm-chat 会话持久化改造。

主要区域依次是 `src/tools`（1,482 文件/448,538 源码行，旧 1,359/420,929）、`mobile/src`（295/57,597，旧 172/32,714）、`src-tauri/src`（88/53,904，旧 81/40,794）和桌面视图 `src/views`（66/31,237，旧 64/28,715）。`packages/llm-core` 是较小但独立发布边界，主仓 `package.json:23-26` 将其与 `mobile` 纳入 workspace。

## 语言、文档与测试

TypeScript 338,193 行（46.5%，超过 Vue 成为第一大语言）、Vue 319,291 行（43.9%）、Rust 61,881 行（8.5%），三者对应共享逻辑/业务逻辑、组件模板和 Tauri 原生层。文档主要位于 `src/tools`（122 文件，旧 111）及 `docs/user-guide`（128）、`docs/design`（24，旧 18）、`docs/architecture`（18，旧 17）。测试分布明显扩散：随 `src/tools`（101 文件，旧 44）、`mobile`（65，旧 13）、新增的 `tests/`（97，Tauri E2E 与 Recall 验收）、`src/llm-apis`（20）和 `packages/llm-core`（20）。

## 跨平台组织与边界

根 `src` 与 `src-tauri` 组成 Windows、macOS、Linux 桌面应用；`mobile/src` 与 `mobile/src-tauri` 是另一套 Tauri 移动入口，构建脚本明确提供 Android/iOS 命令（`package.json:50-53`）。桌面和移动端共享 workspace 与部分包，但不是同一入口的条件编译。README 的桌面发布矩阵见 `README.md:209-211`；本次未实际构建各平台。

## 关键源码索引

- `package.json:23-69`：workspace、桌面/移动构建与检查入口
- `src-tauri/Cargo.toml:24-40`：桌面原生能力
- `mobile/src-tauri/tauri.conf.json:1-15`：移动端独立 Tauri 应用

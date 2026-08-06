# AIO Hub 仓库分布调查笔记

> 调查对象：`../../aio-hub`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`eba9d84b234672321312e92ab48bb474cfb0aca4`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 workspace、Tauri 配置、构建脚本与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 是以 Vue/TypeScript 前端为主体、Rust/Tauri 为桌面壳，并带独立移动端工作区的多端仓库。源码集中度很高：`src/tools` 单一区域约 42.1 万行，占全仓可识别源码约 68%；它同时包含大量随工具就地维护的 Markdown，因此“工具实现”和“工具说明”在物理目录上重叠。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 2,521 |
| 可识别源码 | 1,942 文件 / 618,683 行 |
| 文档 | 332 文件 / 65,431 行 |
| 测试 | 102 文件 / 20,608 源码行 |

主要区域依次是 `src/tools`（1,359 文件/420,929 源码行）、桌面后端 `src-tauri/src`（81/40,794）、`mobile/src`（172/32,714）和桌面视图 `src/views`（64/28,715）。`packages/llm-core` 是较小但独立发布边界，主仓 `package.json:23-26` 将其与 `mobile` 纳入 workspace。

## 语言、文档与测试

Vue 296,566 行（47.9%）、TypeScript 274,513 行（44.4%）、Rust 41,042 行（6.6%），三者对应组件模板/业务逻辑、共享逻辑和 Tauri 原生层。文档主要位于 `src/tools`（111 文件）及 `docs/user-guide`（128）、`docs/design`（19）、`docs/architecture`（17）。测试主要随 `src/tools`（44 文件）、`src/llm-apis`（17）和 `packages/llm-core`（17）分布，另有 13 个移动端测试文件。

## 跨平台组织与边界

根 `src` 与 `src-tauri` 组成 Windows、macOS、Linux 桌面应用；`mobile/src` 与 `mobile/src-tauri` 是另一套 Tauri 移动入口，构建脚本明确提供 Android/iOS 命令（`package.json:50-53`）。桌面和移动端共享 workspace 与部分包，但不是同一入口的条件编译。README 的桌面发布矩阵见 `README.md:209-211`；本次未实际构建各平台。

## 关键源码索引

- `package.json:23-69`：workspace、桌面/移动构建与检查入口
- `src-tauri/Cargo.toml:24-40`：桌面原生能力
- `mobile/src-tauri/tauri.conf.json:1-15`：移动端独立 Tauri 应用

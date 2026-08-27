# VCPMobile 仓库分布调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`cecdbe432feda57821938bba7625a272113d21c1`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 pnpm/Vite、Tauri v2 Cargo workspace、Android 配置与 Vitest/ADB 测试入口
>
> 调查范围：模块、语言、文档、测试、Android/桌面平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 是 VCPChat 的移动端项目，采用 Tauri v2 + Vue 3 + Rust，另含 Android/Kotlin 平台代码与插件。`src` 是 Vue/TypeScript 应用层，`src-tauri` 是 Rust 核心、Tauri 命令、数据库和插件，`tests` 提供前端、Rust、Android E2E 与性能入口。当前快照有 689 个跟踪文件、372 个源码文件 / 102,934 行源码。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 689 |
| 可识别源码 | 372 文件 / 102,934 行 |
| 文档 | 132 文件 / 74,890 行 |
| 测试 | 52 文件 / 5,979 源码行 |

| 区域 | 文件 / 行数 |
| --- | ---: |
| `src-tauri` | 291 / 60,915 |
| `src` | 212 / 40,937 |
| `tests` | 13 / 667 |
| `docs` | 99 / 0（文档行数单列统计） |
| `plan` | 29 / 0 |

## 语言、文档与测试

Rust 51,527 行、Vue 21,880 行、TypeScript 18,035 行、Kotlin 8,222 行。Rust 承担流式网络、持久化、Tauri 命令和设备能力；Vue/TypeScript 承担聊天、同步和展示；Kotlin 位于 Android 生成与平台桥接区域。文档 132 个文件，主要位于 `docs`（99 个），`plan` 记录演进与性能研究。测试识别到 52 个文件，分布在 `src`、`src-tauri` 和 `tests`，另有 Android smoke 与性能脚本；本次未运行测试。

## 跨平台与工程配套

根 `package.json` 使用 pnpm/Vite，`src-tauri/Cargo.toml` 声明 Rust workspace 与 Android `aarch64-linux-android` 构建目标。项目主发布面是 Android，Tauri 配置也保留桌面开发入口；`.github/workflows`、`tests/e2e-android` 和 `tests/perf` 形成 CI、设备验证与性能测量边界。README 所述移动能力为静态代码与配置确认，未实际安装 APK 验证。

## 已确认边界与未验证事项

- 统计包含 `docs`、`plan`、壁纸和图标等资源；它们显著影响文件数、文档数与字节数，但不计入源码行。
- 主线提交历史为浅克隆（50 次提交，历史跨度 41 天）。
- 本次未运行 Vite、Cargo、Android 构建、ADB smoke 或性能脚本。

## 关键源码索引

- `package.json`、`vite.config.ts`：前端工作区与构建脚本
- `src/`：Vue/Pinia 应用与聊天同步界面
- `src-tauri/src/`、`src-tauri/plugins/`：Rust 核心、Tauri IPC 与插件
- `tests/e2e-android/`、`tests/perf/`：Android 与性能验证入口

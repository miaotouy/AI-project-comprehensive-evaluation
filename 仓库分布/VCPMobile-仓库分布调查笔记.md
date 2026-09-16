# VCPMobile 仓库分布调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`9da3baac9fb9d610bc31be40a6dc8d6c66774890`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`git ls-files`），并复核 pnpm/Vite、Tauri v2 Cargo workspace、Android 配置与 Vitest/ADB 测试入口
>
> 调查范围：模块、语言、文档、测试、Android/桌面平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 是 VCPChat 的移动端项目，采用 Tauri v2 + Vue 3 + Rust，另含 Android/Kotlin 平台代码与插件。`src` 是 Vue/TypeScript 应用层，`src-tauri` 是 Rust 核心、Tauri 命令、数据库和插件，`tests` 提供前端、Rust、Android E2E 与性能入口。当前快照有 933 个跟踪文件、492 个源码文件 / 约 153,600 行源码。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 933 |
| 可识别源码 | 492 文件 / 153,617 行 |
| 文档（Markdown） | 108 文件 |
| 测试相关文件 | 82 |

| 区域 | 文件 / 代码行数 |
| --- | ---: |
| `src-tauri` | 368 / 84,399 |
| `src` | 314 / 68,996 |
| `tests` | 13 / 0 |
| `docs` | 102 / 0 |
| `plan` | 87 / 0 |

## 语言、文档与测试

Rust 73,978 行、Vue 33,497 行、TypeScript 35,829 行、Kotlin 10,313 行。Rust 承担流式网络、持久化、Tauri 命令和设备能力；Vue/TypeScript 承担聊天、同步和展示；Kotlin 位于 Android 生成与平台桥接区域。文档 108 个 Markdown 文件，主要位于 `docs`（102 个）与 `plan`（87 个，含图片等资源），`plan` 记录演进与性能研究。测试相关文件 82 个，其中 `.test.ts` 55 个、`tests/` 目录 13 个、`src-tauri/tests` 与 `src-tauri/benches` 13 个、`_test.rs` 1 个，另有 Android smoke / instruments 用例与性能脚本；本次未运行测试。

## 跨平台与工程配套

根 `package.json` 使用 pnpm/Vite，`src-tauri/Cargo.toml` 声明 Rust workspace 与 Android `aarch64-linux-android` 构建目标。项目主发布面是 Android，Tauri 配置也保留桌面开发入口；`.github/workflows`、`tests/e2e-android` 和 `tests/perf` 形成 CI、设备验证与性能测量边界。README 所述移动能力为静态代码与配置确认，未实际安装 APK 验证。

## 已确认边界与未验证事项

- 统计包含 `docs`、`plan`、壁纸和图标等资源；它们显著影响文件数、文档数与字节数，但不计入源码行。
- 主线提交历史完整可达：628 次提交，时间跨度约 2026-03-03 至 2026-09-12，标签覆盖 `v1.0.2` 到 `v1.1.5`。
- 本次未运行 Vite、Cargo、Android 构建、ADB smoke 或性能脚本。

## 关键源码索引

- `package.json`、`vite.config.ts`：前端工作区与构建脚本
- `src/`：Vue/Pinia 应用与聊天同步界面
- `src-tauri/src/`、`src-tauri/plugins/`：Rust 核心、Tauri IPC 与插件
- `tests/e2e-android/`、`tests/perf/`：Android 与性能验证入口

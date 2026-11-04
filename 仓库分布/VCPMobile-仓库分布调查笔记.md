# VCPMobile 仓库分布调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`5fa2eb09e4f4dfab299cbb609a8b904b3485b5a5`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`git archive` 展开后按扩展名与目录归类），并复核 pnpm/Vite、Tauri v2 Cargo workspace、Android/iOS 平台配置与 Vitest/ADB 测试入口
>
> 调查范围：模块、语言、文档、测试、Android 与 iOS 平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 是 VCPChat 的移动端项目，采用 Tauri v2 + Vue 3 + Rust，另含 Android/Kotlin 与 iOS/Swift 平台代码、一个双平台 Tauri 插件和两个本地 crate。`src` 是 Vue/TypeScript 应用层，`src-tauri` 是 Rust 核心、Tauri 命令、数据库、插件与运行时资源，`tests` 提供 Android E2E 与性能入口，测试单元已迁入 `src/tests/unit`。当前快照有 1442 个跟踪文件、808 个源码文件 / 约 26 万行源码。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 1442 |
| 可识别源码 | 808 文件 / 260,353 行 |
| 文档（Markdown） | 311 文件 |
| 前端单元测试 | 122 文件（`src/tests/unit`） |

| 区域 | 文件 / 代码行数 |
| --- | ---: |
| `src-tauri` | 614 / 154,195 |
| `src` | 446 / 101,873 |
| `tests` | 15 / 2,606 |
| `tools` | 5 / 725 |
| `docs` | 105 / 0 |
| `plan` | 206 / 491 |

## 语言、文档与测试

Rust 127,122 行、TypeScript 60,249 行、Vue 42,071 行、Kotlin 19,975 行、Swift 6,959 行，另有少量 CJS/MJS 脚本。Rust 承担流式网络、持久化、Tauri 命令、语音与设备能力；Vue/TypeScript 承担聊天、同步和展示；Kotlin 与 Swift 分别位于 Android、iOS 插件与平台桥接区域。

文档共 311 个 Markdown 文件：`docs` 105 个（含模块、插件、Vue 文档与 iOS/跨平台构建说明），`plan` 190 个（含图片等资源），其余在根目录与测试约束说明中。`plan` 记录演进、审计与性能研究，其中 `plan/vcpmobile-ios-compatibility-research` 与语音相关方案占相当比例。

测试相关文件按入口分布为：前端单元测试 122 个（`src/tests/unit`，本次未运行）、`.test.ts` 116 个、`tests/` 目录 15 个（Android E2E 5、性能 9）、`src-tauri/tests` 8 个、`src-tauri/benches` 6 个，另有 Android 插件内 JVM 与 instrumented 用例 32 个。

## 跨平台与工程配套

根 `package.json` 使用 pnpm/Vite，`src-tauri/Cargo.toml` 声明 Rust workspace，`crates/config-export` 与 `crates/voice-mp3` 是随应用编译的本地 crate。项目主发布面仍是 Android，同时新增 iOS 工程：`src-tauri/gen/apple` 持有 XCTest 与分享扩展资源，`tauri.ios.conf.json` 与 `src-tauri/runtime-assets/voice` 中的 ONNX Runtime、Silero VAD 资源共同承担语音与平台适配。`src-tauri/plugins/vcp-mobile` 在 Android 与 iOS 两侧各有实现与权限声明。`.github/workflows`、`tests/e2e-android` 和 `tests/perf` 形成 CI、设备验证与性能测量边界；docs 中的 `CROSS_PLATFORM_DEVELOPMENT.md`、`IOS_BUILD.md` 与 `MOBILE_UI_COMPATIBILITY.md` 描述双平台构建与兼容约束。

## 已确认边界与未验证事项

- 统计包含 `docs`、`plan`、壁纸和图标等资源；它们显著影响文件数、文档数与字节数，但不计入源码行。
- 主线提交历史完整可达：905 次提交，时间跨度约 2026-03-03 至 2026-11-02，标签覆盖 `v0.9.0` 到 `v1.1.5`。
- 未运行 Vite、Cargo、Android 构建、iOS 构建、ADB smoke 或性能脚本；iOS 侧编译链与 ONNX Runtime 头文件解析只在配置层面确认。

## 关键源码索引

- `package.json`、`vite.config.ts`：前端工作区与构建脚本
- `src/`：Vue/Pinia 应用与聊天同步界面
- `src-tauri/src/`、`src-tauri/plugins/vcp-mobile/`、`src-tauri/crates/`：Rust 核心、双平台插件与本地 crate
- `src-tauri/gen/apple/`、`tauri.ios.conf.json`：iOS 工程与分享扩展资源
- `src-tauri/runtime-assets/voice/`：语音运行时资源（ONNX Runtime、Silero VAD）
- `tests/e2e-android/`、`tests/perf/`、`src/tests/unit/`：设备验证、性能与前端单元测试入口

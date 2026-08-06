# Jan 仓库分布调查笔记

> 调查对象：`../../jan`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Yarn workspace、Tauri、扩展、文档站与平台脚本
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 是 Web 前端、Tauri/Rust 原生层、可插拔扩展和文档站合仓的 workspace。`web-app/src` 占 119,779 行，Rust 原生层与插件约 3.7 万行；扩展目录把本地推理、RAG、向量库等能力拆成独立包。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 2,258 |
| 可识别源码 | 1,105 文件 / 191,672 行 |
| 文档 | 157 文件 / 16,735 行 |
| 测试 | 319 文件 / 60,401 源码行 |

主要区域为 `web-app/src`（953 文件/119,779 行）、`src-tauri/src`（52/21,539）、`src-tauri/plugins`（168/13,858）、`extensions/llamacpp-extension`（23/10,477）和文档站 `docs/src`。workspace 将 web-app 与 `extensions/*` 纳入统一依赖图（`package.json:5-10`）。

## 语言、文档与测试

TypeScript 147,256 行（76.8%）、Rust 36,437 行（19.0%）、Swift 2,221 行（1.2%）。文档以 `docs/src` 的 126 个文件为主，另有 Tauri 插件说明。测试主要随 `web-app/src`（256 文件）和各扩展/核心共置，Rust 插件测试的扩展名与目录命名也纳入本次规则。

## 跨平台组织与边界

桌面发布覆盖 Windows、macOS、Linux；构建脚本还提供 Tauri iOS/Android 入口（`package.json:15-47`）。前端共用 `web-app`，桌面/移动差异进入 Tauri feature、原生插件和资源复制步骤；README 当前主要列出桌面发行物（`README.md:66-82`），因此移动端仅能确认源码与构建入口存在，未确认发行成熟度。

## 关键源码索引

- `package.json:5-55`：workspace 与桌面/移动构建
- `src-tauri/tauri.conf.json:1-26`：Tauri 应用入口
- `web-app/`、`src-tauri/plugins/`、`extensions/`：主要模块边界

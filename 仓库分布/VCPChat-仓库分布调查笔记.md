# VCPChat 仓库分布调查笔记

> 调查对象：`../../VCPChat`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`b6ffa22f15bd0fd2499f4513a992f6bdff1de731`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Electron 打包、Rust 服务、附属工具与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 是 Electron 主应用、众多按功能命名的前端目录、多个 Rust 本地服务以及 VCP 附属服务/工具合仓的复合仓库。一级目录很多但未形成统一 workspace；模块边界主要靠目录与进程协议维持。跟踪的 `vendor` 是最大单一区域，必须与自有代码分开看。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 834 |
| 可识别源码 | 484 文件 / 308,286 行 |
| 文档 | 61 文件 / 12,242 行 |
| 测试 | 5 文件 / 1,250 源码行 |

`vendor` 为 19 个源码文件/59,339 行；自有主要区域包括 `VCPDistributedServer/Plugin`（145/27,194）、`modules` 的 IPC/renderer（合计约 55,660 行）、`VCPHumanToolBox/WorkflowEditormodules`（22/17,845）和 `rust_audio_engine/src`（36/15,775）。

## 语言、文档与测试

JavaScript 210,011 行（68.1%）、CSS 50,916 行（16.5%）、Rust 25,647 行（8.3%）、HTML 12,653 行（4.1%）。文档分散在根目录、功能目录和 Distributed Server 插件中。统一规则只识别到 `tests` 4 文件和 `SovitsTest` 1 文件，未形成覆盖各功能目录的测试树。

## 跨平台组织与边界

Electron builder 声明 macOS、Windows、Linux 目标（`package.json:109-117`），Rust assistant engine CI 也覆盖三个系统（`.github/workflows/rust_assistant_engine_build.yml:21-107`）。同时，README 和部分工具具有 Windows 专属行为，因此“有三平台构建配置”不等于所有附属能力平台等价；本次未运行确认。

## 关键源码索引

- `package.json:1-12,109-117`：Electron 打包入口与目标
- `modules/`、各 `*modules/`：主应用功能目录
- `rust_*`、`VCPDistributedServer/`、`VCPHumanToolBox/`：原生与附属进程

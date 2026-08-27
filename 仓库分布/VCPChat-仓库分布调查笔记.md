# VCPChat 仓库分布调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`89e02b778d626078be91dfbad01e5c9554c47f76`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（口径：`git ls-files` 枚举 + 按扩展名/目录分类 + `Get-Content` 计行，仅计文本文件），并复核 Electron 打包、Rust 服务、附属工具与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-08-27）：Git 跟踪文件 1585 个；可识别源码 1015 文件 / 447900 行；文档 108 文件 / 20559 行；测试 133 文件 / 21140 源码行。主线提交节奏：历史跨度 32 天共 260 次，折算 243.75 次/30天，近90天 260 次（浅克隆，历史可能不完整）。

## 结论摘要

VCPChat 是 Electron 主应用、众多按功能命名的前端目录、多个 Rust 本地服务以及 VCP 附属服务/工具合仓的复合仓库。一级目录很多但未形成统一 workspace；模块边界主要靠目录与进程协议维持。跟踪的 `vendor` 是最大单一区域，必须与自有代码分开看。

b6ffa22 → fb66a52（101 个提交）期间新增两个大型自有区域和若干脚本/测试：

- `ScriptoriumModules/`：共笔文坊文档工作台，25 个跟踪文件，JS 约 19,100 行 + CSS 4,644 行 + 一个 65,411 行的字体诊断 JSON 数据文件
- `modules/loom/webcore/`：VCP Agent WebCore，8 个 JS 文件约 5,075 行
- `modules/ipc/docxHandlers.js`（1,091 行）与 `modules/services/scriptorium{AgentControl,Import,PptxImport}Service.js`（共约 1,640 行）
- `tests/` 下 15 个新测试文件

## 统计与模块分布

> 旧表数字出自不可复现的第三方统计工具口径，本次按"git ls-files + 扩展名分类 + 文本行数"统一重算；两口径的**跟踪文件数可直接对比**（834 → 894，+60）。

| 指标 | 数量（HEAD） | 对比 b6ffa22 |
| --- | ---: | ---: |
| Git 跟踪文件 | 1585 |
| 可识别源码 | 1015 文件 / 447900 行 |
| 文档（*.md，不含 vendor/测试内） | 48 文件 / 9,919 行 | 45 / 9,033 |
| 测试 | 133 文件 / 21140 源码行 |
| vendor（文本） | 22 文件 / 42,870 行 | 22 / 42,870（未变） |

自有主要区域（文本行数，HEAD）：

- `ScriptoriumModules`：JS+CSS+HTML 约 24,900 行，另含 65,411 行 JSON 诊断数据
- `VCPDistributedServer/Plugin`：147 个跟踪文件，插件目录 26 → 30 个
- `modules`：IPC/renderer/services 与 Loom（`modules/loom/` 10 文件约 6,700 行）
- `rust_audio_engine/src` 与 `rust_chat_data_service/src`：Rust 合计 23,409 行

## 语言、文档与测试

语言分布（全部跟踪文本文件，HEAD）：JavaScript 329 文件 / 203,943 行、CSS 89 / 47,069、Rust 59 / 23,409、JSON 41 / 79,340（其中 `ScriptoriumModules/font-name-diagnostics.json` 一个文件即 65,411 行）、HTML 33 / 13,127、Python 21 / 8,156、Markdown 50 / 10,136。剔除 vendor/测试/文档后自有源码约 326,161 行：JS 49.6%、JSON 24.3%（主要同上）、CSS 12.8%、Rust 7.2%、HTML 4.0%、Python 2.2%。

测试树显著扩大：`tests/` 顶层现 7 个文件，其中六个 node:test 用例与一个导出测试：

- frontend-plugins
- loom-controller
- loom-electron-adapter
- loom-manager-runtime
- deepmemo-central-adapter
- mobile-sync-central-adapter
- test-export-inline.cjs

另有 `tests/重构中禁用脚本/` 子目录 12 个 Scriptorium 测试/冒烟脚本（约 3,620 行，目录名自述"重构中禁用"）；`SovitsTest` 5 个文件。统一规则仍只覆盖这几个目录，未形成覆盖各功能目录的测试树。

## 跨平台组织与边界

Electron builder 声明 macOS、Windows、Linux 目标（`package.json:109-117`），Rust assistant engine CI 也覆盖三个系统（`.github/workflows/rust_assistant_engine_build.yml:21-107`）。同时，README 和部分工具具有 Windows 专属行为，因此“有三平台构建配置”不等于所有附属能力平台等价；本次未运行确认。

## 关键源码索引

- `package.json:1-12,109-117`：Electron 打包入口与目标
- `modules/`、各 `*modules/`：主应用功能目录
- `rust_*`、`VCPDistributedServer/`、`VCPHumanToolBox/`：原生与附属进程

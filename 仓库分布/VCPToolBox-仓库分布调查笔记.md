# VCPToolBox 仓库分布调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`6a91ca5f75865a14471bceca4a5e2ccadd04f7e3`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Node 服务、Vue 管理台、插件、Rust workspace 与容器工作流
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-09-16）：Git 跟踪文件 3065 个；可识别源码 1322 文件 / 484333 行；文档 378 文件 / 132663 行；测试 52 文件 / 11552 源码行。主线提交节奏：历史跨度 492 天（2025-05-12 至 2026-09-16）共 2293 次，折算 139.82 次/30天，近90天 355 次（非浅克隆）。

## 结论摘要

VCPToolBox 是 Node 编排服务、Vue 管理台、插件集合、知识/技能资料与多个 Rust/Python 辅助程序合仓的多运行时插件仓库。`AdminPanel-Vue` 和 `Plugin` 是两大主体；两者内部都包含被跟踪的 vendor/dist 或大批技能文档，统计时需要区分产品源码与随仓资产。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 3065 |
| 可识别源码 | 1322 文件 / 484333 行 |
| 文档 | 378 文件 / 132663 行 |
| 测试 | 52 文件 / 11552 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `AdminPanel-Vue/src` | 270 / 99,030 |
| `AdminPanel-Vue/vendor` | 48 / 69,731 |
| `Plugin/SkillBridge` | 616 / 37,517 |
| 根服务源码 | 约 21,558 行 |
| `Plugin/PaperReader` | 83 / 21,350 |

`AdminPanel-Vue/dist` 还有 320 个跟踪文件，进一步抬高文件数。

运行时内核、原生二进制与构建脚本集中在 `Plugin`、`scripts` 与 `tests`：

- `Plugin/ChromeBridge/VCPChrome/webcore/`：运行时内核（7 文件/约 4,459 行，扩展主链逻辑从 `content_script.js` 迁入）
- `CodeSearcher` 的 Node 包装器与 Windows x64 原生二进制
- `DailyNoteSearcher` Windows 二进制
- `scripts/build_rust_plugin.js`
- `tests/chromeBridge/` 4 个测试

## 语言、文档与测试

JavaScript 251,496 行（51.9%）、Vue 68,953 行（14.2%）、Rust 51,165 行（10.6%）、CSS 29,041 行（6.0%），其后是 TypeScript 28,884、C# 19,274、Python 17,942、HTML 15,457 与 Shell/PowerShell 等运行时。文档集中在 `Plugin/SkillBridge`（206 文件/76,269 行）、`docs`（44/26,593）和 `knowledge/TDBdocs`（8/5,406）。测试分布在根 `tests` 33 文件、`AdminPanel-Vue` 18 文件和 `scripts` 1，未与插件数量成比例扩展。

## 跨平台组织与边界

产品主形态是服务端加浏览器管理台，不是原生多端客户端；Docker CI 明确构建 Linux amd64/arm64（`.github/workflows/ci.yml:19-120`）。插件和 Rust 辅助程序各自带构建边界，`OpenWebUISub`/`SillyTavernSub` 是第三方页面集成层。

多系统兼容加固集中在以下文件：

- `Plugin.js`：进程树终止跨平台化（Windows taskkill 失败回退、Unix 进程组 SIGKILL）
- `sqliteHealthManager.js`：针对 macOS 关闭 mmap 并改用 PASSIVE checkpoint
- `CodeSearcher`/`DailyNoteSearcher`：按 win32/linux/darwin × x64/arm64 三元组选择原生二进制（`scripts/build_rust_plugin.js` 统一构建）

非容器环境的平台兼容性仍因插件而异，本次未逐插件运行。

## 关键源码索引

- `package.json:1-13`：Node 服务、Admin 构建与 Rust 搜索器构建脚本（`build:code-searcher` 等）
- `AdminPanel-Vue/`：管理台源码、vendor 与 dist
- `Plugin/`、`routes/`、`modules/`、`rust-vexus-lite/`：插件和服务边界

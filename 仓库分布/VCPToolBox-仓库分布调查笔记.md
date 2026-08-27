# VCPToolBox 仓库分布调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`e2762e4dab5c70952d88f96689fba1270624e5ef`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Node 服务、Vue 管理台、插件、Rust workspace 与容器工作流
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-08-27）：Git 跟踪文件 3025 个；可识别源码 1297 文件 / 467503 行；文档 693 文件 / 162733 行；测试 40 文件 / 8696 源码行。主线提交节奏：历史跨度 471 天共 2259 次，折算 143.89 次/30天，近90天 508 次（非浅克隆）。

## 结论摘要

VCPToolBox 是 Node 编排服务、Vue 管理台、插件集合、知识/技能资料与多个 Rust/Python 辅助程序合仓的多运行时插件仓库。`AdminPanel-Vue` 和 `Plugin` 是两大主体；两者内部都包含被跟踪的 vendor/dist 或大批技能文档，统计时需要区分产品源码与随仓资产。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 3025 |
| 可识别源码 | 1297 文件 / 467503 行 |
| 文档 | 693 文件 / 162733 行 |
| 测试 | 40 文件 / 8696 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `AdminPanel-Vue/src` | 270 / 98,552 |
| `AdminPanel-Vue/vendor` | 46 / 67,369 |
| `Plugin/SkillBridge` | 616 / 37,409 |
| 根服务源码 | 约 20,813 行 |
| `Plugin/PaperReader` | 81 / 19,992 |

`AdminPanel-Vue/dist` 还有 320 个跟踪文件，进一步抬高文件数。

`c4c4d00`→`1ae9b63c` 净增 17 个跟踪文件：

- `Plugin/ChromeBridge/VCPChrome/webcore/`：运行时内核（7 文件/约 4,459 行，扩展主链逻辑从 `content_script.js` 迁入）
- `CodeSearcher` 的 Node 包装器与 Windows x64 原生二进制
- `DailyNoteSearcher` Windows 二进制
- `scripts/build_rust_plugin.js`
- `tests/chromeBridge/` 4 个新测试

## 语言、文档与测试

JavaScript 234,967 行（51.1%）、Vue 68,638 行（14.9%）、Rust 39,524 行（8.6%）、CSS 29,011 行（6.3%），另有 Python 与 Shell 等运行时（注：JS 行数按本次统计口径为 234,967，原表 235,918 含约 2% 的原统计工具口径差，其余语言统计值与原文一致）。文档集中在 SkillBridge（206 文件/76,199 行）、`docs`（52/32,752）和 `knowledge`（227 余文件）。测试只分布在 AdminPanel 18 文件、根 tests 13（`c4c4d00`→`1ae9b63c` 新增 5 个 chromeBridge 运行时/图片/编辑器样本与测试）和 scripts 1，未与插件数量成比例扩展。

## 跨平台组织与边界

产品主形态是服务端加浏览器管理台，不是原生多端客户端；Docker CI 明确构建 Linux amd64/arm64（`.github/workflows/ci.yml:19-120`）。插件和 Rust 辅助程序各自带构建边界，`OpenWebUISub`/`SillyTavernSub` 是第三方页面集成层。

`c4c4d00`→`1ae9b63c` 提交集中做多系统兼容加固：

- `Plugin.js`：进程树终止跨平台化（Windows taskkill 失败回退、Unix 进程组 SIGKILL）
- `sqliteHealthManager.js`：针对 macOS 关闭 mmap 并改用 PASSIVE checkpoint
- `CodeSearcher`/`DailyNoteSearcher`：按 win32/linux/darwin × x64/arm64 三元组选择原生二进制（`scripts/build_rust_plugin.js` 统一构建）

非容器环境的平台兼容性仍因插件而异，本次未逐插件运行。

## 关键源码索引

- `package.json:1-13`：Node 服务、Admin 构建与 Rust 搜索器构建脚本（`build:code-searcher` 等）
- `AdminPanel-Vue/`：管理台源码、vendor 与 dist
- `Plugin/`、`routes/`、`modules/`、`rust-vexus-lite/`：插件和服务边界

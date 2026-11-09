# VCPToolBox 仓库分布调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`018cd7fae1bbcf6a993bc45dcdd0914f909ca3bf`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Node 服务、Vue 管理台、插件、Rust workspace 与容器工作流
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-11-04）：Git 跟踪文件 3332 个；可识别源码 1372 文件 / 546854 行；文档 362 文件 / 145336 行；测试 142 文件 / 27741 源码行。主线提交节奏：历史跨度 541 天（2025-05-12 至 2026-11-04）共 3354 次，折算 185.99 次/30天，近90天 483 次（非浅克隆）。

## 结论摘要

VCPToolBox 是 Node 编排服务、Vue 管理台、插件集合、知识/技能资料与多个 Rust/Python 辅助程序合仓的多运行时插件仓库。`Plugin` 与 `AdminPanel-Vue` 是两大主体；两者内部都包含大批技能文档与 vendor 代码，统计时需要区分产品源码与随仓资产。Rust 代码主要来自 `rust-vexus-lite` 向量检索组件；管理台的构建产物 `dist` 不被跟踪。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 3332 |
| 可识别源码 | 1372 文件 / 546854 行 |
| 文档 | 362 文件 / 145336 行 |
| 测试 | 142 文件 / 27741 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `Plugin`（全部） | 1228 / 772,099 |
| `AdminPanel-Vue`（全部） | 353 / 200,381 |
| `AdminPanel-Vue/src` | 264 / 98,891 |
| `AdminPanel-Vue/vendor` | 22 / 69,731 |
| `Plugin/SkillBridge` | 213 / 37,531 |
| `rust-vexus-lite` | 65 / 47,259 |
| `modules` | 63 / 26,041 |
| `knowledge` | 263 / 20,952 |
| 根服务源码 | 19 文件 / 16,295 行 |

`AdminPanel-Vue/dist` 无被跟踪文件，管理台产物不计入文件规模；`vendor` 仍随仓提交，包含 22 个源码文件与约 6.97 万行。

运行时内核、原生二进制与构建脚本集中在 `Plugin`、`scripts` 与 `tests`：

- `Plugin/ChromeBridge/VCPChrome/webcore/`：扩展运行时内核
- `CodeSearcher` 的 Node 包装器与 Windows x64 原生二进制
- `DailyNoteSearcher` Windows 二进制
- `scripts/build_rust_plugin.js`、根目录的 `rust-toolchain.toml`
- `tests/chromeBridge/` 的 JEV 传输测试与其余浏览器桥测试

## 语言、文档与测试

JavaScript 286,442 行（52.4%）、Rust 85,173 行（15.6%）、Vue 69,257 行（12.7%），其后是 TypeScript 28,640、CSS 24,708、C# 19,274、Python 19,132、HTML 11,527 与 Shell/PowerShell 等。Rust 侧的增量集中在 `rust-vexus-lite`：`src`、`crates`、`benchmarks` 与 `tests` 四块合计约 4.7 万行，另有根目录 `rust-toolchain.toml` 固定工具链。

文档集中在 `Plugin/SkillBridge`（174 文件 / 73,666 行）、`docs`（68 / 38,203，其中 `docs/archive` 收存退役算法）和 `knowledge/TDBdocs`（8 / 5,406）。测试分布在根 `tests`（93 个 `*.test.js`）、`AdminPanel-Vue`（19）、`Plugin`（6）和 `scripts`（1）；本轮扩充以知识库、JEV 决策链与原生重排为主，尚未与插件数量成比例。

## 跨平台组织与边界

产品主形态是服务端加浏览器管理台，不是原生多端客户端；Docker CI 明确构建 Linux amd64/arm64（`.github/workflows/ci.yml:19-120`）。插件和 Rust 辅助程序各自带构建边界，`OpenWebUISub`/`SillyTavernSub` 是第三方页面集成层。根目录 `shared/fileKit/` 提供读取、文本、路径、校验、二进制与 diff 的小型公共库，供服务端与插件共用。

多系统兼容加固集中在以下文件：

- `Plugin.js`：进程树终止跨平台化（Windows taskkill 失败回退、Unix 进程组 SIGKILL）
- `modules/safeFilePath.js`：统一文件路径校验，供需要落盘的模块复用
- `databaseCoordinator.js`：负责 SQLite 连接与 checkpoint 时机
- `CodeSearcher`/`DailyNoteSearcher`：按 win32/linux/darwin × x64/arm64 三元组选择原生二进制（`scripts/build_rust_plugin.js` 统一构建）

非容器环境的平台兼容性仍因插件而异，本次未逐插件运行。

## 关键源码索引

- `package.json`：Node 服务、Admin 构建与 Rust 搜索器构建脚本（`build:code-searcher` 等）
- `AdminPanel-Vue/`：管理台源码与 vendor
- `Plugin/`、`routes/`、`modules/`、`rust-vexus-lite/`：插件和服务边界
- `validate-plugin-json.js`、`normalize-plugin-examples.js`：插件 JSON 的只读校验与示例规范化脚本
- `modules/knowledgeBase/`：索引、摄取、检索与日记元数据协调
- `shared/fileKit/`：公共文件读写与路径工具

# VCPChat 仓库分布调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ce9882266782ffdd7b958bbf79d8db70480047c0`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（口径：`git ls-files` 枚举并按扩展名、目录分类），并复核 Electron 打包、Rust 服务、附属工具与主要目录；本快照未统计文本行数以外的性能数据
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-11-04）：Git 跟踪文件 3578 个；按扩展名可识别的源码 2194 个（不含 `vendor/` 为 2052 个），文档类文件 154 个，`tests/` 下跟踪文件 515 个，`vendor/` 610 个。该仓库仍在高频变化。

## 结论摘要

VCPChat 是 Electron 主应用、众多按功能命名的前端目录、多个 Rust 本地服务以及 VCP 附属服务/工具合仓的复合仓库。一级目录很多但未形成统一 workspace；模块边界主要靠目录与进程协议维持。跟踪的 `vendor` 是最大单一区域，统计时与自有代码分开计算。

目录组织上有三处集中区域：前端基础设施分成独立的 `modules/ui-system/`、`modules/renderer/`、`modules/services/`、`modules/ipc/` 与 `preloads/api/` 五层；子应用目录包括 `Chartmodules/`、`DeskPetmodules/`、`Gamemodules/`、`ProjectForgemodules/` 与 `modules/deskpet/`、`modules/scriptorium/`、`modules/voice/`、`modules/emotion/`、`modules/game/`；`vendor/` 收录 pdf.js 5.7.284、pdf-lib 与 Excalidraw 0.18.1 及其打包脚本。

大型自有区域和测试面包括：

- `ScriptoriumModules/`：共笔文坊文档工作台，67 个跟踪文件，JS 约 30,711 行 + CSS 5,691 行 + 4 个 JSON 数据文件约 65,624 行
- `modules/loom/webcore/`：VCP Agent WebCore，11 个 JS 文件约 6,061 行
- `modules/ipc/docxHandlers.js`（1,311 行）与 `modules/services/scriptorium{AgentControl,Import,PptxImport}Service.js`（共约 1,583 行）
- `tests/` 下 515 个跟踪文件，覆盖聊天 surface/流式、历史写入、设置、Loom 与 Loom 管理器、移动同步、Scriptorium（含白板与文件视图）、Tavern-SRPG、VTrade、语音唤醒、side-browser、多源歌词与媒体、启动安装链

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 3578 |
| 可识别源码文件 | 2194 |
| 不含 `vendor/` 的可识别源码 | 2052 |
| 文档类文件 | 154 |
| `tests/` 跟踪文件 | 515 |
| `vendor/` 跟踪文件 | 610 |
| 分布式节点插件一级目录 | 37 |

自有主要区域（HEAD）：

- `ScriptoriumModules`：VDOCX/VPPTX 文档、演示、白板、导入导出与协作工作台。
- `VCPDistributedServer/Plugin`：37 个一级插件目录，含 LoomController、PromptSponsor、TopicSponsor、DeepMemo、TavernSRPG、ScriptoriumCollaborator、移动同步和本机工具。
- `modules`：IPC、renderer、services、UI system、Loom WebCore、deskpet、歌词和受管启动模块。
- `preloads/api`：37 个按能力域拆分的预加载 API 模块，是渲染进程访问主进程能力的统一入口。
- `rust_audio_engine`、`rust_chat_data_service`、`rust_assistant_engine`、`rust_voice_input_engine`、`rust_projectforge_indexer`：音频、聊天索引、桌面感知、语音输入与工程索引 sidecar。

## 语言、文档与测试

源码仍以 JavaScript、CSS、HTML 与 Rust 为主，另有 Python 插件和大量 JSON 资产。由于仓库包含 vendor、编译产物、字体诊断数据、媒体资源和多套子应用，按总行数直接比较会放大非业务源码；本快照只保留文件数口径，未重新给出语言行数占比。

测试树现有 515 个跟踪文件，主要覆盖：

- 聊天 surface、事件契约、流式 session、终态清理、内容管线和 DOM renderer；
- 历史 mutation queue、持久化、selection race 与 sender task registry；
- Canvas 编辑审批、LoomSkill/持久目标、PromptSponsor/TopicSponsor 服务、Loom 管理器运行时；
- 设置 schema、自动保存协调、revision 冲突和关闭压力；
- 多源歌词候选、Music Stage、移动同步协议与降级；
- Scriptorium 的白板与 Agent 读写文件、文件原位打开、Tavern-SRPG 沙箱、VTrade 编排器；
- 受管启动、安装器、side-browser 与平台边界。

这些多为 Node 静态或契约测试，不能替代 Electron、Tauri、音频设备、WebContentsView 和外部服务的端到端验证。

## 跨平台组织与边界

Electron builder 声明 macOS、Windows、Linux 目标（`package.json:182-262`），构建前的 sidecar 编译现在同时包含聊天数据服务、语音输入引擎与工程索引器（`package.json:28`）。CI 侧有六个工作流，其中 Rust assistant engine 构建覆盖三平台（`.github/workflows/rust_assistant_engine_build.yml:21-107`），另有移动同步、side pane 端到端与安装器工作流（`.github/workflows/mobile_sync.yml`、`side_pane_e2e.yml`、`side_pane_windows.yml`、`vcpchat-installer.yml`）。同时，README 和部分工具具有 Windows 专属行为，因此三平台构建配置覆盖构建与产物目标；附属能力的平台支持范围各有差异，本次未运行确认。

## 关键源码索引

- `package.json:28,92-93,182-262`：构建脚本、打包入口与三平台目标
- `modules/`、各 `*modules/`：主应用功能目录
- `preloads/api/`：按能力域拆分的预加载 API 模块
- `modules/services/`：渲染进程侧服务层（聊天数据、Git、PDF、嵌入式应用会话等）
- `vendor/pdfjs`、`vendor/pdf-lib`、`vendor/excalidraw`：新增的文档渲染与白板依赖
- `rust_*`、`VCPDistributedServer/`、`VCPHumanToolBox/`：原生与附属进程

# VCPChat 仓库分布调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`429a96829da0149ff59b6758748795a2934bdc9d`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（口径：`git ls-files` 枚举并按扩展名、目录分类），并复核 Electron 打包、Rust 服务、附属工具与主要目录；本快照未重新统计文本行数
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-09-16）：Git 跟踪文件 1961 个；按扩展名可识别的源码 1218 个，文档类文件 109 个，`tests/` 下跟踪文件 174 个。该仓库仍在高频变化；本文不沿用旧快照的代码行数和提交频率统计。

## 结论摘要

VCPChat 是 Electron 主应用、众多按功能命名的前端目录、多个 Rust 本地服务以及 VCP 附属服务/工具合仓的复合仓库。一级目录很多但未形成统一 workspace；模块边界主要靠目录与进程协议维持。跟踪的 `vendor` 是最大单一区域，统计时与自有代码分开计算。

大型自有区域和测试面包括：

- `ScriptoriumModules/`：共笔文坊文档工作台，25 个跟踪文件，JS 约 19,100 行 + CSS 4,644 行 + 一个 65,411 行的字体诊断 JSON 数据文件
- `modules/loom/webcore/`：VCP Agent WebCore，8 个 JS 文件约 5,075 行
- `modules/ipc/docxHandlers.js`（1,091 行）与 `modules/services/scriptorium{AgentControl,Import,PptxImport}Service.js`（共约 1,640 行）
- `tests/` 下 174 个跟踪文件，覆盖聊天 surface/流式、历史写入、设置、Loom、移动同步、Scriptorium、媒体和启动安装链

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 1961 |
| 可识别源码文件 | 1218 |
| 文档类文件 | 109 |
| `tests/` 跟踪文件 | 174 |
| 分布式节点插件一级目录 | 32 |

自有主要区域（HEAD）：

- `ScriptoriumModules`：VDOCX/VPPTX 文档、演示、导入导出与协作工作台。
- `VCPDistributedServer/Plugin`：32 个一级插件目录，含 LoomController、PromptSponsor、TopicSponsor、DeepMemo、移动同步和本机工具。
- `modules`：IPC、renderer、services、UI system、Loom WebCore、歌词和受管启动模块。
- `rust_audio_engine`、`rust_chat_data_service`、`rust_assistant_engine`：音频、聊天索引和桌面感知 sidecar。

## 语言、文档与测试

源码仍以 JavaScript、CSS、HTML 与 Rust 为主，另有 Python 插件和大量 JSON 资产。由于仓库包含 vendor、编译产物、字体诊断数据、媒体资源和多套子应用，按总行数直接比较会放大非业务源码；本快照只保留文件数口径，未重新给出语言行数占比。

测试树现有 174 个跟踪文件，主要覆盖：

- 聊天 surface、事件契约、流式 session、终态清理、内容管线和 DOM renderer；
- 历史 mutation queue、持久化、selection race 与 sender task registry；
- Canvas 编辑审批、LoomSkill/持久目标、PromptSponsor/TopicSponsor 服务；
- 设置 schema、自动保存协调、revision 冲突和关闭压力；
- 多源歌词候选、Music Stage、移动同步协议与降级；
- Scriptorium、受管启动、安装器和平台边界。

这些多为 Node 静态或契约测试，不能替代 Electron、Tauri、音频设备、WebContentsView 和外部服务的端到端验证。

## 跨平台组织与边界

Electron builder 声明 macOS、Windows、Linux 目标（`package.json:109-117`），Rust assistant engine CI 也覆盖三个系统（`.github/workflows/rust_assistant_engine_build.yml:21-107`）。同时，README 和部分工具具有 Windows 专属行为，因此“有三平台构建配置”不等于所有附属能力平台等价；本次未运行确认。

## 关键源码索引

- `package.json:1-12,109-117`：Electron 打包入口与目标
- `modules/`、各 `*modules/`：主应用功能目录
- `rust_*`、`VCPDistributedServer/`、`VCPHumanToolBox/`：原生与附属进程

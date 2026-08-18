# Jan 独特功能调查笔记

> 调查对象：`E:\works\git\jan`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：只读通读根 README、docs 产品文档、扩展目录、src-tauri Rust 后端与 web-app 前端路由；由专项核验覆盖 7 个扩展、Tauri 插件与 CLI，并对关键入口（`proxy.rs` 编排端点、`llamacpp-extension`、`jan-cli.rs`）抽查复核；未运行应用，未修改被调查仓库
>
> 调查范围：待查清单中 Jan 行的复核——本地推理器管理、本地 API 服务、Artifact、本地/云路由及潜在新候选的入口、状态、执行与持久化主链；与现有十类笔记去重
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

以下达到 `主链确认`（静态证据）的新候选：

1. **设备级本地推理器管理闭环**（主贡献候选）：llama.cpp 后端二进制下载/更新/回滚、按 OS/CPU 指令集/GPU 选型、Router 单进程多模型、GPU 未启用检测与 fit 预测——管理的是"引擎本身"，比通用"生成式输出与运行时"（模型服务抽象层）深一层。
2. **`/v1/orchestrations` 服务端 MCP 编排端点**（辅助贡献候选）：把 MCP 工具执行作为 HTTP 服务暴露，可配置 router 模型预选工具——不是又一个 OpenAI 兼容服务，而是"本地 Agent 服务端"。
3. **Jan CLI + 外部 Agent 预接**（辅助贡献候选）：`jan serve` / `jan launch claude|openclaw` 打通桌面数据目录、终端与外部 Agent CLI 三面。
4. **MCP 智能工具路由**（辅助贡献候选）：LLM 路由器模型 + 关键词分类降级 + 遥测回调，属 Agent 工具类目的增强形态。

明确不存在的实现：README 语境下不存在"本地↔云模型级 failover"（仅 API key 链 401 重试与 MCP 工具路由降级）；BrowserMCP 是伴生 Chrome 扩展，本仓库只有配置入口。

## 介绍声明与候选盘点

README 与 docs 反复强调的能力集中在：本地优先（模型/后端/API 全本地）、多引擎（llama.cpp + MLX）、Hub 模型市场、MCP、Artifact、Assistant/Agent 与 Project。候选归属的权威表面：`extensions/`（7 个 JS 扩展）、`src-tauri/plugins/`（6 个 Tauri 插件）、`src-tauri/src/core/`（Rust 核心）、`web-app/src/routes/`（前端路由）。

| 候选 | 证据状态 | 结论 |
|---|---|---|
| 推理器生命周期管理（下载/更新/回滚/选型/Router） | `主链确认` | llamacpp-extension 的 `configureBackends`/`updateBackend`/`startRouter` + router.preset.ini + Rust 插件进程管理，见能力一 |
| 硬件适配闭环（探测→推荐→fit 预测→运行验证） | `主链确认` | tauri-plugin-hardware + `gpuBackendMatch.ts`/`modelCompatibility.ts` + `readiness.ts` 探针，并入能力一 |
| `/v1/orchestrations` 服务端编排 | `主链确认` | `proxy.rs:1770`，见能力二 |
| Jan CLI（serve/launch/threads/models） | `主链确认` | `src-tauri/src/bin/jan-cli.rs`，见能力三 |
| MCP 智能工具路由 | `主链确认` | `web-app/src/lib/mcp-orchestrator/`，见能力四 |
| 本地 OpenAI/Anthropic 兼容 API 服务器 | `归并已有类目` | 本地服务暴露属"生成式输出与运行时"（LM Studio/Ollama 同形态）；路由按 model_id 静态解析 |
| 双本地运行时（llama.cpp + MLX） | `归并已有类目` | 归入能力一的运行时管理面与运行时类目 |
| Hub 模型市场与量化分档 | `归并已有类目` | 模型下载属运行时类目；自研模型线为外部发布物 |
| HTML/SVG Artifact 预览 | `归并已有类目` | 消息渲染器类目（围栏预览，无独立对象） |
| RAG 附件检索、web_search/web_fetch | `归并已有类目` | Agent 工具类目 |
| Project 工作流（主题多会话+共享文件+指定助手） | `入口确认` | `web-app/src/routes/project/` 与 `services/projects/`；证据以 UI 层为主，与"协同工作区"聚类重叠，本轮不单独提案 |

## 已确认的独特能力

### 能力一：设备级本地推理器管理闭环 — `主链确认`

**用户目标**：管理"跑模型的引擎本身"而非只管理模型文件——按机器硬件选 CUDA/Vulkan/CPU 后端、下载与升级 llama-server 二进制、失败回滚、单进程 Router 承载多个模型、并验证 GPU 真的被用上（"模型装得下吗、会不会慢"）。

**入口与触发者**：设置页、首次运行引导（`configureBackends`）、后端更新按钮（`updateBackend`）与硬件/依赖建议对话框（`DependencyAdvice.tsx`）触发；主要执行者是 llamacpp-extension（`extensions/llamacpp-extension/src/index.ts`）。

**事实对象**：
- `<data>/llamacpp/backends/<version>/<backend>/` 后端目录：保留两个版本供回滚；
- `update_history.json`：更新记录（`BackendUpdateRecord`，`index.ts:118`）；
- `router.preset.ini`：由 `preset.ts` 生成，全局节加逐模型节，含 MTP、fit 与采样服务端默认值。

**完整主链**（总入口 `extensions/llamacpp-extension/src/index.ts:1413`，其余入口行号见文末索引）：配置函数按远端清单（`backend.ts`，按 OS/CPU 指令集/GPU 过滤）下载后端二进制并做 sha512 校验，生成 preset 后由 Router 启动器经 Rust 插件拉起单进程 Router 承载多模型。运行后验证 GPU 是否真的被用上：`readiness.ts` 的 GPU 卸载校验对比引擎设备列表与硬件 GPU 数，向量探针真实执行嵌入；`gpuBackendMatch.ts` 判定"已装后端 vs 探测 GPU"的不匹配。`updateBackend` 升级后做健康检查，失败时按 `update_history.json` 与保留版本目录回滚。

**持续性**：后端目录与 preset 落盘，重启后按配置恢复；崩溃恢复由 `adoptRouter` 接管孤儿 Router 进程；升级带并发去重与排队（测试见 `extensions/llamacpp-extension/src/test/index.test.ts` 的 updateBackend 系列）。

**外部依赖与执行域**：二进制下载依赖远端后端清单（GitHub 发布），校验与运行在本机；硬件探测模块负责 NVIDIA/AMD/Vulkan 厂商识别与显存占用轮询（`src-tauri/plugins/tauri-plugin-hardware/src/` 的 gpu.rs、cpu.rs 与 vendor/）。

**独特性判断**：通用"生成式输出与运行时"类目覆盖模型服务抽象层；这里是推理器二进制的设备级生命周期（版本、硬件驱动后端、依赖库 CUDA/Vulkan/cuDNN 检查、进程收养）与"探测→推荐→预测→验证"闭环，调查样本中未见同类实现。

**证据强度**：扩展与 Rust 插件源码、单元测试为静态事实；真实下载、GPU 探测与 Router 运行未验证。

### 能力二：`/v1/orchestrations` 服务端 MCP 编排 — `主链确认`

**用户目标**：让外部 HTTP 客户端触发 Jan 服务端执行一段 MCP 工具编排（加载 assistant 系统提示 → 模型出 tool_calls → 服务端执行 MCP 工具 → 循环至完成），并可用 router 模型预选工具。

**入口与触发者**：`POST /v1/orchestrations`（`src-tauri/src/core/server/proxy.rs:1770`），由外部客户端经本地 API 服务器触发；`stream=true` 不支持（`proxy.rs:1827`）。

**事实对象**：请求为一次性编排会话，服务端维护 tool_calls 循环状态。

**完整主链**：请求到达 → 加载对应 assistant 系统提示 → 模型生成 tool_calls → 服务端在自身进程内执行 MCP 工具 → 结果回注循环直至完成 → 返回汇总响应。与普通 `/v1/chat/completions`、`/v1/messages` 并列于 `proxy.rs` 的 `resolve_upstream_for_model` 三路路由（云端 provider → MLX 会话 → llama.cpp router）。

**人机与多 Agent 关系**：外部客户端（其他 Agent 或脚本）以 HTTP 身份参与；工具执行发生在 Jan 服务端，权限边界沿用 MCP 工具的既有执行域。

**独特性判断**："本地 OpenAI 兼容服务"可归并已有类目，但"把 MCP 工具执行编排暴露为 HTTP 端点"接近本地 Agent 服务器形态，样本中罕见。

**证据强度**：`proxy.rs` 端点为静态事实；端到端编排行为未运行验证。

### 能力三：Jan CLI 与外部 Agent 预接 — `主链确认`

**用户目标**：终端用户不打开桌面窗口，即可启动本地模型服务，并把 Claude Code / OpenClaw 等外部 Agent CLI 一键接上本地模型。

**入口与触发者**：`src-tauri/src/bin/jan-cli.rs` 的 `jan serve`、`jan launch <agent>`、`jan threads`、`jan models`；由用户在终端触发。

**完整主链**：
- `jan serve`：按 router 预设启动本地 API 服务；
- `jan launch claude`：默认开启按显存自动配上下文的 `--fit`（`jan-cli.rs:1149`），并以 `ANTHROPIC_AUTH_TOKEN` 环境变量指向本地端点；
- `jan launch openclaw`：向 `~/.openclaw/openclaw.json` 写入/合并 jan provider 条目并设默认模型（`configure_openclaw`，`jan-cli.rs:1254`），随后拉起 `openclaw tui`；
- `jan threads`：不经 AppHandle 直读数据目录线程（`src-tauri/src/core/cli/mod.rs`）。

**持续性**：桌面数据目录是唯一事实源，CLI 与桌面共享；`jan launch` 写的配置持久化于外部 Agent 的配置目录。

**独特性判断**："桌面应用内置 CLI + 自动对接外部 Agent 并预接本地模型"是完整多表面工作流，通用 Chat UI/会话类目不覆盖，与"多表面连续性"聚类（Hermes、OpenCode、DeepChat）对照是"向外提供本地模型"的方向。

**证据强度**：CLI 二进制构建链（Cargo `[[bin]] jan-cli`、`make build-cli`）与各子命令源码为静态事实；真实启动外部 Agent 未验证。

### 能力四：MCP 智能工具路由 — `主链确认`

**用户目标**：当 MCP 服务器很多时，用独立小模型对用户意图做工具级路由选择，LLM 不可用时降级为关键词分类，并把每次路由决策与降级原因记入遥测，供用户观察"为什么用了/没用哪个工具"。

**入口与触发者**：前端路由选择面位于 `web-app/src/lib/mcp-orchestrator/`，含意图分类、LLM 路由与模型过滤三个模块，另有路由器模型选择组件与遥测文档（文件清单见文末索引）。

**完整主链**：意图分类（阈值 5、最多 5 个服务器、打分）→ LLM 路由器（约 3.5s 超时）→ 七类 `fallbackReason` 降级路径 → 路由结果进入工具调用面；遥测回调记录决策。

**独特性判断**：MCP 接入本身归 Agent 工具类目；"独立小模型做工具级路由 + 关键词降级 + 可观测遥测"是 Agent 工具类目的增强形态，可并入该类目或在卡内作子项，不单独计主贡献。

**证据强度**：路由与分类源码、测试为静态事实；真实 LLM 路由调用未验证。

## 已归并到现有类目的能力

| 能力 | 归并去向 |
|---|---|
| 本地 OpenAI/Anthropic 兼容 API 服务与按 model_id 的统一路由（`resolve_upstream_for_model`） | LLM 渠道与生成式输出与运行时类目；无模型级 failover，只有 API key 链重试与 MCP 路由降级 |
| 双本地运行时（llamacpp + MLX，`mlx-server` Swift 推理服务器） | 能力一的运行时管理面 + 生成式输出与运行时类目 |
| Hub 模型市场、量化分档、模型下载 | 运行时类目（模型下载）；自研模型线属外部发布物 |
| HTML/SVG Artifact 围栏预览（`HtmlArtifact.tsx`、`splitHtmlArtifacts`） | 消息渲染器类目；无独立对象、文件管理与生命周期 |
| RAG 附件检索（rag-extension `retrieve`/`list_attachments`/`get_chunks` + 引用卡） | Agent 工具/附件处理类目 |
| 原生 web_search / web_fetch（Exa/Tavily/SearXNG） | Agent 工具类目 |
| Assistant/Agent、线程自动标题、首次运行向导、后端设置与 OS keyring | Agent 角色、会话管理与设置类目；keyring 为工程/安全机制单独标注 |

## 声明不符、外部依赖与暂缓项

- **本地↔云模型级 failover**：README 语境下的"容灾/路由"易被读成智能调度；按当前快照只有云端 API key 链 401 重试（`provider-api-keys.ts`）与 MCP 工具路由降级，无分片、无模型级本地↔云自动切换。统一路由 = 按 `model_id` 静态解析，结论维持归并。
- **BrowserMCP**：伴生 Chrome 扩展（`JanBrowserExtensionDialog.tsx` 仅为配置入口），本仓库主链未接入，标外部依赖。
- **Project 工作流**：`入口确认`（`web-app/src/routes/project/$projectId.tsx`、`services/projects/default.ts`、rag-extension `scope: "project"` 检索），证据以 UI 层为主；与"协同工作区"聚类（Open WebUI Notes、LobeHub Pages）重叠，本轮不单独提案，留待聚类比较。
- **首次运行向导**（HEAD 提交 `fad3f12` 主题）：普通引导流程，归并设置类目，不进入统计。

## 对特色贡献统计的影响

- **主贡献候选**：能力一"设备级本地推理器管理闭环"（`主链确认`，静态证据）。统计中 F41"本地模型运行时与云 Provider 统一路由"已有 Jan 主贡献，其计入理由应扩充为包含引擎生命周期管理；若按"同一工作流合并"原则，将能力一与 F41 视为同一能力族（本地模型运行整体），则 Jan 主贡献理由增强而不新增条目。
- **辅助贡献候选**：能力二（服务端 MCP 编排端点）、能力三（CLI + 外部 Agent 预接，属"多表面连续性"聚类方向）、能力四（MCP 智能工具路由，可并入 Agent 工具类目 F31/F33 相关条目）。
- **不重复计数**：Artifact（F22 严格隔离预览仍按消息渲染器归并）、Hub 下载、RAG、web_search。
- 统计表重排待[待查清单](待查清单.md)全局待办第 6 条（按"产品特性贡献"与"机制贡献"拆分重做）一并处理，本笔记仅登记建议。

## 未验证事项

- 全部能力均未运行验证：真实后端下载/更新/回滚、GPU 探测与 fit 预测、Router 多模型并发、`/v1/orchestrations` 端到端编排、`jan launch` 拉起外部 Agent、LLM 路由器真实调用与遥测落库。
- `readiness.ts` 探针（`verifyGpuOffload`/`verifyEmbeddingModel`）的判定阈值与误报边界未核对。
- MCP 智能路由的"最多 5 服务器"与阈值 5 的具体打分语义未逐行展开。
- Project 工作流主链未走通（本轮未调查服务端权限与持久化细节）。

## 关键源码索引

- `extensions/llamacpp-extension/src/index.ts`（118 BackendUpdateRecord、996 startRouter、1413 configureBackends、1835 updateBackend、2084 restartRouterAndProbe）、`backend.ts`（远端后端清单过滤）、`preset.ts`（router.preset.ini）、`readiness.ts`（verifyGpuOffload/verifyEmbeddingModel）、`src/test/index.test.ts`（updateBackend 系列）
- `src-tauri/plugins/tauri-plugin-llamacpp/src/router.rs`、`backend.rs`、`process.rs`、`deps_analyzer.rs`；`src-tauri/plugins/tauri-plugin-hardware/src/gpu.rs`、`cpu.rs`、`vendor/`；`src-tauri/plugins/tauri-plugin-websearch/src/commands.rs`、`provider.rs`
- `src-tauri/src/core/server/proxy.rs`（1770 /v1/orchestrations、1827 stream 限制、resolve_upstream_for_model）、`src-tauri/src/core/server/provider_secrets.rs`、`src-tauri/src/bin/jan-cli.rs`（41-43 用法、1149 --fit 默认、1163-1173 环境变量、1254 configure_openclaw）、`src-tauri/src/core/cli/mod.rs`（jan threads 直读线程）
- `web-app/src/lib/mcp-orchestrator/`（intent-classifier.ts、mcp-router-llm.ts）、`web-app/src/lib/mcp-router-model-filter.ts`、`containers/McpRouterModelPicker.tsx`、docs `mcp-routing-telemetry.mdx`
- `web-app/src/lib/gpuBackendMatch.ts`、`modelCompatibility.ts`（estimateModelFit）、`backendDependencies.ts`、`containers/dialogs/DependencyAdvice.tsx`、`routes/system-monitor.tsx`
- `web-app/src/routes/hub/index.tsx`、`containers/ModelDownloadAction.tsx`、`components/HtmlArtifact.tsx`、`lib/utils.ts`（splitHtmlArtifacts）、`containers/RenderMarkdown.tsx`（renderHtmlArtifacts 开关）
- `web-app/src/routes/project/$projectId.tsx`、`services/projects/default.ts`、`extensions/rag-extension/src/tools.ts`（scope: "project"）

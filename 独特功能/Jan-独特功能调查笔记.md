# Jan 独特功能调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`38491c73d12398edda45ebec366f940e83509490`（分支：`main`）
>
> 调查方式：只读通读根 README、docs 产品文档、扩展目录、src-tauri Rust 后端与 web-app 前端路由；由专项核验覆盖 7 个扩展、Tauri 插件与 CLI，并对关键入口（`proxy.rs` 编排端点、`llamacpp-extension`、`jan-cli` crate）抽查复核；未运行应用，未修改被调查仓库
>
> 调查范围：待查清单中 Jan 行的复核——本地推理器管理、本地 API 服务、Artifact、本地/云路由及潜在新候选的入口、状态、执行与持久化主链；与现有十类笔记去重
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

以下达到 `主链确认`（静态证据）的新候选：

1. **随附推理引擎的 worker 托管与逐线程 KV 缓存**（主贡献候选，范围较旧快照收窄）：引擎以编译期版本捆绑进随附 worker，运行机不再下载、选择或回滚后端；worker 按需承载多模型、容量满时只淘汰空闲的最近最少使用 chat 模型，并按 thread_id 保存/恢复提示缓存，运行后校验 GPU 卸载与实际嵌入。管理对象仍是推理引擎本身，通用"生成式输出与运行时"类目只覆盖模型服务抽象层。
2. **`/v1/orchestrations` 服务端 MCP 编排端点**（辅助贡献候选）：把 MCP 工具执行作为 HTTP 服务暴露，可配置 router 模型预选工具；与本地 OpenAI 兼容服务相比，它多出服务端的工具编排。
3. **Jan Agent CLI/TUI**（辅助贡献候选）：裸 `jan` 打开终端 Agent 控制台，`jan cli agent run` 非交互运行项目 Agent，Provider 由 `~/.jan/config.toml`、项目 `agent.toml` 或桌面配置解析。
4. **MCP 智能工具路由**（辅助贡献候选）：LLM 路由器模型 + 关键词分类降级 + 遥测回调，属 Agent 工具类目的增强形态。

明确不存在的实现：README 语境下不存在"本地↔云模型级 failover"（仅 API key 链 401 重试与 MCP 工具路由降级）；BrowserMCP 是伴生 Chrome 扩展，本仓库只有配置入口。

## 介绍声明与候选盘点

README 与 docs 反复强调的能力集中在：本地优先（模型/后端/API 全本地）、多引擎（llama.cpp + MLX）、Hub 模型市场、MCP、Artifact、Assistant/Agent 与 Project。候选归属的权威表面：`extensions/`（7 个 JS 扩展）、`src-tauri/plugins/`（7 个 Tauri 插件）、`src-tauri/src/core/`（Rust 核心，含 Agent 核心与 CLI/TUI）、`src-tauri/jan-cli/`（独立 CLI crate）、`web-app/src/routes/`（前端路由）。

| 候选 | 证据状态 | 结论 |
|---|---|---|
| 随附引擎的 worker 托管与逐线程 KV 缓存（多模型按需加载、LRU 淘汰） | `主链确认` | llamacpp-extension 的 `ensureProvisioned`/`startEngine` + preset + Rust 插件 worker，见能力一 |
| 硬件适配闭环（探测→推荐→运行验证） | `主链确认` | tauri-plugin-hardware + `gpuBackendMatch.ts`/`modelCompatibility.ts` + `readiness.ts` 探针，并入能力一 |
| `/v1/orchestrations` 服务端编排 | `主链确认` | `proxy.rs:1119`，见能力二 |
| Jan Agent CLI/TUI（TUI、`cli agent run`、`cli threads/models/mcp`） | `主链确认` | `src-tauri/jan-cli/src/main.rs`，见能力三 |
| MCP 智能工具路由 | `主链确认` | `web-app/src/lib/mcp-orchestrator/`，见能力四 |
| 本地 OpenAI/Anthropic 兼容 API 服务器 | `归并已有类目` | 本地服务暴露属"生成式输出与运行时"（LM Studio/Ollama 同形态）；路由按 model_id 静态解析 |
| 双本地运行时（llama.cpp + MLX） | `归并已有类目` | 归入能力一的运行时管理面与运行时类目 |
| Hub 模型市场与量化分档 | `归并已有类目` | 模型下载属运行时类目；自研模型线为外部发布物 |
| HTML/SVG Artifact 预览 | `归并已有类目` | 消息渲染器类目（围栏预览，无独立对象） |
| RAG 附件检索、web_search/web_fetch | `归并已有类目` | Agent 工具类目 |
| Project 工作流（主题多会话+共享文件+指定助手） | `入口确认` | `web-app/src/routes/project/` 与 `services/projects/`；证据以 UI 层为主，与"协同工作区"聚类重叠，本轮不单独提案 |

## 已确认的独特能力

### 能力一：随附推理引擎的 worker 托管与逐线程 KV 缓存 — `主链确认`

**用户目标**：引擎随应用一起发布，用户无需在运行机管理后端二进制；在内存容量内按需承载多个模型，并让同一会话续写复用已算好的提示缓存；运行后能确认 GPU 真的被用上。

**入口与触发者**：扩展 `onLoad` 进入的 `ensureProvisioned()` 触发 `startEngine()`（`extensions/llamacpp-extension/src/index.ts:456-557,853-900`）；首次运行设置页、启动流程与首次模型加载共用这条单飞（single-flight）链；插件侧命令为 `start_engine`。

**事实对象**：
- 捆绑进 worker 的引擎：版本是编译期常量，`getEngineVersion` 不依赖任何进程；
- `router.preset.ini`：由 `preset.ts` 生成，含全局节与逐模型节、MTP 与采样服务端默认值；
- 每模型 `<data>/llamacpp/models/<modelId>/model.yml`；
- 逐线程 KV 缓存目录：以 `slotCacheMib` 为预算，0 表示关闭。

**完整主链**（其余入口行号见文末索引）：扩展生成 preset → 插件启动受监督的引擎 worker（端口由 OS 分配后回传，并返回 pid、api_key 与已注册模型数）→ worker 的 registry 按需加载模型，容量满时只淘汰空闲的最近最少使用 chat 模型（`userModelsMax` 与 `loadedChatOrder`，`index.ts:2297-2318`）→ 请求以 thread_id 识别 KV 状态，换入前保存旧状态、命中时恢复，身份校验失败则删除而不恢复（`engine/slots.rs`）→ 运行后 `readiness.ts` 校验 GPU 卸载与嵌入向量、`gpuBackendMatch.ts` 判定引擎与探测 GPU 的家族匹配（`engine/worker.rs`、`engine/registry.rs`、`engine/http.rs`）。

**持续性**：preset、`model.yml` 与线程 KV 目录落盘；worker 在启动它的进程退出（含被 SIGKILL）时因 stdin EOF 自行退出，无需收养或回收。跨会话缓存命中率与并发淘汰时序未运行验证。

**外部依赖与执行域**：引擎与 CUDA/Vulkan 运行库在构建期打包（`src-tauri/build-utils/stage-engine.sh`、`engine-prebuilt.sh` 等），运行期不下载后端；只有回退嵌入模型仍按需获取。硬件探测模块负责 NVIDIA/AMD/Vulkan 厂商识别与显存占用轮询（`src-tauri/plugins/tauri-plugin-hardware/src/` 的 gpu.rs、cpu.rs 与 vendor/）。

**独特性判断**：不再包含旧快照的“后端目录下载/更新/回滚与按硬件选型”（见文末声明不符）；保留的是随附引擎的 worker 托管、容量受限的多模型驻留与逐线程提示缓存，以及“探测→运行校验”的 GPU 实测，调查样本中仍未见同类组合。

**证据强度**：扩展、插件源码与单元测试为静态事实；worker 并发、缓存命中与 GPU 校验阈值未运行验证。

### 能力二：`/v1/orchestrations` 服务端 MCP 编排 — `主链确认`

**用户目标**：让外部 HTTP 客户端触发 Jan 服务端执行一段 MCP 工具编排（加载 assistant 系统提示 → 模型出 tool_calls → 服务端执行 MCP 工具 → 循环至完成），并可用 router 模型预选工具。

**入口与触发者**：`POST /v1/orchestrations`（`src-tauri/src/core/server/proxy.rs:1119`），由外部客户端经本地 API 服务器触发；`stream=true` 不支持（`proxy.rs:1182`）。

**事实对象**：请求为一次性编排会话，服务端维护 tool_calls 循环状态。

**完整主链**：请求到达 → 加载对应 assistant 系统提示 → 模型生成 tool_calls → 服务端在自身进程内执行 MCP 工具 → 结果回注循环直至完成 → 返回汇总响应。与普通 `/v1/chat/completions`、`/v1/messages` 并列于 `resolve_upstream_for_model`（`src-tauri/src/core/agent/upstream.rs:403`）的三路路由（云端 provider → MLX 会话 → llama.cpp router）。

**人机与多 Agent 关系**：外部客户端（其他 Agent 或脚本）以 HTTP 身份参与；工具执行发生在 Jan 服务端，权限边界沿用 MCP 工具的既有执行域。

**独特性判断**："本地 OpenAI 兼容服务"可归并已有类目，但"把 MCP 工具执行编排暴露为 HTTP 端点"接近本地 Agent 服务器形态，样本中未找到同类端点。

**证据强度**：`proxy.rs` 端点为静态事实；端到端编排行为未运行验证。

### 能力三：Jan Agent CLI/TUI — `主链确认`

**用户目标**：终端用户不打开桌面窗口，即可在项目目录中运行一个能读写文件、执行命令的 Agent，并直接复用桌面或项目里已配置的远程 Provider。

**入口与触发者**：独立 crate `src-tauri/jan-cli/src/main.rs`，由用户在终端触发；裸 `jan` 打开交互式 Agent 控制台（TUI），无子命令时才走 TUI，带子命令则走非交互面（`main.rs:1-5,152-194`）。

**完整主链与非交互面**：
- Provider 解析优先级：CLI 参数与 `JAN_API_KEY`/`<PROVIDER>_API_KEY` 环境变量 > 项目 `.jan/agent/agent.toml` 的 `[provider]` > 桌面 `settings.json`（只继承、不回写）> 全局 `~/.jan/config.toml`（`src-tauri/src/core/cli/providers.rs:1-16`）；
- `jan cli agent run/step/status`：非交互运行项目 Agent；
- `jan cli models list`、`jan cli threads list/get/delete/messages`、`jan cli mcp list/get/add/remove/enable/disable`：列出已配置 Provider 的模型、读取与删除线程、管理共享的 `mcp_config.json`（`main.rs:236-263,385-479`）；
- `jan config set/unset/list/path` 管理 `~/.jan/config.toml` 中的 Provider 凭据，`jan login`/`auth` 处理 Tokamak 登录，`jan plugin` 管理项目插件与技能，`jan update` 自更新（`main.rs:159-193`）；
- Agent 工具循环复用桌面的 Rust Agent 核心；`--safe` 在写入、命令与 MCP 调用前审批，`--sandbox` 开启 OS 沙箱（默认按配置关闭），`--plan` 只读计划模式，`-c`/`--resume` 恢复项目会话（`main.rs:44-98,115-148`）。

**持续性**：全局/项目配置与项目维度线程均落盘，`-c`/`--resume` 可跨进程恢复最近或指定 ID 的会话；可写出 Desktop 兼容 thread（`src-tauri/src/core/cli/mod.rs`）。

**外部依赖与执行域**：仅使用远程 Provider，不含本地推理或 GUI 依赖（`main.rs:1-5`）。

**独特性判断**：把桌面级 Agent 核心抽成独立 CLI/TUI，并与桌面共用 Provider 配置（可选共享线程格式），属“多表面连续性”聚类中“向外提供终端 Agent 执行面”的方向；通用 Chat UI/会话类目不覆盖。

**证据强度**：各子命令与 Provider 解析源码为静态事实；真实 TUI 交互、沙箱与跨进程会话兼容性未运行验证。

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
- **设备级推理器下载/选型/回滚**：旧快照的 `configureBackends`、`updateBackend`、`restartRouterAndProbe` 与后端目录、`update_history.json` 已不在当前源码中；引擎改为编译期捆绑进随附 worker，首次运行不再下载数百 MB 后端，相关设置键（`llamacpp_version`、`llamacpp_backend`、`check_for_updates`、`auto_update_engine`、`verify_backend_deps`）已从扩展设置中移除。旧"按硬件选 CUDA/Vulkan/CPU 后端并回滚"的表述不再成立。[代码确认]
- **旧 `jan serve` / `jan launch claude|openclaw`**：旧快照的一键启动本地模型服务、并自动预接外部 Agent CLI 的命令不在当前 CLI 命令树中；当前 CLI 只运行自身的 Agent（见能力三与外部执行体笔记）。
- **BrowserMCP**：伴生 Chrome 扩展（`JanBrowserExtensionDialog.tsx` 仅为配置入口），本仓库主链未接入，标外部依赖。
- **Project 工作流**：`入口确认`（`web-app/src/routes/project/$projectId.tsx`、`services/projects/default.ts`、rag-extension `scope: "project"` 检索），证据以 UI 层为主；与"协同工作区"聚类（Open WebUI Notes、LobeHub Pages）重叠，本轮不单独提案，留待聚类比较。
- **首次运行向导**：普通引导流程，归并设置类目，不进入统计。

## 对特色贡献统计的影响

- **主贡献候选**：能力一"随附推理引擎的 worker 托管与逐线程 KV 缓存"（`主链确认`，静态证据）。统计中 F41"本地模型运行时与云 Provider 统一路由"已有 Jan 主贡献，其计入理由应扩充为包含 worker 托管与线程缓存；若按"同一工作流合并"原则，将能力一与 F41 视为同一能力族（本地模型运行整体），则 Jan 主贡献理由增强而不新增条目。旧快照的"后端下载/选型/回滚"不再是当前实现，不应据此加分。
- **辅助贡献候选**：能力二（服务端 MCP 编排端点）、能力三（Jan Agent CLI/TUI，属"多表面连续性"聚类方向）、能力四（MCP 智能工具路由，可并入 Agent 工具类目 F31/F33 相关条目）。
- **不重复计数**：Artifact（F22 严格隔离预览仍按消息渲染器归并）、Hub 下载、RAG、web_search。
- 统计表重排待[待查清单](待查清单.md)全局待办第 6 条（按"产品特性贡献"与"机制贡献"拆分重做）一并处理，本笔记仅登记建议。

## 未验证事项

- 全部能力均未运行验证：worker 多模型并发与逐线程缓存命中、GPU 探测与卸载校验、`/v1/orchestrations` 端到端编排、TUI 与 `jan cli agent run` 的真实会话与沙箱、LLM 路由器真实调用与遥测落库。
- `readiness.ts` 探针（`evaluateGpuOffload`/`evaluateEmbeddingVector`）的判定阈值与误报边界未核对。
- MCP 智能路由的"最多 5 服务器"与阈值 5 的具体打分语义未逐行展开。
- Project 工作流主链未走通（本轮未调查服务端权限与持久化细节）。

## 关键源码索引

- `extensions/llamacpp-extension/src/index.ts`（456-557 ensureProvisioned/startEngine、853-900 startEngine、1420 resolveEmbeddingConfig、1485 resolveMtpLayersConfig、2297-2318 容量淘汰）、`preset.ts`（router.preset.ini）、`readiness.ts`（evaluateGpuOffload/evaluateEmbeddingVector）、`backend-settings.ts`/`settings-store.ts`（设置持久化）
- `src-tauri/plugins/tauri-plugin-llamacpp/src/engine/worker.rs`、`engine/registry.rs`、`engine/slots.rs`、`engine/preset.rs`、`process.rs`、`gguf/`；`src-tauri/plugins/tauri-plugin-hardware/src/gpu.rs`、`cpu.rs`、`vendor/`；`src-tauri/plugins/tauri-plugin-websearch/src/commands.rs`、`provider.rs`
- `src-tauri/src/core/server/proxy.rs`（1119 /orchestrations、1182 stream 限制、858 proxy_api_key 校验）、`src-tauri/src/core/agent/loop.rs`（run_server_side_openai_orchestration）、`src-tauri/src/core/server/provider_secrets.rs`、`src-tauri/jan-cli/src/main.rs`（TUI 与 `cli agent/models/threads/mcp`、`config`、`login`）、`src-tauri/src/core/cli/providers.rs`（Provider 解析）、`src-tauri/src/core/cli/tui.rs`
- `web-app/src/lib/mcp-orchestrator/`（intent-classifier.ts、mcp-router-llm.ts）、`web-app/src/lib/mcp-router-model-filter.ts`、`containers/McpRouterModelPicker.tsx`、docs `mcp-routing-telemetry.mdx`
- `web-app/src/lib/gpuBackendMatch.ts`、`modelCompatibility.ts`（estimateModelFit）、`backendDependencies.ts`、`containers/dialogs/DependencyAdvice.tsx`、`routes/system-monitor.tsx`
- `web-app/src/routes/hub/index.tsx`、`containers/ModelDownloadAction.tsx`、`components/HtmlArtifact.tsx`、`lib/utils.ts`（splitHtmlArtifacts）、`containers/RenderMarkdown.tsx`（renderHtmlArtifacts 开关）
- `web-app/src/routes/project/$projectId.tsx`、`services/projects/default.ts`、`extensions/rag-extension/src/tools.ts`（scope: "project"）

# Jan 独特功能调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
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
4. **Agent 运行时对外协议族**（辅助贡献候选）：会话级 JSON-RPC 允许外部客户端声明自己的 host tool 并由运行时把调用派回客户端；同一 Agent 另有实验性 ACP 入口与"把内置工具作为 MCP server 提供出去"的反向方向。
5. **可运行时安装、worker 隔离的扩展运行时**（辅助贡献候选）：第三方扩展以 npm 包形式运行时安装，在 worker 中经 RPC 使用稳定 API 的受控能力；六个内置包仍在宿主进程激活。
6. **MCP 智能工具路由**（辅助贡献候选）：LLM 路由器模型 + 关键词分类降级 + 遥测回调，属 Agent 工具类目的增强形态。

明确不存在的实现：README 语境下不存在"本地↔云模型级 failover"（仅 API key 链 401 重试与 MCP 工具路由降级）；BrowserMCP 是伴生 Chrome 扩展，本仓库只有配置入口。

## 介绍声明与候选盘点

README 与 docs 反复强调的能力集中在：本地优先（模型/后端/API 全本地）、多引擎（llama.cpp + MLX）、Hub 模型市场、MCP、Artifact、Assistant/Agent 与 Project。候选归属的权威表面：`extensions/`（6 个扩展包：assistant、download、llamacpp、mlx、rag、vector-db）、`src-tauri/plugins/`（8 个 Tauri 插件：agent-tools、extensions、hardware、llamacpp、mlx、rag、vector-db、websearch）、`packages/`（extension-api、extension-runtime、adk）、`protocol/`（RPC 与事件 schema）、`src-tauri/src/core/`（Rust 核心，含 Agent 核心与 CLI/TUI）、`src-tauri/jan-cli/`（独立 CLI crate）、`web-app/src/routes/`（前端路由）。

| 候选 | 证据状态 | 结论 |
|---|---|---|
| 随附引擎的 worker 托管与逐线程 KV 缓存（多模型按需加载、LRU 淘汰） | `主链确认` | llamacpp-extension 的 `ensureProvisioned`/`startEngine` + preset + Rust 插件 worker，见能力一 |
| 硬件适配闭环（探测→推荐→运行验证） | `主链确认` | tauri-plugin-hardware + `gpuBackendMatch.ts`/`modelCompatibility.ts` + `readiness.ts` 探针，并入能力一 |
| `/v1/orchestrations` 服务端编排 | `主链确认` | `proxy.rs:1191`，见能力二；需先开启服务端工具执行 |
| Jan Agent CLI/TUI（TUI、`cli agent run`、`cli threads/models/mcp`、`mcp serve`） | `主链确认` | `src-tauri/jan-cli/src/main.rs`，见能力三 |
| Agent 运行时对外协议（JSON-RPC host tools、ACP、MCP serve） | `主链确认` | `src-tauri/src/core/cli/{rpc,acp}.rs`、`protocol/`、`packages/adk/`，见能力五 |
| 可运行时安装的 worker 隔离扩展 | `主链确认` | `packages/extension-api/`、`packages/extension-runtime/`、`web-app/src/lib/extensions/`，见能力六 |
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

**入口与触发者**：扩展 `onLoad` 进入的 `ensureProvisioned()` 触发 `startEngine()`（`extensions/llamacpp-extension/src/index.ts:466-557,870`）；首次运行设置页、启动流程与首次模型加载共用这条单飞（single-flight）链；插件侧命令为 `start_engine`。

**事实对象**：
- 捆绑进 worker 的引擎：版本是编译期常量，`getEngineVersion` 不依赖任何进程；
- `router.preset.ini`：由 `preset.ts` 生成，含全局节与逐模型节、MTP 与采样服务端默认值；
- 每模型 `<data>/llamacpp/models/<modelId>/model.yml`；
- 逐线程 KV 缓存目录：以 `slotCacheMib` 为预算，0 表示关闭。

**完整主链**（其余入口行号见文末索引）：扩展生成 preset → 插件启动受监督的引擎 worker（端口由 OS 分配后回传，并返回 pid、api_key 与已注册模型数）→ worker 的 registry 按需加载模型，容量满时只淘汰空闲的最近最少使用 chat 模型（`userModelsMax` 与 `loadedChatOrder`，`index.ts:459-461`）→ 请求以 thread_id 识别 KV 状态，换入前保存旧状态、命中时恢复，身份校验失败则删除而不恢复（`engine/slots.rs`）→ 运行后 `readiness.ts` 校验 GPU 卸载与嵌入向量、`gpuBackendMatch.ts` 判定引擎与探测 GPU 的家族匹配（`engine/worker.rs`、`engine/registry.rs`、`engine/http.rs`）。

**持续性**：preset、`model.yml` 与线程 KV 目录落盘；worker 在启动它的进程退出（含被 SIGKILL）时因 stdin EOF 自行退出，无需收养或回收。跨会话缓存命中率与并发淘汰时序未运行验证。

**外部依赖与执行域**：引擎与 CUDA/Vulkan 运行库在构建期打包（`src-tauri/build-utils/stage-engine.sh`、`engine-prebuilt.sh` 等），运行期不下载后端；只有回退嵌入模型仍按需获取。硬件探测模块负责 NVIDIA/AMD/Vulkan 厂商识别与显存占用轮询（`src-tauri/plugins/tauri-plugin-hardware/src/` 的 gpu.rs、cpu.rs 与 vendor/）。

**独特性判断**：不再包含旧快照的“后端目录下载/更新/回滚与按硬件选型”（见文末声明不符）；保留的是随附引擎的 worker 托管、容量受限的多模型驻留与逐线程提示缓存，以及“探测→运行校验”的 GPU 实测，调查样本中仍未见同类组合。

**证据强度**：扩展、插件源码与单元测试为静态事实；worker 并发、缓存命中与 GPU 校验阈值未运行验证。

### 能力二：`/v1/orchestrations` 服务端 MCP 编排 — `主链确认`

**用户目标**：让外部 HTTP 客户端触发 Jan 服务端执行一段 MCP 工具编排（加载 assistant 系统提示 → 模型出 tool_calls → 服务端执行 MCP 工具 → 循环至完成），并可用 router 模型预选工具。

**入口与触发者**：`POST /v1/orchestrations`（`src-tauri/src/core/server/proxy.rs:1191`），由外部客户端经本地 API 服务器触发；只有设置里开启服务端工具执行时该路由才放行（`orchestrations_allowed`，`:619`），`stream=true` 不支持。

**事实对象**：请求为一次性编排会话，服务端维护 tool_calls 循环状态。

**完整主链**：请求到达 → 加载对应 assistant 系统提示 → 模型生成 tool_calls → 服务端在自身进程内执行 MCP 工具 → 结果回注循环直至完成 → 返回汇总响应。与普通 `/v1/chat/completions`、`/v1/messages` 并列于 `resolve_upstream_for_model`（`src-tauri/src/core/agent/upstream.rs:636`）的三路路由（云端 provider → MLX 会话 → llama.cpp router）。

**人机与多 Agent 关系**：外部客户端（其他 Agent 或脚本）以 HTTP 身份参与；工具执行发生在 Jan 服务端，权限边界沿用 MCP 工具的既有执行域。

**独特性判断**："本地 OpenAI 兼容服务"可归并已有类目，但"把 MCP 工具执行编排暴露为 HTTP 端点"接近本地 Agent 服务器形态，样本中未找到同类端点。

**证据强度**：`proxy.rs` 端点为静态事实；端到端编排行为未运行验证。

### 能力三：Jan Agent CLI/TUI — `主链确认`

**用户目标**：终端用户不打开桌面窗口，即可在项目目录中运行一个能读写文件、执行命令的 Agent，并直接复用桌面或项目里已配置的远程 Provider。

**入口与触发者**：独立 crate `src-tauri/jan-cli/src/main.rs`（`main` 在 `:763`），由用户在终端触发；裸 `jan` 打开交互式 Agent 控制台（TUI），带子命令则走非交互面。命令树除 `cli` 外还有 `login`/`auth`/`usage`/`config`/`plugin`/`mcp serve`/`update` 与隐藏实验项 `acp`（`main.rs:229` 起的 `Commands`）。

**完整主链与非交互面**：
- Provider 解析优先级：CLI 参数与 `JAN_API_KEY`/`<PROVIDER>_API_KEY` 环境变量 > 项目 `.jan/agent/agent.toml` 的 `[provider]` > 桌面 `settings.json`（只继承、不回写）> 全局 `~/.jan/config.toml`（`src-tauri/src/core/cli/providers.rs:1-16`）；
- `jan cli agent run/step/status`：非交互运行项目 Agent；
- `jan cli models list`、`jan cli threads list/get/delete/messages`、`jan cli mcp list/get/add/remove/enable/disable`：列出已配置 Provider 的模型、读取与删除线程、管理共享的 `mcp_config.json`（`main.rs:236-263,385-479`）；
- `jan config set/unset/list/path` 管理 `~/.jan/config.toml` 中的 Provider 凭据，`jan login`/`auth` 处理 Tokamak 登录，`jan usage` 读取账号用量，`jan plugin` 管理项目插件与技能，`jan update` 自更新；
- Agent 工具循环复用桌面的 Rust Agent 核心；`--safe` 在写入、命令与 MCP 调用前审批，`--sandbox` 开启 OS 沙箱（默认按配置关闭），`--no-sandbox` 临时取消持久配置，沙箱内升级需批准，`--plan` 只读计划模式，`-c`/`--resume` 恢复项目会话。
- 反向方向：`jan mcp serve` 把只读内置工具按项目根目录暴露给其他 Agent（stdio 或 loopback HTTP，写与执行需 `--allow-write`/`--allow-exec`）。

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

### 能力五：Agent 运行时对外协议族 — `主链确认`

**用户目标**：让外部程序驱动 Jan 的 Agent 内核，而不是只能从桌面或终端界面使用它；同一内核同时要能当工具提供方，供别的 Agent 调用。

**入口与触发者**：外部客户端启动 `jan cli agent rpc`，通过 LF 分隔的 stdio 驱动 Jan 的 Agent 内核；这是外部程序控制 Jan 的方向。实验性 ACP 走 stdio 供编辑器接入，需环境变量或项目配置显式开启；反向的 `jan mcp serve` 把内置工具作为 MCP server 提供出去。命令分派见 [main.rs:563–578、1179](../../jan/src-tauri/jan-cli/src/main.rs#L563-L578)，RPC 服务见 [rpc.rs:488–552](../../jan/src-tauri/src/core/cli/rpc.rs#L488-L552)。

**事实对象**：RPC 会话（连接身份 + 会话 id + 模型 + 工具集）、host tool 声明（客户端提供、运行时派发）、协议 schema 产物（`protocol/schema.json`、`protocol/rpc-schema.json`）与由它生成的客户端（`packages/adk` 的 JavaScript 实现、`adk/python` 的 Python 实现）。

**完整主链**：客户端请求 `initialize` 并发送 `initialized` 通知完成握手，再以 `session/start` 创建会话、`session/tools/set` 声明客户端工具，随后用 `turn/start` 发起生成。模型调用客户端工具时，Jan 派发请求，客户端通过 `tool/respond` 回填；`turn/steer` 可向运行中回合追加输入，结束通知为 `turn/completed`。方法名采用斜杠分隔，握手与调度分支见 [rpc.rs:518–610](../../jan/src-tauri/src/core/cli/rpc.rs#L518-L610)、[rpc.rs:673–801](../../jan/src-tauri/src/core/cli/rpc.rs#L673-L801)。

**并发与持续性**：一个进程可持有多个会话，同时只运行一个回合；运行中更换该会话的工具或模型会收到可重试错误。`session/resume` 只查进程内会话表；成功完成且未设 ephemeral 的会话可保存为项目线程，但该 RPC 方法不从磁盘恢复旧进程的会话。临时会话还关闭项目记忆写入（[rpc.rs:459–473](../../jan/src-tauri/src/core/cli/rpc.rs#L459-L473)、[rpc.rs:569–581](../../jan/src-tauri/src/core/cli/rpc.rs#L569-L581)、[rpc.rs:704–751](../../jan/src-tauri/src/core/cli/rpc.rs#L704-L751)）。

**人机与多 Agent 关系**：外部客户端既是调用方也是工具执行方，权限边界因此从"Jan 在本机执行什么"变成"客户端允许 Jan 请求什么"；`jan mcp serve` 方向则相反，是 Jan 把受限工具面交给别的 Agent。

**独特性判断**：把 Agent 内核同时暴露成"可被驱动的运行时协议"与"可被调用的工具服务"，并让工具执行留在客户端一侧，这种双向契约在样本中未见过同类实现。

**证据强度**：RPC 入口、命令树、schema 与 ADK 包为静态事实；未用 ADK 客户端实跑，工具派发失败与并发 steer 的行为未验证。

### 能力六：可运行时安装的 worker 隔离扩展 — `主链确认`

**用户目标**：扩展不再是随仓库发布的固定清单，而能在运行时安装、升级、卸载，同时不让第三方便宜地直接拿到宿主全部能力。

**入口与触发者**：设置页提供 Installed/Catalog 两个页签，可从本地 `.tgz` 包或目录索引安装；开发目录加载只在开发构建显示。安装先暂存，首次安装展示权限同意框，升级展示新增权限差异，确认后提交注册表并重载扩展。入口与事件见 [扩展设置页:107–155、240–263](../../jan/web-app/src/routes/settings/extensions/index.tsx#L107-L155)、[useStagedInstall:34–95](../../jan/web-app/src/containers/extensions/useStagedInstall.tsx#L34-L95)。

**事实对象**：扩展包（npm 形式的包 + 清单）、稳定 API（`packages/extension-api` 的 `API_VERSION`、能力与贡献声明、语义化版本兼容判断、`Disposable` 与事件）、worker 侧运行时（`packages/extension-runtime` 的 `protocol.ts`、`handles.ts`、`endpoint.ts`、`worker/`）。

**完整主链**：用户确认安装 → Rust 提交数据目录中的包与注册表 → loader 读取启用条目和经哈希核验的入口 → 宿主在启动 worker 前校验 API 版本，并把授权收窄为清单请求集合 → 第三方扩展在 worker 中经 RPC 调用受控宿主 API → 贡献点进入界面与服务注册表。禁用、升级、回滚、卸载与权限变更均通过按扩展串行的 reload 先释放旧贡献再重读注册表，避免旧权限的 worker 最后启动（[installed-loader.ts:66–117](../../jan/web-app/src/lib/extensions/installed-loader.ts#L66-L117)、[host.ts:260–389](../../jan/web-app/src/lib/extensions/host.ts#L260-L389)）。

**执行域边界**：仓库内六个内置扩展使用宿主进程的 `activate(ctx)`，可取得内部服务、文件、引擎等能力；安装和开发加载的第三方扩展才使用 worker 隔离。两条路径共享 dispatcher 的参数校验，但内置扩展不受 worker 的通知速率、监听数和并发请求限额约束（[builtins.ts:9–27](../../jan/web-app/src/lib/extensions/builtins.ts#L9-L27)、[host.ts:564–600](../../jan/web-app/src/lib/extensions/host.ts#L564-L600)）。

**持续性与故障收口**：安全模式先保存标志再停止所有已安装扩展，内置和开发扩展保持原状；关闭后重新加载启用项。已安装扩展崩溃后可从注册表重启，短时间反复崩溃则本次应用会话内禁用并通知用户。设置经宿主存储保存，RAG 设置另有一次性键名与类型迁移（[installed-loader.ts:125–157](../../jan/web-app/src/lib/extensions/installed-loader.ts#L125-L157)、[host.ts:500–528](../../jan/web-app/src/lib/extensions/host.ts#L500-L528)）。

**独特性判断**：扩展能力从"仓库内固定 JS 目录"变成"运行时可安装 + worker 隔离 + 稳定 API + API 报告校验"的组合，与旧快照的实现相比是机制级变化；样本中同类桌面 Agent 产品少有把扩展隔离做到 worker + 版本化 API 报告。

**证据强度**：包结构、加载器与迁移逻辑为静态事实；安装/升级的端到端流程、worker 崩溃恢复与 API 兼容性拒载未运行验证。
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
| Agent 项目记忆（vector-db 插件的 FTS5/BM25 存储、只索引最终回答、有界摘要） | 检索增强与认知编排类目；属该项目的记忆机制，不单独计主贡献 |
| 子 Agent 的独立 git worktree 与只读根、shell 沙箱升级审批 | Agent 工具类目；属工具执行域的权限与隔离细节 |
| 外发请求 provenance 摘要与 OTel 观测 | LLM 渠道与运行时类目；属可观测性工程机制 |
| Cowork 的产物卡、差异面板与预览面 | 生成式输出与运行时类目 |

## 声明不符、外部依赖与暂缓项

- **本地↔云模型级 failover**：README 语境下的"容灾/路由"易被读成智能调度；按当前快照只有云端 API key 链 401 重试（`provider-api-keys.ts`）与 MCP 工具路由降级，无分片、无模型级本地↔云自动切换。统一路由 = 按 `model_id` 静态解析，结论维持归并。
- **设备级推理器下载/选型/回滚**：旧快照的 `configureBackends`、`updateBackend`、`restartRouterAndProbe` 与后端目录、`update_history.json` 已不在当前源码中；引擎改为编译期捆绑进随附 worker，首次运行不再下载数百 MB 后端，相关设置键（`llamacpp_version`、`llamacpp_backend`、`check_for_updates`、`auto_update_engine`、`verify_backend_deps`）已从扩展设置中移除。旧"按硬件选 CUDA/Vulkan/CPU 后端并回滚"的表述不再成立。[代码确认]
- **旧 `jan serve` / `jan launch claude|openclaw`**：旧快照的一键启动本地模型服务、并自动预接外部 Agent CLI 的命令不在当前 CLI 命令树中；当前 CLI 只运行自身的 Agent（见能力三与外部执行体笔记）。
- **BrowserMCP**：伴生 Chrome 扩展（`JanBrowserExtensionDialog.tsx` 仅为配置入口），本仓库主链未接入，标外部依赖。
- **Project 工作流**：`入口确认`（`web-app/src/routes/project/$projectId.tsx`、`services/projects/default.ts`、rag-extension `scope: "project"` 检索），证据以 UI 层为主；与"协同工作区"聚类（Open WebUI Notes、LobeHub Pages）重叠，本轮不单独提案，留待聚类比较。
- **首次运行向导**：普通引导流程，归并设置类目，不进入统计。

## 对特色贡献统计的影响

- **主贡献候选**：能力一"随附推理引擎的 worker 托管与逐线程 KV 缓存"（`主链确认`，静态证据）。能力五与能力六目前只登记为辅助候选：前者与"多表面连续性"聚类相邻但方向相反（把内核交出去而非接进来），后者是工程机制贡献，是否计入待统一口径后再定。统计中 F41"本地模型运行时与云 Provider 统一路由"已有 Jan 主贡献，其计入理由应扩充为包含 worker 托管与线程缓存；若按"同一工作流合并"原则，将能力一与 F41 视为同一能力族（本地模型运行整体），则 Jan 主贡献理由增强而不新增条目。旧快照的"后端下载/选型/回滚"不再是当前实现，不应据此加分。
- **辅助贡献候选**：能力二（服务端 MCP 编排端点）、能力三（Jan Agent CLI/TUI，属"多表面连续性"聚类方向）、能力四（MCP 智能工具路由，可并入 Agent 工具类目 F31/F33 相关条目）、能力五（Agent 运行时对外协议族）、能力六（可运行时安装的 worker 隔离扩展）。
- **不重复计数**：Artifact（F22 严格隔离预览仍按消息渲染器归并）、Hub 下载、RAG、web_search。
- 统计表重排待[待查清单](待查清单.md)全局待办第 6 条（按"产品特性贡献"与"机制贡献"拆分重做）一并处理，本笔记仅登记建议。

## 未验证事项

- 全部能力均未运行验证：worker 多模型并发与逐线程缓存命中、GPU 探测与卸载校验、`/v1/orchestrations` 端到端编排、TUI 与 `jan cli agent run` 的真实会话与沙箱、LLM 路由器真实调用与遥测落库。
- 能力五的 RPC 与 ACP 只用 schema 与源码核对，未用 ADK 客户端或编辑器实连；MCP serve 的传输与 token 校验未实跑。
- 能力六的运行时安装/升级/卸载、worker 崩溃恢复、API 版本拒载与贡献点热更新均未运行验证。
- `readiness.ts` 探针（`evaluateGpuOffload`/`evaluateEmbeddingVector`）的判定阈值与误报边界未核对。
- MCP 智能路由的"最多 5 服务器"与阈值 5 的具体打分语义未逐行展开。
- Project 工作流主链未走通（本轮未调查服务端权限与持久化细节）。

## 关键源码索引

- `extensions/llamacpp-extension/src/index.ts`（466-557 ensureProvisioned、870 startEngine、1432 resolveEmbeddingConfig、459-461 容量淘汰状态）、`preset.ts`（router.preset.ini）、`readiness.ts`（evaluateGpuOffload/evaluateEmbeddingVector）、`backend-settings.ts`/`settings-store.ts`（设置持久化）
- `src-tauri/plugins/tauri-plugin-llamacpp/src/engine/worker.rs`、`engine/registry.rs`、`engine/slots.rs`、`engine/preset.rs`、`process.rs`、`gguf/`；`src-tauri/plugins/tauri-plugin-hardware/src/gpu.rs`、`cpu.rs`、`vendor/`；`src-tauri/plugins/tauri-plugin-websearch/src/commands.rs`、`provider.rs`
- `src-tauri/src/core/server/proxy.rs`（1191 /orchestrations、619 服务端工具执行开关、930 proxy_api_key 校验、2408 不安全绑定拒绝）、`src-tauri/src/core/agent/loop.rs`（run_server_side_openai_orchestration）、`src-tauri/src/core/server/provider_secrets.rs`、`src-tauri/jan-cli/src/main.rs`（TUI 与 `cli agent/models/threads/mcp`、`config`、`login`）、`src-tauri/src/core/cli/providers.rs`（Provider 解析）、`src-tauri/src/core/cli/tui.rs`
- `web-app/src/lib/mcp-orchestrator/`（intent-classifier.ts、mcp-router-llm.ts）、`web-app/src/lib/mcp-router-model-filter.ts`、`containers/McpRouterModelPicker.tsx`、docs `mcp-routing-telemetry.mdx`
- `web-app/src/lib/gpuBackendMatch.ts`、`modelCompatibility.ts`（estimateModelFit）、`backendDependencies.ts`、`containers/dialogs/DependencyAdvice.tsx`、`routes/system-monitor.tsx`
- `web-app/src/routes/hub/index.tsx`、`containers/ModelDownloadAction.tsx`、`components/HtmlArtifact.tsx`、`lib/utils.ts`（splitHtmlArtifacts）、`containers/RenderMarkdown.tsx`（renderHtmlArtifacts 开关）
- `web-app/src/routes/project/$projectId.tsx`、`services/projects/default.ts`、`extensions/rag-extension/src/tools.ts`（scope: "project"）
- 对外协议：`src-tauri/src/core/cli/rpc.rs`、`acp.rs`、`src-tauri/src/core/agent/host_tools.rs`、`protocol/rpc-schema.json`、`packages/adk/`、`adk/python/`
- 扩展运行时：`packages/extension-api/`、`packages/extension-runtime/`（`worker/`、`protocol.ts`）、`web-app/src/lib/extensions/`、`src-tauri/plugins/tauri-plugin-extensions/`

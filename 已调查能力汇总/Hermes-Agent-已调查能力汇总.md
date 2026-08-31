# Hermes-Agent 已调查能力汇总

> 汇总对象：`Hermes-Agent`（远端仓库 `https://github.com/NousResearch/hermes-agent`，产品命令 `hermes`）
>
> 汇总更新日期：2026-08-31
>
> 依据：Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、外部执行体与应用协作、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时、检索增强与认知编排共 15 个类目的 Hermes-Agent 调查笔记（完整清单见文末来源笔记索引），基于代码快照 `791e2ae3257e211d14ca77e654dfe10ee1976a1c`（分支：`main`）
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题合并重复能力，保留证据状态并链接来源；未做新的源码调查与跨项目横向比较
>
> 汇总范围：上述 15 个类目的既有调查结论；仓库分布与应用界面基础设施两个工程向类目单列于"工程与基础设施摘要"小节；排除跨项目横向比较、评分与排序
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

Hermes Agent 是跨 CLI / TUI / 桌面 / Web / 消息网关复用同一套 Python agent 核心的个人 AI 助手，README 自我定位为 "self-improving agent"，核心卖点是内置学习闭环。架构形态是混合 monorepo：Python 核心（`run_agent` / `cli` / `gateway` / `tools`）与 TypeScript 前端（Electron 桌面、Ink TUI、Web dashboard）同仓。桌面端不运行 agent，而是自 spawn 一个无头 `hermes serve` 后端进程，renderer 经 WebSocket JSON-RPC 通信；后端 SQLite 是会话与消息的唯一真相源，各前端只是缓存投影。本次汇总覆盖 15 个类目的调查结论，证据全部来自静态源码阅读，未运行应用、测试与真实模型请求。

## 完成度速览

| 证据状态 | 条目数 |
|---|---|
| 主链确认 | 14 |
| 静态源码确认（未运行） | 17 |
| 入口确认（未闭合，集中在末尾小节） | 2 |
| 归并已有类目 | 4 |
| 声明不符 | 1 |
| 暂缓 | 0 |

功能能力共 37 条：确认态（主链确认 + 静态源码确认）31 条，占约 84%；入口确认 2 条、归并已有类目 4 条。声明不符 1 项（"the only agent" 宣传强度）、agentskills.io 声明未核验 1 项、暂缓 0 项，另有候选观察 1 项（实验性 relay connector），异常项均不混入功能能力正文，集中在文末"已知边界与待验证事项"。

**证据口径**：本汇总的“主链确认/静态源码确认”表示已在当前代码快照 `791e2ae` 复查入口、状态、执行与结果处理构成的实现路径。“未运行验证”只保留需要在目标环境观察的 UI、端到端、时序与外部依赖表现，不使实现结论失效。能力条目中的“默认关闭/依赖外部服务/依赖用户配置”等边界均来自来源笔记的明确表述。

## 功能能力摘要

当前快照补充：客户端重连以每会话事件序号补取缺口，桌面端以 connection + profile 路由同 ID 会话；默认上下文压缩保留 10K--25K token 的 lean tail。Provider 可从已启用的 pip entry point 发现，浏览器真实档案与终端环境后端则分别受用户同意和插件注册边界约束。详情见本汇总所列的会话与消息管理、对话请求与上下文、LLM 渠道管理和 Agent 工具来源笔记。

### 角色与上下文

- **分层角色机制（无独立角色对象）**：角色是多个互补提示词机制按"身份 → 命名模板 → 全局/会话覆盖 → 运行时注入"分层叠加——`$HERMES_HOME/SOUL.md` 主身份文件（缺失回退硬编码 `DEFAULT_AGENT_IDENTITY`）、personalities 具名模板（内置 14 个，用户按名覆盖）、`agent.system_prompt` 用户手动 overlay（人格代码永不写入）、`display.personality` 保存选中名并成为权威来源、`ChannelOverride` 渠道级覆盖、Profile 构成完整隔离包。人格文本经 ephemeral system prompt 运行时追加、不进缓存、不进轨迹。证据：主链确认（静态源码阅读）。链接：[Agent 角色调查笔记](../Agent角色/Hermes-Agent-Agent角色配置调查笔记.md)、[Chat 调查笔记](../Chat/Hermes-Agent-Chat调查笔记.md)。
- **系统提示词三层拼装与缓存**：`build_system_prompt_parts` 产出 stable（身份与指引，字节稳定以保前缀缓存）/ context（cwd 相关、上下文文件）/ volatile（技能索引、记忆、时间戳）三档，每会话构建一次并缓存、仅上下文压缩时重建；完整构建结果写入 `system_prompts` hash 去重表，会话行引用 model/model_config 快照。证据：静态源码阅读确认（未运行）。链接：[Agent 角色调查笔记](../Agent角色/Hermes-Agent-Agent角色配置调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)。
- **上下文构建、预算与压缩**：`build_turn_context` 约 30 个动作分组组装本轮上下文（恢复轮转会话、MCP 工具刷新、系统提示词恢复、DB 行确保、压缩检查、插件钩子、记忆预取、sidecar 注入、崩溃持久化）。压缩无 token 级截断原语：preflight 多 pass（至多 3 轮、要求行数减少或 token 降幅>5%）+ idle 压缩（墙上时间门）+ gpt-5.6 服务端 native compaction 并存；`prompt_cache_boundary` 注册表声明 stable/volatile 缓存边界断点；轮转压缩生成新 session_key 连血缘链，原地压缩同 ID 软归档。证据：静态源码阅读确认（未运行）。链接：[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。
- **会话级绑定与覆盖优先级**：模型 / 人格 / 提示词绑定粒度为会话级，`model_override` 等为每会话字段；模型优先级按"会话 > 渠道 > 全局"解析，运行中 `/model` 切换以 `model_switch` 时间线条目入史、不计入 user 轮计数。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[Agent 角色调查笔记](../Agent角色/Hermes-Agent-Agent角色配置调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)。

- **记忆与跨会话检索的三条路径**：内置 `MEMORY.md`/`USER.md` 在下一会话以冻结快照进入系统提示词；可选外部 MemoryProvider 在每轮用户消息前预取上下文并附加到该轮 API sidecar，完成回合后异步写回；`session_search` 则以 SQLite FTS5 搜索会话并返回命中锚点窗口。三者均不是统一文档知识库或固定多阶段认知编排。证据：静态源码确认（未运行）。来源：[检索增强与认知编排调查笔记](../检索增强与认知编排/Hermes-Agent-检索增强与认知编排调查笔记.md)。

### 会话与消息

- **状态权威与双 ID 身份**：后端 SQLite `state.db` 是唯一事实源；进程内 UI 句柄 `sid` 与持久 `session_key` 分离；压缩轮转经 `parent_session_id` + `end_reason='compression'` 连成轮转链，跨轮转不变的稳定标识是派生只读字段 `_lineage_root_id`，桌面端 pin、路由匹配、草稿作用域都键在它上。证据：主链确认（静态）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[Chat 调查笔记](../Chat/Hermes-Agent-Chat调查笔记.md)。
- **会话生命周期与崩溃恢复**：DB 行惰性落行（首次真实 turn 才建行，空草稿不留痕）；resume 沿压缩链跳活 tip，close 只标记 `ended_at/end_reason` 不删数据，归档 `archived=1` 软隐藏，硬删除无回收站；崩溃痕迹只在 `interrupted_turns.json` 中断标记文件，resume 时按标记自动重放且 attempts 防循环；子代理是真实会话（`_delegate_from` 标记，删除时沿标记级联）。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)。
- **消息数据模型与持久化**：`messages` 表一行一条消息，字段含 role / content / tool_calls / reasoning / `active`（软删）/ `compacted`（压缩归档仍可搜索）/ `display_kind` / `api_content`（发 API 的字节保真 sidecar，恢复时原样返回）；落盘用"单事务批量 + 内存 marker 去重"的原子配对契约，崩溃中途不写库；工具执行增量 flush 应对工具杀死进程场景。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。
- **编辑、重试、续写与分支**：编辑通过"截断 + 重发"实现（截断提交要求显式 `confirm_truncate`，无单消息原地编辑或删除 RPC）；重试三套实现共享"截断到最后一个真实 user turn 后重发"语义；续写无独立命令，就是普通 prompt 文本 "continue"；分支 `session.branch` 建新 session_key + `_branched_from` 标记、标题加 `#N`；截断重发带归档语义，旧轮次落盘为可搜索归档行。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)。
- **标题机制（两段式 + 带来源）**：会话首个 turn 的 prologue 即得 derived 即时标题（确定性派生、无模型调用），后台线程用小模型升级为 llm 标题；标题带 provenance（derived < llm < user），`set_auto_title` 单事务 compare-and-swap 防自动覆盖，用户 `/title` 永不被覆盖；压缩轮转携带标题与 provenance 不变。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。
- **列表、分页与搜索**：会话列表 `list_sessions_rich` 单查询完成预览、置顶回填、按压缩链 tip 最近活跃排序与逻辑去重；REST 分页 limit/offset、侧栏分 profile 分片翻页；消息搜索走 FTS 四路矩阵（unicode61 基表 / CJK bigram / trigram / LIKE 兜底），trigram 明确跳过 `role='tool'` 行（约 90% 字节为机器噪声）；`session_search` 跨会话检索带谱系去重与锚定窗口。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **对话导出与导入**：两条按需快照路径（`/save` 三入口 + 运行期 JSON 快照默认关闭）与一条结构化导出子系统（`hermes sessions export`，支持 jsonl / md / qmd / html / trace 五格式，`--redact` 脱敏、`--lineage logical` 合并压缩血缘链）；trace 可 `--upload` 到 Hugging Face（默认私有、强制脱敏）；导入经 `POST /api/sessions/import` 往返，带四类硬上限。E3 图片分享与 E4 对话链接分享未覆盖，见末尾小节。证据：静态源码调查确认（未运行）。链接：[对话导出与分享调查笔记](../对话导出与分享/Hermes-Agent-对话导出与分享调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。

### 生成与创作

- **生成式输出与 Artifact（能力等级 G3）**：桌面渲染器对模型流式文本中的代码围栏做后验启发式检测（html/svg/代码四类体积与行数门槛、散文排除与语言黑名单防误触发），围栏收尾后注册为 artifact 卡片；HTML 在 `<iframe sandbox="allow-scripts">` 中运行、URL 在沙箱 webview 中运行，带版本化注册表（内存-only，以聊天记录为事实源）；模型回流部分存在（read_preview / read_terminal / read_file）。artifact 不可被模型寻址、不可用户编辑，无 notebook / 画布 / 白板，细节见末尾小节。证据：主链确认（静态走通）。链接：[生成式输出与运行时调查笔记](../生成式输出与运行时/Hermes-Agent-生成式输出与运行时调查笔记.md)。
- **MEDIA: 媒体输出协议**：`MEDIA:<absolute-path>` 纯文本标签是唯一"模型/工具 → 平台"单向消费的协议，消息平台拦截为原生附件，递送前有安全根校验（缓存根白名单 + 10 分钟新鲜度信任 + 系统路径/凭据子路径硬拒）；桌面渲染器把该标记行改写为媒体链接并渲染播放器；配套图像 sub-2MP 默认 upscale 后处理。证据：静态源码确认（未运行）。链接：[生成式输出与运行时调查笔记](../生成式输出与运行时/Hermes-Agent-生成式输出与运行时调查笔记.md)。
- **消息渲染体系**：四套渲染面共享同一 `tui_gateway` 后端——TUI 自研 `markdown.tsx` 行状态机（无第三方 Markdown 依赖）、桌面 Streamdown + Shiki + KaTeX、Web 极简辅助渲染、经典 CLI/gateway 仅记录边界；流式走"先缓冲、后分段"模型（`message.delta` 累积 → streaming 状态对象 → `message.complete` 定稿去重）；列表层 TUI 自定义虚拟化 vs 桌面渲染预算 + `content-visibility`；链接协议白名单、iframe sandbox 隔离、`dangerouslySetInnerHTML` 仅用于 3 处 SVG 片段与 artifact 预览。证据：静态源码阅读确认（DOM/视觉未运行验证）。链接：[消息渲染器调查笔记](../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)。
- **Composer 与输入（草稿、附件、发送配置）**：草稿按会话持久化（localStorage 上限 50 条、仅文本、跨窗口 storage 事件同步、压缩轮转时随 tip 迁移、附件仅内存不落盘）；拖放附件按来源分流（应用内路径 → 内联 `@file:` ref、OS 文件 → 附件管线、目录 → `@folder:`、图片 → base64 缩略图）；斜杠命令为客户端侧编目与派发管线；发送走 `prompt.submit` 带 1800s 超时、busy 门控、storedId/runtimeId 配对校验与 session 切换 drift 守卫。证据：静态源码阅读确认（未运行）。链接：[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)、[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)。

### Agent 运行时与外部协作

- **工具来源、注册与发现**：工具面由多层来源组成——仓库 `tools/` 自动导入注册、`plugins/` 插件工具、MCP 客户端动态发现、skills 指令文本工具、Agent Plugins 便携包（v1 目录包兼容层）、`toolsets.py` 按平台工具集装配；注册集中在 `tools/registry.py`（`register()` 在模块 import 时被各工具调用），四个 agent-level 工具由 `_AGENT_LOOP_TOOLS` 拦截不进入 registry；`get_tool_definitions` 做白/黑名单过滤、动态 schema override 与进程级 `_last_resolved_tool_names` 记录；tools 数组每次 API 调用全量发送（prompt caching 只缓存 system prompt 前缀）。证据：主链确认（静态源码阅读）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **工具执行编排与参数校验**：核心执行链沿 `run_agent.py → model_tools.py → tools/registry.py` 三层组织；模型回吐 tool_calls 经 id 去重、name 校验（近似修复）、JSON 解析重试 ≤3 次；执行分单 / 并发 / 分段三路（并发走 DaemonThreadPoolExecutor 默认 8 线程，`ConcurrentToolAuthorizationGate` 串行化审批顺序）；参数校验靠 `coerce_tool_args` 与 `_normalize_json_strings_for_schema`，无独立 schema 强制校验器；结果回注 tool 消息 + 三层持久化预算（per-tool / per-turn / preview，超限落盘用 preview+文件引用回填）。证据：主链确认（静态源码阅读）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **审批与执行边界**：CLI 交互审批 `prompt_dangerous_approval` 只是 `check_dangerous_command` 的一环，`HERMES_YOLO_MODE` 冻结或会话 yolo 开启时整个审批门可被跳过；真正执行端是 `registry.dispatch`，其 handler 不重新核对审批标记；`execute_code` 沙箱 RPC 直接调用 `handle_function_call` 是独立旁路（只受 allow-list 限制、不重复审批）；另有自仓库 git 变更硬阻断、systemd cgroup 隔离、本地执行无强制 sandbox、容器类有 `container_cpu/memory/disk` 资源上限。证据：主链确认（静态源码阅读）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **MCP、插件、Skill 与便携包扩展**：插件经 `discover_plugins` 副作用注册并提供五类 hooks，`resolve_pre_tool_block` 是每个工具分发点的单一安全入口（任何错误 fail-closed）；MCP server 注册为 `mcp-<name>` toolset、动态 `tools/list_changed` 触发 nuke-and-repave、trust-tier 门控分 full/untrusted 两档；Skill 是文本指令而非权限沙箱；Agent Plugins 便携包把便携包的技能 / MCP 组件翻译进 Hermes 运行时。证据：静态源码阅读确认（未运行）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **子代理委派**：`delegate_task` 创建占 DB 行的子会话（`_delegate_from` 标记），继承同一套创建与持久化语义，删除时沿标记级联；子代理默认 auto_deny、session/terminal 独立、可选继承父 MCP 工具；支持可选结构化输出 schema 与 per-delegation 成本返回。证据：静态源码阅读确认（未运行）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。
- **外部执行体与控制面（多表面）**：桌面、TUI 和 Web 控制面共享同一个 Python `tui_gateway` / `AIAgent` runtime、profile 数据库与 session lineage，经 JSON-RPC 提交、流式接收、取消和恢复任务；`acp_adapter/` 把 Hermes 作为 ACP agent 暴露给 VS Code / Zed / JetBrains 等外部宿主；REST API gateway 提供补全、响应与运行类端点（`/v1/chat/completions`、`/v1/responses`、`/v1/runs` + SSE 订阅）及会话管理与 cron 接口；新客户端接入经 DM Pairing 一次性配对码授权，正在运行的 turn 可被新客户端收养为 adopted running turn。消息平台 gateway 20+ 平台为入口确认，逐 adapter 细节见末尾小节。证据：主链确认（静态）/ 消息平台为入口确认。链接：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/Hermes-Agent-外部执行体与应用协作调查笔记.md)、[Chat 调查笔记](../Chat/Hermes-Agent-Chat调查笔记.md)。

### 渠道与调度

- **LLM 渠道与 Provider 管理**：无"LLM 渠道"实体——Provider 是声明式 `ProviderProfile` 标识 + 凭据注册表，用户实例化的是 `providers:` / `custom_providers:` 端点（base_url + key_env/api_key + extra_headers），"渠道"等价于"Provider 标识 + 一个 base_url + 一份凭据"的组合；模型目录为静态表 + 远端拉取 + 用户输入三层；协议适配集中在 `agent/transports/` 按 api_mode 注册分发（OpenAI 兼容 / Anthropic / Responses / Bedrock）；运行时由 `resolve_runtime_provider` 产出运行时 dict；管理入口不对称——Desktop 自定义端点页是全 CRUD，CLI/TUI/Web 主要管理凭据、模型选择或整个 Profile，未找到同等端点 CRUD 页面。证据：静态源码阅读确认（未运行）。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/Hermes-Agent-LLM渠道管理调查笔记.md)。
- **重试、Key 轮换与故障转移**：四层机制——SDK 内建重试 → 应用层重试 → 同 Provider 多 Key 的 credential pool 轮换（429/401/供应商错误）→ 跨渠道 fallback 链（`fallback_providers` 需用户显式声明）→ 会话层恢复主通道；fallback 切换重建 transport 重发同一消息，存在重复计费可能（推断）；凭据层化存储（.env / auth.json / credential pool）并在子进程、日志、UI、备份全链路脱敏；设置页连接测试走独立 HTTP 探针，不经过真实 resolver / pool / fallback 链，测试通过不等于真实聊天可用。证据：静态源码阅读确认（重复计费为推断）。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/Hermes-Agent-LLM渠道管理调查笔记.md)。

### 独特与差异化能力

以下能力卡保留[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)的能力卡标题与证据状态。四项主能力卡均达主链确认（静态证据）；共同前提是"prompt caching is sacred"——后台机制继承主会话运行时与提示缓存、对主对话零干扰。入口确认未闭合的候选（Tool Gateway、全局紧急停止）与声明/外部依赖边界不在此列，集中在文末"已知边界与待验证事项"。

- **能力一：闭环学习（后台记忆/技能复习 + /refine）**：每 N 轮 / 每 N 次工具迭代触发一次后台 fork 复习，fork 继承父会话模型配置、凭据与已缓存系统提示，命中同一提示缓存；后台复习只放行 memory 与 skill_manage 工具（线程级白名单），复习结果写 MEMORY.md / 技能目录或外部 provider；`/refine` 为用户显式触发同一 fork 的按需入口；复习失败仅捕获不抛出，best-effort。证据：主链确认（静态证据）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **能力二：Skill 生命周期（创建-使用中改进-curator 维护）**：`skill_manage` 提供六动作（create/patch/edit/delete/write_file/remove_file），"复杂任务成功 / 克服错误 / 用户纠正有效"定为创建时机；`.usage.json` 侧车记录使用统计；curator 惰性后台维护（按 stale_after_days/archive_after_days 标记与归档，从不删除、pinned 跳过、只处理 agent 创建技能），`hermes curator` CLI 提供状态查看/运行/暂停/回滚等子命令。证据：主链确认（静态证据）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **能力三：持久记忆与用户建模**：双轨记忆——内置 `MEMORY.md` / `USER.md` 文件记忆注入 system prompt volatile 段 + `MemoryProvider` ABC 外部后端（honcho/mem0/supermemory 等 8 个，同一时刻至多激活一个）；模型写记忆可能被人审拦截（写审批门，用户 `/memory approve` 后才落盘）；跨会话用户建模的 dialectic 多轮推理由 Honcho 承担，本仓库只含接入链（建模质量见末尾小节）。证据：主链确认（内置）/ 入口确认（外部 provider）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[Agent 角色调查笔记](../Agent角色/Hermes-Agent-Agent角色配置调查笔记.md)。
- **能力四：研究数据工具链（会话轨迹生产）**：`save_trajectories` 开关（默认关闭）把每轮会话按 ShareGPT 格式追加为 JSONL（成功/失败分文件）；`trajectory_compressor.py` 保护首尾只压缩中间段并替换为摘要；配套 `batch_runner.py` / `mini_swe_runner.py` / `datagen-config-examples/` 面向轨迹数据集批量生产；`hermes sessions export --format trace --upload` 把会话发布为 Hugging Face Agent Trace 数据集（默认私有、强制脱敏）。证据：主链确认（保存/压缩）/ 入口确认（批量与数据集）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[对话导出与分享调查笔记](../对话导出与分享/Hermes-Agent-对话导出与分享调查笔记.md)。
- **跨会话检索（session_search）**：FTS5 + 会话谱系去重 + 锚定窗口，属于闭环学习"搜索自己过去对话"的组成件，已并入学习闭环描述；同时是 `_AGENT_LOOP_TOOLS` 四个 agent-level 工具之一。证据：主链确认（静态证据）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。
- **会话心跳（`/heartbeat`，候选能力）**：会话级重复重入指令（如 `/heartbeat every 10m <prompt>`），到期且会话空闲时作为普通用户回合注入，忙碌时合并 tick、空闲后只补一次；状态持久化在会话数据库，`/resume` 可拾取；与 cron 分工明确（cron 是隔离会话的调度任务，heartbeat 是持续重入当前会话）。证据：主链确认（静态证据）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **目标质量门（`/goal`，候选能力）**：目标循环每次"可能完成"时用 judge 复查，并可配置确定性命令质量门，通过后才允许目标完成；续接提示只是普通用户消息，真实用户消息可抢占。证据：主链确认（静态证据）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **终端后端（7 类）**：已归并到 Agent 工具类目（`tools/environments/` 下 local/ssh/docker/singularity/modal/daytona/vercel_sandbox 等，容器资源上限、execute_code 沙箱、容器风险豁免）。状态：归并已有类目。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **cron 定时任务**：已归并到既有类目（3 分钟硬中断、补跑窗口、文件锁防并发、cron 会话关闭记忆写入）。状态：归并已有类目。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **verify-on-stop**：已归并到 Agent 工具类目（回合终止前对候选回复跑 run-recipe 检测与验证）。状态：归并已有类目。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **委派 / 子 Agent、MCP、插件体系、人格系统**：已归并到 Agent 工具与 Agent 角色类目，本汇总不重写。状态：归并已有类目。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。

## 工程与基础设施摘要

**仓库分布**

- **仓库形态与规模**：运行面和配套资产最广的混合 monorepo，Python Agent / CLI / gateway / tools 与 TypeScript 桌面、Web、TUI 同仓，还包含 skills、插件和文档站。Git 跟踪文件 8,748；可识别源码 6,270 文件 / 2,094,425 行；文档 1,528 文件；测试 3,604 文件 / 821,783 源码行（约占全仓可识别源码 39.2%）。证据：Git 跟踪文件机械统计 + 源码复核（静态）。链接：[仓库分布调查笔记](../仓库分布/Hermes-Agent-仓库分布调查笔记.md)。
- **语言与产品区域**：Python 1,567,851 行（74.9%）、TypeScript 461,514 行（22.0%）；产品区域以 `apps/desktop`（1,561 文件 / 324,484 行）、`hermes_cli`（196,956 行）、`agent`（114,650 行）、`tools`（112,750 行）为主。证据：静态统计。链接：[仓库分布调查笔记](../仓库分布/Hermes-Agent-仓库分布调查笔记.md)。
- **跨平台与入口组织**：README 明确区分 Linux/macOS/WSL2、原生 Windows 与 Android/Termux 安装；npm workspace 把 apps/ui-tui/web/tests-js 组织为独立成员；桌面壳、Web 和 TUI 是独立入口，共享 Agent/gateway 协议而非一个响应式 UI。证据：静态确认。链接：[仓库分布调查笔记](../仓库分布/Hermes-Agent-仓库分布调查笔记.md)。

**应用界面基础设施**

- **三套界面与共享协议**：Electron 桌面、Ink TUI、Web dashboard 三端不共享组件实现，但共享后端皮肤协议（`~/.hermes/skins/*.yaml`）与通知协议（notification.show），并采用"从种子值派生语义 token"的主题思路；唯一共享代码是 `apps/shared` 连接层。证据：静态源码阅读确认。链接：[应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)。
- **桌面端装配与公共设施**：应用根是贡献注册表驱动的 ContribController，pane / 标题栏 / 快捷键 / 命令面板 / 路由 / 主题全部走同一 area 注册 API，核心与插件同权、插件崩溃按 slot 降级；弹窗基于 Radix，提供专门的 Portal 容器解决弹窗内 Popover 的层级问题；Toast 双栈 + 后端 notice 映射；命令面板 ⌘K 为 Radix Dialog + cmdk 自研排序；多窗口（HUD/旁窗/quick/wake）与多 profile 独立二级 socket。证据：静态源码阅读确认（视觉未运行验证）。链接：[应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)。
- **TUI 与 Web 的界面组织**：TUI 以单一 overlayStore 管理流内提示、浮层面板与 widget 模态三类形态，渲染用 Ink fork；Web dashboard 组件来自 `@nous-research/ui`，主题/Profile/SystemActions 走 context，PTY 嵌入真实 TUI。证据：静态源码阅读确认。链接：[应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)。
- **主题体系（三端不同权威源）**：三端主题哲学是"少量种子色 → 派生全部次级 token"（桌面 `--theme-*` → `--ui-*` color-mix、TUI mix 阶梯、Web palette 分层），但权威源各异——桌面按 profile 存于 localStorage、TUI 使用启动缓存和环境检测、Web 以服务端为权威；桌面另有完整 VS Code 主题市场链路（Gallery 查询、VSIX 下载、用户主题注册表），accent 设 WCAG AA 对比护栏。证据：静态源码阅读确认（视觉未运行验证）。链接：[应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)。

## 已知边界与待验证事项

### 声明不符

- README "the only agent with a built-in learning loop" 的强度超出可验证范围，但学习闭环本体在快照中有完整实现（按实现事实记录，不背书宣传强度）。来源：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- agentskills.io 兼容为 README 声明，协议细节未核验。来源：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。

### 暂缓与外部依赖

- 暂缓：0 项。
- Tool Gateway（入口确认未闭合）：统一路由 Nous 托管后端（firecrawl 搜索、fal-queue 图像、openai-audio TTS/转写、modal 沙箱）的入口与 entitlements 门控已确认，完整凭据/订阅流未验证，依赖外部订阅。来源：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- 全局紧急停止 `hermes pause` / `resume`（入口确认）：跨会话全局停止位属安全/可靠性机制，不进入用户可见产品特性统计。来源：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- Honcho 用户建模（入口确认）：dialectic 多轮推理与持久结论在外部 Honcho 服务实现，本仓库只含接入链，建模质量与数据驻留未验证。来源：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- 七终端后端中的 serverless 休眠唤醒（入口确认/外部依赖）：Modal/Daytona 的休眠-唤醒语义依赖外部服务，本仓库只验证到环境适配器层。来源：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。

### 未覆盖类目

- 消息平台 gateway 20+ 平台（telegram/discord/whatsapp/slack/钉钉/企业微信/微信/飞书等）为入口确认，安装、endpoint 映射、线程回复与权限未逐 adapter 调查。来源：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/Hermes-Agent-外部执行体与应用协作调查笔记.md)。
- relay connector 为实验性托管 gateway 形态，由外部 connector 拨号接入，标候选观察。来源：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/Hermes-Agent-外部执行体与应用协作调查笔记.md)。
- E3 图片分享与 E4 对话链接分享：本次未找到（检索范围见来源笔记）。来源：[对话导出与分享调查笔记](../对话导出与分享/Hermes-Agent-对话导出与分享调查笔记.md)。
- artifact 注册表对模型不可见：无列出 artifact、读取版本源码、选择版本的模型侧通道；`[Preview: …]` 协议只有消费端、无生产端；无 notebook / 画布 / 白板运行时。来源：[生成式输出与运行时调查笔记](../生成式输出与运行时/Hermes-Agent-生成式输出与运行时调查笔记.md)。
- 检索与记忆：本仓未找到内置文档摄取、切块、Embedding 和向量库主链，也未找到召回结果自动驱动下一阶段查询的宿主协议；外部 MemoryProvider 的检索质量、索引结构、数据驻留和自动演化不在本仓已确认范围。来源：[检索增强与认知编排调查笔记](../检索增强与认知编排/Hermes-Agent-检索增强与认知编排调查笔记.md)。
- `display_type` 参数全树 grep 零命中。来源：[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)。
- Web 端、cron/kanban/插件体系为 Chat 笔记声明的范围排除项，未纳入本次汇总。来源：[Chat 调查笔记](../Chat/Hermes-Agent-Chat调查笔记.md)。

### 共性未验证

- 全部 14 篇来源笔记均为静态源码阅读，未运行应用、测试或真实模型请求；均已对齐代码快照 `791e2ae3257e211d14ca77e654dfe10ee1976a1c`，快照之外的历史未纳入。
- 未运行验证：运行行为（视觉效果、时序、性能、真实 Provider 流式）、多客户端/多窗口并发、键盘与无障碍、FTS 实际布局、崩溃重放端到端、后台复习 fork 成本、HF 轨迹上传实际行为、VS Code 市场端到端链路。
- 设置页连接测试与真实聊天链路走不同代码路径，测试通过不等于真实可用（已确认的工程边界）。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Hermes-Agent-LLM渠道管理调查笔记.md)。
- 与特色贡献统计的衔接：独特功能笔记建议新增主贡献候选（闭环学习、Skill 生命周期、研究数据工具链、会话心跳 + 目标质量门）与辅助贡献（持久记忆与用户建模），相关归并口径见[特色功能贡献统计](../AI客户端特色功能贡献统计.md)。

## 来源笔记索引

- [Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)：工具来源与注册、发现与注入、执行编排与并发、审批与执行边界、结果回注、MCP/插件/Skill/子代理、Agent Plugins 便携包。
- [Agent 角色调查笔记](../Agent角色/Hermes-Agent-Agent角色配置调查笔记.md)：分层角色机制、SOUL/personalities/system prompt 拼装、模型/工具/记忆绑定、导入导出、配置 UI 与运行时可见性。
- [Chat 调查笔记](../Chat/Hermes-Agent-Chat调查笔记.md)：跨界面端到端聊天主链、核心对象与状态权威、编辑/中断/崩溃安全、压缩触发、搜索与标题机制。
- [Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)：桌面工作台页面结构、会话列表与搜索、Composer/草稿/附件、发送与流式反馈、消息操作与分支、状态所有权、键盘与响应式。
- [LLM 渠道管理调查笔记](../LLM渠道管理/Hermes-Agent-LLM渠道管理调查笔记.md)：Provider/端点/凭据概念模型、配置与各平台管理入口、凭据与脱敏、模型目录、transport 适配、运行时解析、多 Key/重试/故障转移、连接检测与可观测性。
- [仓库分布调查笔记](../仓库分布/Hermes-Agent-仓库分布调查笔记.md)：仓库形态与量级、语言分工、文档/测试分布、跨平台与入口组织。
- [会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)：会话/消息/分支数据模型、事实源与持久化、生命周期、编辑重试分支、列表分页搜索、一致性、标题机制、Agent/模型/附件绑定。
- [外部执行体与应用协作调查笔记](../外部执行体与应用协作/Hermes-Agent-外部执行体与应用协作调查笔记.md)：多表面控制（桌面/TUI/Web/ACP/REST/消息平台）、身份与协议映射、执行与回流控制语义、权限与治理边界。
- [对话导出与分享调查笔记](../对话导出与分享/Hermes-Agent-对话导出与分享调查笔记.md)：/save 快照、sessions export 多格式、导入往返、内容口径、隐私安全、分享载体与访问控制。
- [对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)：提交入口与任务状态机、上下文拼装、预算与压缩、Provider 交接、流式事件、完成/中断/重试/续写、队列与后台生成。
- [应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)：应用装配、弹窗浮层、通知反馈、主题 token、响应式、桌面集成与浮层细节。
- [消息渲染器调查笔记](../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md)：四套渲染面、输入模型、流式链路、列表窗口化、Markdown/代码/富文本管线、HTML 与安全隔离、性能策略与扩展方式。
- [独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)：闭环学习、Skill 生命周期、持久记忆与用户建模、研究数据工具链四项能力卡，以及 Tool Gateway、heartbeat/goal/estop 候选与归并项盘点（入口确认与候选明细见"已知边界与待验证事项"）。
- [生成式输出与运行时调查笔记](../生成式输出与运行时/Hermes-Agent-生成式输出与运行时调查笔记.md)：artifact 检测/预览/版本化、MEDIA 协议、模型回流、对象模型、执行环境与安全隔离、持久化与恢复。
- [检索增强与认知编排调查笔记](../检索增强与认知编排/Hermes-Agent-检索增强与认知编排调查笔记.md)：内置与外部记忆、跨会话 FTS5 检索、写回、注入、预算与恢复边界。

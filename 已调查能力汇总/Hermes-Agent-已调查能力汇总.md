# Hermes-Agent 已调查能力汇总

> 汇总对象：`Hermes-Agent`（远端仓库 `https://github.com/NousResearch/hermes-agent`，产品命令 `hermes`）
>
> 汇总更新日期：2026-11-05
>
> 依据：Agent 工具、Agent 角色、Chat、Chat UI、LLM 渠道管理、仓库分布、会话与消息管理、主动Agent与后台任务、外部执行体与应用协作、对话导出与分享、对话请求与上下文、应用界面基础设施、消息渲染器、独特功能、生成式输出与运行时、检索增强与认知编排共 16 个类目的 Hermes-Agent 调查笔记（完整清单见文末来源笔记索引），基于代码快照 `71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 汇总方法：阅读各来源笔记的结论摘要与关键章节，按功能主题合并重复能力，保留证据状态并链接来源；定向源码复核覆盖规范桌面 owner、输入受理与重启、cron 交接恢复与投递、预览工具生产消费链，其余沿用来源证据；未运行应用与模型请求
>
> 汇总范围：上述 16 个类目的既有调查结论；仓库分布与应用界面基础设施两个工程向类目单列于"工程与基础设施摘要"小节；排除跨项目横向比较、评分与排序
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

Hermes Agent 在 CLI、TUI、桌面、Web 与消息网关之间复用同一套 Python agent 核心，是一个可跨这些前端使用的个人 AI 助手；README 将其定位为 "self-improving agent"，核心卖点是内置的学习闭环。仓库是混合 monorepo：Python 核心含 run_agent、cli、gateway 与 tools 四个模块，TypeScript 前端含 Electron 桌面、Ink TUI 与 Web dashboard，两者同仓。桌面端通过 gateway ensure 附着或启动规范本地 owner，renderer 经私有端点与 WebSocket JSON-RPC 通信，关闭桌面只断开 viewer；后端 SQLite 是会话与消息的唯一真相源，各前端只是缓存投影。当前快照约 2.2 万个受版本控制文件：agent、hermes_cli、gateway 与 cron 已完成模块化拆分，单个 `hermes_state.py` 拆成约 65 个 `hermes_state_*` 模块；`plugin-catalog/` 的 SHA 固定插件清单从 99 条增长到 978 条，核心 `plugins/` 有 24 个条目，其中 computer_use 负责计算机操作，delegation 负责子代理委派，teams_pipeline 与 kanban 分别覆盖团队流水线与看板；终端后端为六个内建加插件后端。本次汇总覆盖 16 个类目，证据全部来自静态源码阅读，未运行应用、测试与真实模型请求。

## 完成度速览

功能摘要以“主链确认”“静态源码确认”“入口确认”和“归并已有类目”区分证据成熟度。协议契约、同一能力的新增控制面和工程统计不重复计为独立产品能力；声明不符、外部依赖、已回退实现和候选观察也不混入功能能力正文，集中在文末“已知边界与待验证事项”。

**证据口径**：本汇总的“主链确认/静态源码确认”表示已在当前代码快照 `71736c9f32597bbca9d89cede5aa136e55946b2f` 复查入口、状态、执行与结果处理构成的实现路径。“未运行验证”只保留需要在目标环境观察的 UI、端到端、时序与外部依赖表现，不使实现结论失效。能力条目中的“默认关闭/依赖外部服务/依赖用户配置”等边界均来自来源笔记的明确表述。

## 功能能力摘要

当前快照中，JSON-RPC 方法、请求与事件由 Python Pydantic 契约生成 TypeScript/OpenRPC；客户端重连以每会话事件序号补取缺口，桌面端以 connection + profile 路由同 ID 会话。默认上下文压缩保留 10K--25K token 的 lean tail，`execute_code` 使用会话持久内核；Provider 可从已启用的 pip entry point 发现，浏览器真实档案、加密 Vault、Connector 与终端环境后端分别受用户同意、服务端秘密边界和插件注册约束。

### 角色与上下文

- **分层角色机制**：角色没有独立的配置对象，由多个互补的提示词机制按"身份 → 命名模板 → 全局/会话覆盖 → 运行时注入"的顺序分层叠加，下层提供默认值，上层按需覆盖：

  - 身份：`$HERMES_HOME/SOUL.md` 是主身份文件，文件缺失时回退到硬编码的 `DEFAULT_AGENT_IDENTITY`。
  - 命名模板：personalities 提供具名模板（内置 14 个），用户可按名覆盖。
  - 全局覆盖：`agent.system_prompt` 供用户手动 overlay，人格代码永不写入。
  - 选中名：`display.personality` 保存选中的模板名，并成为权威来源。
  - 渠道覆盖：`ChannelOverride` 在渠道级覆盖。
  - 隔离包：Profile 把上述配置构成完整隔离单元。

  人格文本经 ephemeral system prompt 在运行时追加，不进缓存，也不进轨迹。证据：主链确认（静态源码阅读）。链接：[Agent 角色调查笔记](../Agent角色/Hermes-Agent-Agent角色配置调查笔记.md)、[Chat 调查笔记](../Chat/Hermes-Agent-Chat调查笔记.md)。
- **系统提示词三层拼装与缓存**：`build_system_prompt_parts` 把系统提示词拆成三档，每会话只构建一次并缓存，仅在上下文压缩时重建：

  - stable：身份与指引，字节稳定以保住前缀缓存；
  - context：与工作目录相关，承载上下文文件；
  - volatile：技能索引、记忆与时间戳。

  完整构建结果写入 `system_prompts` hash 去重表，会话行引用 model/model_config 快照。证据：静态源码阅读确认（未运行）。链接：[Agent 角色调查笔记](../Agent角色/Hermes-Agent-Agent角色配置调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)。
- **上下文构建、预算与压缩**：`build_turn_context` 用约 30 个动作分组组装本轮上下文，覆盖恢复轮转会话、刷新 MCP 工具、恢复系统提示词、确保 DB 行、检查压缩、执行插件钩子、预取记忆、注入 sidecar 与崩溃持久化。压缩由三套机制叠加完成，没有 token 级截断原语：preflight 多 pass（至多 3 轮，要求行数减少或 token 降幅超过 5%）、idle 压缩（以墙上时间为门）、服务端 native compaction（gpt-5.6）。`prompt_cache_boundary` 注册表声明 stable 与 volatile 的缓存边界断点；轮转压缩生成新的 session_key 并连成血缘链，原地压缩在同一 ID 上软归档。证据：静态源码阅读确认（未运行）。链接：[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。
- **会话级绑定与覆盖优先级**：模型、人格与提示词的绑定粒度都在会话级，`model_override` 等字段按会话保存；模型优先级按"会话 > 渠道 > 全局"解析，运行中用 `/model` 切换会以 `model_switch` 时间线条目写入历史，且不计入 user 轮计数。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[Agent 角色调查笔记](../Agent角色/Hermes-Agent-Agent角色配置调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)。

- **记忆与跨会话检索的三条路径**：内置 `MEMORY.md`/`USER.md` 在下一会话以冻结快照进入系统提示词；可选外部 MemoryProvider 在每轮用户消息前预取上下文并附加到该轮 API sidecar，完成回合后异步写回；`session_search` 则以 SQLite FTS5 搜索会话并返回命中锚点窗口，支持时间边界、整条 lineage 排除和无命中时的 OR 放宽提示。三者均不是统一文档知识库或固定多阶段认知编排。证据：静态源码确认（未运行）。来源：[检索增强与认知编排调查笔记](../检索增强与认知编排/Hermes-Agent-检索增强与认知编排调查笔记.md)。

### 会话与消息

- **状态权威与双 ID 身份**：会话与消息以 SQLite `state.db` 为唯一事实源，进程内的 UI 句柄 sid 与持久化的 `session_key` 分开保存。压缩轮转时，新会话通过 `parent_session_id` 指向父会话，父会话写入结束时间与 compression 结束原因，由此连成轮转链；跨轮转不变的稳定标识是由此派生的只读字段 `_lineage_root_id`，桌面端的 pin、路由匹配与草稿作用域都以它为键。证据：主链确认（静态）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[Chat 调查笔记](../Chat/Hermes-Agent-Chat调查笔记.md)。
- **会话生命周期与崩溃恢复**：会话行按需创建，首次真实 turn 才落库，空草稿不留痕。resume 沿压缩链跳到活 tip；close 只标记 `ended_at/end_reason`，不删数据；归档以 `archived=1` 软隐藏，硬删除没有回收站。规范网关的输入先持久受理再执行，同一身份与 payload 的重试返回原回执，payload 变更则报冲突；owner 重启会把已开始的输入置为 unknown 并暂停后续队列，legacy tui_gateway 另有一套中断标记恢复。子代理是真实会话，带 `_delegate_from` 标记，删除时沿标记级联。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)。
- **消息数据模型与持久化**：`messages` 表一行一条消息，内容字段为 role、content、tool_calls 与 reasoning，另有四个字段决定消息如何保留与回放：

  - `active`：软删除标记；
  - `compacted`：压缩归档标记，归档后仍可搜索；
  - `display_kind`：该行的展示类型；
  - `api_content`：发往 API 的字节保真 sidecar，恢复时原样返回。

  落盘采用"单事务批量 + 内存 marker 去重"的原子配对契约，提交与工具进展都能留下持久记录，增量 flush 用于应对工具杀死进程的场景。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。
- **编辑、重试、续写与分支**：编辑以"截断 + 重发"实现，提交截断需要显式 `confirm_truncate`，没有单消息原地编辑或删除的 RPC。三套重试实现共享同一语义：截断到最后一个真实 user turn 后重发；续写没有独立命令，发送普通 prompt 文本 "continue" 即可。分支由 `session.branch` 建立新 session_key 并加 `_branched_from` 标记，标题追加 `#N`；截断重发带归档语义，旧轮次落盘为可搜索的归档行。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)。
- **标题机制（两段式 + 带来源）**：会话首个 turn 的 prologue 即得 derived 即时标题（确定性派生、无模型调用），后台线程用小模型升级为 llm 标题；标题带 provenance（derived < llm < user），`set_auto_title` 单事务 compare-and-swap 防自动覆盖，用户 `/title` 永不被覆盖；压缩轮转携带标题与 provenance 不变。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。
- **列表、分页与搜索**：会话列表由 `list_sessions_rich` 用一次查询完成预览拼接、置顶回填、按压缩链 tip 的最近活跃排序与逻辑去重；REST 接口按 limit/offset 分页，侧栏按 profile 分片翻页。消息搜索走 FTS 四路矩阵，依次是 unicode61 基表、CJK bigram、trigram 与 LIKE 兜底；其中 trigram 会跳过 `role='tool'` 行，这类行约 90% 字节是机器噪声。跨会话检索由 `session_search` 承担，带谱系去重与锚定窗口。证据：静态源码阅读确认（未运行）。链接：[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **对话导出与导入**：两条按需快照路径与一条结构化导出子系统，支持 jsonl / md / qmd / html / trace；结构化导出附带由消息时间戳派生、明确标为不完整的文本无关 timing evidence。JSONL 可往返导入，桌面还可只读发现 Claude Code/Codex CLI 会话并作为不可信静态历史导入，不继承凭据、审批或活动工具。E3 图片分享与 E4 对话链接分享未覆盖。证据：静态源码调查确认（未运行）。链接：[对话导出与分享调查笔记](../对话导出与分享/Hermes-Agent-对话导出与分享调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。

### 生成与创作

- **生成式输出与 Artifact（能力等级 G3）**：桌面渲染器对模型输出流中的代码围栏做事后启发式检测，按 html、svg 与代码等四类的体积和行数门槛判断，并用散文排除与语言黑名单避免误触发；围栏收尾后注册为 artifact 卡片。HTML 运行在带 `sandbox="allow-scripts"` 的 iframe 中，URL 类内容运行在沙箱 webview 中，注册表按版本记录、只驻留内存，以聊天记录为事实源。模型通过 desktop_preview 的 open、close、read 动作操作并读取会话作用域的预览，也能读取终端与磁盘文件。artifact 不能被模型寻址，也不能由用户编辑，没有 notebook、画布或白板形态，细节见末尾小节。证据：主链确认（静态走通）。链接：[生成式输出与运行时调查笔记](../生成式输出与运行时/Hermes-Agent-生成式输出与运行时调查笔记.md)。
- **MEDIA: 媒体输出协议**：模型与工具可通过 `MEDIA:` 加绝对路径这一纯文本标记向平台交付媒体，消息平台把它拦截为原生附件，桌面渲染器把该标记行改写为媒体链接并渲染播放器。递送前先解析路径并确认文件存在；缓存根与操作者白名单根内的文件直接放行。根外文件在默认模式下按拒绝路径表检查；严格模式还要求处于配置的新鲜度窗口内，默认 10 分钟。图像附件另有 sub-2MP 默认 upscale 后处理。证据：静态源码确认（未运行）。链接：[生成式输出与运行时调查笔记](../生成式输出与运行时/Hermes-Agent-生成式输出与运行时调查笔记.md)。
- **消息渲染体系**：四套渲染面共享同一 `tui_gateway` 后端，各自的实现不同：TUI 用自研的 `markdown.tsx` 行状态机解析 Markdown，不依赖第三方库；桌面用 Streamdown 配合 Shiki 与 KaTeX；Web 只做极简辅助渲染；经典 CLI 与 gateway 仅记录边界。流式渲染采用先缓冲后分段的模型：`message.delta` 先累积到 streaming 状态对象，收到 `message.complete` 后定稿并去重。列表层 TUI 自建虚拟化，桌面则用渲染预算配合 `content-visibility`。安全侧有链接协议白名单与 iframe sandbox 隔离，`dangerouslySetInnerHTML` 只用于 3 处 SVG 片段与 artifact 预览。证据：静态源码阅读确认（DOM/视觉未运行验证）。链接：[消息渲染器调查笔记](../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)。
- **Composer 与输入（草稿、附件、发送配置）**：草稿按会话持久化在 localStorage，上限 50 条、只存文本，跨窗口靠 storage 事件同步，压缩轮转时随 tip 迁移，附件只驻留内存、不落盘。拖放附件按来源分流：应用内路径转成内联 `@file:` 引用，OS 文件进附件管线，目录转成 `@folder:`，图片转成 base64 缩略图。斜杠命令在客户端侧编目与派发；发送调用 `prompt.submit`，带 1800s 超时、busy 门控、storedId 与 runtimeId 的配对校验，以及会话切换时的 drift 守卫。证据：静态源码阅读确认（未运行）。链接：[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)、[对话请求与上下文调查笔记](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)。
- **语音会话**：桌面 Composer 同时支持传统 STT → Hermes → TTS 与 GPT-Live 全双工前端；实时音频引擎负责麦克风/扬声器和打断，真实任务仍连同近期文本上下文委托给当前 Hermes 会话，由当前模型与工具集执行。证据：静态源码阅读确认（WebRTC 与真实音频未运行）。链接：[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)、[应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)。

### Agent 运行时与外部协作

- **工具来源、注册与发现**：工具面汇总六类来源，最终都进入同一份工具定义：

  - 仓库 `tools/` 目录的工具在模块导入时自动注册；
  - `plugins/` 提供插件工具；
  - MCP 客户端在运行时动态发现；
  - skills 以指令文本的形式贡献工具；
  - Agent Plugins 便携包（v1 目录包兼容层）提供打包工具；
  - `toolsets.py` 按平台装配工具集。

  注册集中在 `tools/registry.py`，各工具在模块 import 时调用 `register()`；另有四个 agent-level 工具由 `_AGENT_LOOP_TOOLS` 拦截，不进入 registry。`get_tool_definitions` 负责白名单与黑名单过滤、动态 schema override，并在进程级记录 `_last_resolved_tool_names`。tools 数组在每次 API 调用时全量发送，prompt caching 只缓存 system prompt 前缀。证据：主链确认（静态源码阅读）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **工具执行编排与参数校验**：核心执行链沿 `run_agent.py`、`model_tools.py` 与 `tools/registry.py` 三层组织。模型回吐的 tool_calls 先按 id 去重、校验 name（近似名字会被修复），JSON 解析失败时最多重试 3 次。执行分单条、并发与分段三路，并发路径使用 DaemonThreadPoolExecutor 默认 8 线程，审批顺序由 `ConcurrentToolAuthorizationGate` 串行化。参数校验依赖 `coerce_tool_args` 与 `_normalize_json_strings_for_schema`，没有独立的 schema 强制校验器。结果回注为 tool 消息，并有三层持久化预算：per-tool、per-turn 与 preview 各有一份，超出限额时落盘并以 preview 加文件引用回填。证据：主链确认（静态源码阅读）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **审批、持久代码内核与执行边界**：CLI 交互审批是危险命令检查的一环，YOLO 模式可绕过整个审批门；`execute_code` 按稳定会话身份复用本地或远端 Python 内核，每个 cell 重新绑定当前工具权限，子 Agent 独立，超时/中断/会话关闭销毁内核。大输出溢写到文件；本地后端仍是本机进程和临时目录，容器类后端另有资源上限。证据：主链确认（静态源码阅读）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)、[生成式输出与运行时调查笔记](../生成式输出与运行时/Hermes-Agent-生成式输出与运行时调查笔记.md)。
- **MCP、插件、Skill 与便携包扩展**：插件由 `discover_plugins` 在加载时注册副作用，并提供五类 hooks；`resolve_pre_tool_block` 是每个工具分发点唯一的安全入口，任何错误都按 fail-closed 处理。MCP server 注册为 `mcp-<name>` 形式的 toolset，`tools/list_changed` 变化会动态触发 nuke-and-repave，trust-tier 门控分 full 与 untrusted 两档。Skill 以文本指令的形式生效，使用 Skill 不改变工具权限。Agent Plugins 便携包把其中的技能与 MCP 组件翻译进 Hermes 运行时。证据：静态源码阅读确认（未运行）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **子代理委派与实时控制**：`delegate_task` 创建占 DB 行的子会话，子会话拥有独立的 session 与 terminal，并支持结构化输出；当前会话还能按运行代际枚举 live roster、读取有界的 transcript tail，并对子 Agent 执行 steer 或 interrupt。已经结束、来自其他会话或代际失效的子 Agent 不再暴露内容。证据：静态源码阅读确认（未运行）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)。
- **外部执行体与控制面（多表面）**：桌面、TUI 与 Web 复用同一套 Python Agent、profile 数据库与 lineage；常规桌面本地路径连接规范网关，legacy tui_gateway 桥保留原有控制协议，两边方法名相同，受理与恢复契约需要分别看待。`acp_adapter/` 把 Hermes 作为 ACP agent 暴露给 VS Code、Zed、JetBrains 等外部宿主。REST API gateway 提供三类接口：

  - 补全与响应：`/v1/chat/completions`、`/v1/responses`；
  - 运行：`/v1/runs`，配合 SSE 订阅；
  - 会话管理与 cron。

  新客户端接入需经 DM Pairing 的一次性配对码授权，正在运行的 turn 可以被新客户端收养为 adopted running turn。消息平台 gateway 的 20+ 平台为入口确认，逐 adapter 细节见末尾小节。证据：主链确认（静态）/ 消息平台为入口确认。链接：[外部执行体与应用协作调查笔记](../外部执行体与应用协作/Hermes-Agent-外部执行体与应用协作调查笔记.md)、[Chat 调查笔记](../Chat/Hermes-Agent-Chat调查笔记.md)。
- **Connector 与 Vault 边界**：`manage_connections` 统一托管应用和 MCP 的安装、启用与授权，模型只收到后端 operation 终态，不接触授权链接；profile 本地 Vault 用 Fernet 保存登录、支付卡与地址，模型只见 opaque handle 和非秘密元数据，真实字段在服务端按 origin 填入浏览器。证据：静态源码阅读确认（未运行）。链接：[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)、[应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)。

### 渠道与调度

- **LLM 渠道与 Provider 管理**：Hermes 没有独立的"LLM 渠道"实体，Provider 由声明式 `ProviderProfile` 标识与凭据注册表构成，用户实例化的对象是 `providers:` 与 `custom_providers:` 下的一组端点参数：base_url、key_env 或 api_key、extra_headers；所谓"渠道"即 Provider 标识、一个 base_url 与一份凭据的组合。模型目录分静态表、远端拉取与用户输入三层；协议适配集中在 `agent/transports/`，按 api_mode 注册分发，覆盖 OpenAI 兼容、Anthropic、Responses 与 Bedrock。运行时由 `resolve_runtime_provider` 产出运行时 dict。管理入口在三端并不对称：Desktop 的自定义端点页支持完整 CRUD，CLI、TUI 与 Web 主要管理凭据、模型选择或整个 Profile，本次未找到同等粒度的端点 CRUD 页面。证据：静态源码阅读确认（未运行）。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/Hermes-Agent-LLM渠道管理调查笔记.md)。
- **重试、Key 轮换与故障转移**：重试与恢复按层次自内向外叠加：SDK 内建重试、应用层重试、同一 Provider 多 Key 的 credential pool 轮换、跨渠道 fallback 链，最后由会话层恢复主通道。连续编号的环境变量（如 `KEY_2`、`KEY_3`）可以直接播种 Key 池，秘密本身留在环境或 secret manager，`auth.json` 只存引用；发现过程在第一个编号缺口处终止。fallback 重发存在重复计费可能（推断）；设置页探活验证的是凭据与端点连通，聊天可用性由请求链决定。证据：静态源码阅读确认。链接：[LLM 渠道管理调查笔记](../LLM渠道管理/Hermes-Agent-LLM渠道管理调查笔记.md)。

### 独特与差异化能力

以下能力卡保留[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)的能力卡标题与证据状态。四项主能力卡均达主链确认（静态证据）；共同前提是"prompt caching is sacred"——后台机制继承主会话运行时与提示缓存、对主对话零干扰。入口确认未闭合的候选（Tool Gateway、全局紧急停止）与声明/外部依赖边界不在此列，集中在文末"已知边界与待验证事项"。

- **能力一：闭环学习（后台记忆/技能复习 + /refine）**：主会话每积累 N 轮对话或 N 次工具迭代，就触发一次后台 fork 复习；fork 继承父会话的模型配置、凭据与已缓存的系统提示，因此命中同一份提示缓存。后台复习只放行 memory 与 skill_manage 两个工具（由线程级白名单控制），复习结果写入 MEMORY.md、技能目录或外部 provider。`/refine` 是用户显式触发同一 fork 的按需入口；复习失败只做捕获、不向外抛出，按 best-effort 处理。证据：主链确认（静态证据）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **能力二：Skill 生命周期（创建-使用中改进-curator 维护）**：`skill_manage` 对模型暴露以 `operations` 批次提交的原子操作，单批最多 20 项，任一项失败则整批回滚；delete 必须独占调用，旧的平铺动作只用于历史重放。使用统计记录在 `.usage.json` 中；curator 采用惰性维护，只归档技能、不执行删除。证据：主链确认（静态证据）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)。
- **能力三：持久记忆与用户建模**：记忆分两轨：内置的 `MEMORY.md` 与 `USER.md` 文件记忆注入 system prompt 的 volatile 段；外部后端通过 `MemoryProvider` ABC 接入，仓库内置 byterover 与 retaindb，Honcho、Mem0 等经 plugin-catalog 安装，同一时刻至多激活一个。模型写记忆可能被人审的写审批门拦下，用户执行 `/memory approve` 之后才落盘。跨会话用户建模的 dialectic 多轮推理由 Honcho 承担，本仓库只含接入链（建模质量见末尾小节）。证据：主链确认（内置）/ 入口确认（外部 provider）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[Agent 角色调查笔记](../Agent角色/Hermes-Agent-Agent角色配置调查笔记.md)。
- **能力四：研究数据工具链（会话轨迹生产）**：打开 `save_trajectories` 开关（默认关闭）后，每轮会话按 ShareGPT 格式追加为 JSONL，成功与失败分别成文件；`trajectory_compressor.py` 保留首尾、只压缩中间段并替换为摘要。批量生产由 `batch_runner.py`、`mini_swe_runner.py` 与 `datagen-config-examples/` 一套配套组件承担。`hermes sessions export --format trace --upload` 把会话发布为 Hugging Face Agent Trace 数据集，默认私有并强制脱敏。证据：主链确认（保存/压缩）/ 入口确认（批量与数据集）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[对话导出与分享调查笔记](../对话导出与分享/Hermes-Agent-对话导出与分享调查笔记.md)。
- **跨会话检索（session_search）**：FTS5 + 会话谱系去重 + 锚定窗口，属于闭环学习"搜索自己过去对话"的组成件，已并入学习闭环描述；同时是 `_AGENT_LOOP_TOOLS` 四个 agent-level 工具之一。证据：主链确认（静态证据）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)、[Agent 工具调查笔记](../Agent工具/Hermes-Agent-Agent工具调查笔记.md)、[会话与消息管理调查笔记](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)。
- **会话心跳（`/heartbeat`，候选能力）**：会话级重复重入指令到期且空闲时作为普通用户回合注入，忙碌时合并 tick；状态持久化在会话数据库。它与创建独立会话、执行账本和交付目标的 cron 分型不同。证据：主链确认（静态证据）。链接：[主动 Agent 与后台任务调查笔记](../主动Agent与后台任务/Hermes-Agent-主动Agent与后台任务调查笔记.md)、[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **目标质量门（`/goal`，候选能力）**：目标循环每次"可能完成"时用 judge 复查，并可配置确定性命令质量门，通过后才允许目标完成；续接提示只是普通用户消息，真实用户消息可抢占。证据：主链确认（静态证据）。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **终端后端（6 类内建 + 插件后端）**：已归并到 Agent 工具类目：`tools/environments/` 下提供 local、ssh、docker、modal、daytona 与 vercel_sandbox 六种后端，Singularity 与 Apptainer 由插件提供；容器资源上限、execute_code 沙箱与容器风险豁免一并归在该类目。状态：归并已有类目。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **cron 定时任务**：profile 范围的 job、execution、输出与认领协议形成隔离日程运行；预推进后尚未取得 fire claim 的 pending_slot 可恢复一次，已认领运行避免盲目重放。headless tick 无 ready 网关时保留到期 Agent job、拒绝隐式启动 daemon。成功交付可按目标与开关镜像或播种为可继续会话，执行会话仍独立；暂停阻止新派发，取消进入 Agent/脚本路径。循环 job 若在零模型 API 调用阶段因网络/DNS 失败，可按 5/15/30 分钟有限重排；一次性任务或已可能产生副作用的失败不重跑。证据：主链确认（静态证据）。链接：[主动 Agent 与后台任务调查笔记](../主动Agent与后台任务/Hermes-Agent-主动Agent与后台任务调查笔记.md)。
- **verify-on-stop**：已归并到 Agent 工具类目（回合终止前对候选回复跑 run-recipe 检测与验证）。状态：归并已有类目。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- **委派 / 子 Agent、MCP、插件体系、人格系统**：已归并到 Agent 工具与 Agent 角色类目，本汇总不重写。状态：归并已有类目。链接：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。

## 工程与基础设施摘要

**仓库分布**

- **仓库形态与规模**：仓库是混合 monorepo，Python 侧包含 Agent、CLI、gateway 与 tools，TypeScript 侧包含桌面、Web 与 TUI，另有 skills、插件与文档站。Git 跟踪文件 13,516 个，可识别源码 9,948 个文件、共 2,739,531 行；文档 1,673 个文件；测试 5,812 个文件、共 1,381,872 源码行，约占全仓可识别源码的 50.4%。证据：Git 跟踪文件机械统计 + 源码复核（静态）。链接：[仓库分布调查笔记](../仓库分布/Hermes-Agent-仓库分布调查笔记.md)。
- **语言与产品区域**：Python 1,899,875 行，占 69.4%；TypeScript 752,790 行，占 27.5%。产品区域集中在四个目录：

  - `apps/desktop`：2,639 个文件，596,485 行；
  - `hermes_cli`：370 个文件，187,370 行；
  - `agent`：224 个文件，100,446 行；
  - `tools`：257 个文件，94,028 行。

  证据：静态统计。链接：[仓库分布调查笔记](../仓库分布/Hermes-Agent-仓库分布调查笔记.md)。
- **跨平台与入口组织**：README 明确区分 Linux/macOS/WSL2、原生 Windows 与 Android/Termux 的安装方式；npm workspace 把 apps/ui-tui、web 与 tests-js 组织为独立成员；桌面壳、Web 与 TUI 是三个独立入口，共享 Agent 与 gateway 协议。证据：静态确认。链接：[仓库分布调查笔记](../仓库分布/Hermes-Agent-仓库分布调查笔记.md)。

**应用界面基础设施**

- **三套界面与共享协议**：Electron 桌面、Ink TUI、Web dashboard 三端不共享组件实现，但共享后端皮肤/通知协议和由 Python Pydantic 契约生成的 JSON-RPC TypeScript/OpenRPC 描述；共享代码集中在 `apps/shared` 连接与协议层。证据：静态源码阅读确认。链接：[应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)、[Chat 调查笔记](../Chat/Hermes-Agent-Chat调查笔记.md)。
- **桌面端装配与公共设施**：应用根是贡献注册表驱动的 ContribController，pane / 标题栏 / 快捷键 / 命令面板 / 路由 / 主题全部走同一 area 注册 API，核心与插件同权、插件崩溃按 slot 降级；弹窗基于 Radix，提供专门的 Portal 容器解决弹窗内 Popover 的层级问题；Toast 双栈 + 后端 notice 映射；命令面板 ⌘K 为 Radix Dialog + cmdk 自研排序；多窗口（HUD/旁窗/quick/wake）与多 profile 独立二级 socket。证据：静态源码阅读确认（视觉未运行验证）。链接：[应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)、[Chat UI 调查笔记](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)。
- **TUI 与 Web 的界面组织**：TUI 以单一 overlayStore 管理流内提示、浮层面板与 widget 模态三类形态，渲染用 Ink fork；Web dashboard 组件来自 `@nous-research/ui`，主题/Profile/SystemActions 走 context，PTY 嵌入真实 TUI。证据：静态源码阅读确认。链接：[应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)。
- **主题体系（三端不同权威源）**：三端主题哲学是"少量种子色 → 派生全部次级 token"（桌面 `--theme-*` → `--ui-*` color-mix、TUI mix 阶梯、Web palette 分层），但权威源各异——桌面按 profile 存于 localStorage、TUI 使用启动缓存和环境检测、Web 以服务端为权威；桌面另有完整 VS Code 主题市场链路（Gallery 查询、VSIX 下载、用户主题注册表），accent 设 WCAG AA 对比护栏。证据：静态源码阅读确认（视觉未运行验证）。链接：[应用界面基础设施调查笔记](../应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md)。

## 已知边界与待验证事项

### 声明不符

- README "the only agent with a built-in learning loop" 的强度超出可验证范围，但学习闭环本体在快照中有完整实现（按实现事实记录，不背书宣传强度）。来源：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- agentskills.io 兼容为 README 声明，协议细节未核验。来源：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。
- Collective Wisdom V1 曾在 `a6ee31f55a` 引入，随后由 `0dcadf6f41` 明确整包回退；当前 HEAD 不含该 package、工具或 UI，因此不列为现行能力。来源：[独特功能调查笔记](../独特功能/Hermes-Agent-独特功能调查笔记.md)。

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

- 全部 16 篇来源笔记均为静态源码阅读，未运行应用、测试或真实模型请求；均已对齐代码快照 `71736c9f32597bbca9d89cede5aa136e55946b2f`，历史提交只用于确认当前实现的引入或回退来源。
- 本轮同步以路径级定向复核为主（模块归位、插件目录、后端数量、手工合并的插件准入），未逐行重读约 2.6 万提交范围的全部改动；前半组 7 篇由另一任务同步，行号引用统一按模块级定位。
- 未运行验证：运行行为（视觉效果、时序、性能、真实 Provider 流式）、多客户端/多窗口并发、键盘与无障碍、FTS 实际布局、崩溃重放端到端、后台复习 fork 成本、HF 轨迹上传实际行为、VS Code 市场端到端链路。
- 设置页连接测试与真实聊天链路走不同代码路径，测试覆盖的是连通性，真实可用性由聊天链路决定（已确认的工程边界）。来源：[LLM 渠道管理调查笔记](../LLM渠道管理/Hermes-Agent-LLM渠道管理调查笔记.md)。
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

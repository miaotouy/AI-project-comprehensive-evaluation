# DeepSeek-Harness 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`8bd073392eef6f54e921a093b95076248eb08cbb`（分支：`master`）
>
> 调查方式：静态源码阅读与全文检索，覆盖 `packages/llm`（llm、llm-retry、token-meter）、`packages/core`（session、agent-loop、tools）、`packages/session`（session-persistence 及 jsonl 后端、session-format 与 v0→v4 迁移链、session-projection、session-title、session-stats、session-telemetry、session-log-deepseek）、`packages/compaction`、`packages/attachment`、`packages/spill`、`packages/util/output-retention`、`packages/deliverables`、`packages/client`（runtime、ui-chat、ui-conversation 消费侧）及 `docs/subsystems` 对应页与 `docs/upgrade-guide`；未运行任何命令或测试
>
> 调查范围：流式词汇与折叠、输出事件落盘与持久化、v4 消息契约与工具结果表示、工具结果输出契约、终端/shell/附件/spill/消息反馈/交付物/令牌计量等输出形态、客户端流式消费概览；明确排除 Chat UI 的 DOM 渲染细节、工具管道的审批与调度语义、对话请求与上下文的装配细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek-Harness 是插件化 agent harness，输出链路以"会话事件日志"为核心。模型输出没有独立 artifact 对象：原始形态是闭合的 `StreamChunk` 流协议（起止块、文本/推理/工具调用三类 delta、usage 与 finish 变体，`packages/llm/llm/src/types.ts`），adapter 契约要求 usage 先于 finish、工具参数端到端保持原始 JSON 字符串、失败归一化为可序列化的失败事实。

流式折叠由 BlockAssembler 承担。实时 chunk 只作为临时 assistant stream 帧发布；尝试收口时，把紧凑原始流与 usage 内嵌进 assistant 消息。未产生表面消息的失败、重试或取消尝试另记 `assistant/attempt`，从而每次尝试都有耐久收口，重放无需独立 chunk 事件（`packages/core/agent-loop/src/agent.ts:482-582`）。

会话日志仍是唯一事实源，模型历史经表面折叠派生（`deriveMessages()`），日志同时支撑精确回放与请求可重建。

**格式 v4 改写了消息数据契约**：工具结果从包装在 user 角色里的内容块，变成角色为 tool 的独立消息——`toolCallId` 标记它对应哪次调用，内容字段直接是块数组，错误以可选的 `isError` 表示；消息来源由 plugin 字符串改为 kind 判别，插件扩展内容统一加 `plugin:<原名>` 前缀，并新增 `developer/message` 事件类型。v3 到 v4 是独立迁移包，恢复旧会话时执行转换，已存储的代保持原样（`packages/session/session-format-v3-to-v4/`）。

输出对象身份分四类：消息（稳定 `MessageId`）、工具调用/结果（`CallId` 配对）、磁盘文件（spill 文件、内容寻址附件、交付物引用）、运行实例（终端会话与后台 job，仅进程内存活，不进日志）。工具结果契约是"规范 JSON 值 + 纯投影渲染"：执行产生的 value 只在进程内存在，落盘的只有渲染后的内容、错误信息和展示 meta。

输出留存分执行流与结果副本两层：shell/subprocess 保留尾窗口及完整流地址；spill 策略按估算 token 计算文本和图像，保留有序 head/tail 及读取提示，完整文本和图像可读取路径另存为会话私有文件。持久化通过 write handle 的有界批处理与 `session/flush` 检查点完成；第一方只提供 JSONL。压缩侧拆出 `compaction-basic`、`compaction-image-offload`、`compaction-tool-result-pruner` 三个策略插件。

另有两条对外输出通道：`session-log-deepseek` 在启用官方 DeepSeek 请求元数据时把规范会话日志增量上传（`dsh_session_log` 请求字段加 `session-log-deepseek/delivery-accepted` 事件作为水位），`present` 工具把文件声明为交付物供客户端呈现。

能力总评 **G1（富静态结果）**：文本/推理/图片与工具卡片在消息内投影，文件产物可寻址复用（附件、spill、交付物）；终端 PTY 与后台 job 提供"模型可跨调用定向维护的活对象"（G5 的局部形态），但既不入日志也不持久化，进程终止即失。模型输出本身没有 G2 声明式控件、没有 G3 专用运行环境；用户不能编辑模型输出对象，无 diff 应用层与协作机制。

## 系统边界与完整主链路

边界按职责划分：

- `packages/llm/llm` 定义 provider 无关的流与消息词汇并归一化所有 adapter；
- `packages/core/session` 提供事件日志与表面派生，`packages/core/agent-loop` 是唯一循环消费者，`packages/core/tools` 提供工具注册与结果契约；
- `packages/session/*` 负责持久化、格式与迁移链、检查点、投影缓存、标题、统计与遥测；
- terminal/shell/subprocess/spill/attachment/compaction/deliverables/token-meter 分别提供输出形态与治理；
- 客户端经 Remote mux 订阅 journal、投影与临时流帧，在对象层重建会话视图。

主链路（模型流实时发布，尝试结束后耐久收口）：

1. 输入：用户消息先写入 inbox 并唤醒驱动器，turn 流程随即追加 `turn/start`；preStep 认领这条消息后追加 `user/message`。
2. 装配：buildRequest 追加请求头与请求上下文两条事件，请求头是含工具 schema 的 EpochHeader 全量快照；两条事件经 `llm.prepareCall` 绑定 adapter 注册，请求随之冻结。
3. 生成：循环消费模型流并折叠，实时发布起止与分块帧；adapter 错误与迭代错误统一归一化为终态失败事实。
4. 最终化：有表面输出时追加 assistant 消息，其余尝试记为 `assistant/attempt`，两者都内嵌紧凑流；错误交给请求错误瀑布决定重试还是抛错（`packages/core/agent-loop/src/agent.ts:482-582`）。
5. 工具执行：`tool/call` 记录原始参数 JSON，批次结算时落盘（`packages/core/tools/src/batch.ts:236-264`）；管线依次经过下列环节，最后追加 `tool/result`，带渲染内容与可选的错误、展示信息，`sourceEventSeqs` 指回对应的调用事件。

   ```
   tools/pre-execute → guards → tools/execute → projectContent
   → tools/post-execute → finalizeContent
   ```

6. 收口与持久化：步骤结束与回合结束两条事件（带结构化原因）依序追加；`session/flush` 检查点把已提交事件批量写入后端（默认 200ms 批窗）；resume 时后端按格式目录与迁移链恢复日志并重建内存 Session。

## 1. 触发方式、输出协议与对象模型

**触发方式**：无 artifact 类特殊标记。输出全部由用户文本、注入上下文（`agent.inject`）与模型工具调用触发；模型侧唯一的"结构"入口是工具调用（原始 arguments JSON 字符串），文本与推理块没有受控语法。

**消息与内容块**：消息是一组 typed block，`ContentBlockMap` 可合并扩展；v4 起消息来源用 `kind` 判别，插件内容类型以 `plugin:<原名>` 前缀命名，参数、回放状态与插件内容字段不被迁移遍历（`session-format-v3-to-v4/README.md` 的 Extension data 节）。

**工具结果的 v4 表示**：`tool/result` 事件的消息为 `role: 'tool'`，`toolCallId` 与 `source.callId` 一致，content 直接是块数组，`isError` 提升为消息字段；模型历史中的工具结果以该独立角色保存。

**消息角色**：session 事件层面的消息载荷有五类，surface 派生时只保留其中的模型可见子集（`packages/core/session/src/types.ts:317, 449`）：

- 用户消息 `user/message`
- 系统消息 `system/message`
- 开发者消息 `developer/message`
- 助手消息 `assistant/message`
- 工具结果 `tool/result`

**媒体与附件**：图片以内容块引用附件；文本、JSON 与图片都可有内容寻址存储。附件读取改为引用对象语义——客户端从消息图片块里取完整引用交给 `readAttachment`，返回的 `name` 与原尺寸只属调用方展示信息，只有 id、媒体类型、字节长度与宽高会与存储对象核对；访问权由 Gateway 权限决定而非会话归属（`docs/upgrade-guide/v0.2.1-rc.3/attachment-read-access/guide.md`）。

## 2. 输出事件的类型、持久化与恢复

**事件类型**（`packages/core/session/src/types.ts`）：会话生命周期（created、title、surface 操作）、回合与步骤（turn/start、step/start、step/end、turn/end）、模型请求（request/header、request/context）、未产生表面消息的尝试（assistant/attempt）、消息（user、system、developer、assistant、tool/call、tool/result）、审批（approval/asked、approval/decided）、模型选择（model/selection）、以及各工具自有的领域事件。

**持久化**：`Session.append()` 在 store 拥有的实例上受发布门控——创建公告（`session/created` 同步派发）完成前与移除后都拒绝写入；创建监听器不能追加（`docs/upgrade-guide/v0.2.1-rc.2/session-store-writes/guide.md`）。写入经 write handle 的有界批处理与 `session/flush` 检查点；第一方后端只有 JSONL，以插件形式挂载（`session-persistence-jsonl` 导出命名函数插件，服务 API 与文件格式不变）。

**格式与迁移**：格式版本由 `session-format-catalog` 描述，迁移边独立成包：v0→v1、v1→v2、v2→v3、v3→v4。每条边只改它声明的表示，保留源事件的时间、消息身份与其余字段，先跑前序边到 v3 再进 v4。v4 物理行复用已发布的 v2 帧加上 v4 原生准入；编码与解码不触发入向迁移，后继代以不可变文件发布，拒绝时不产生后继（`packages/session/session-format-v3-to-v4/`）。

**恢复与投影**：投影成为一等公民，注册表与句柄由 session-projection 提供，重建结果由 session-projection-cache 缓存，统计、标题与遥测都作为投影或消费者挂在同一层。实时投影帧包含会话 id、序号与改动集合三项，一帧列出该事件牵动的所有 key；`onEventChanged` 在每个提交事件后回调一次（`docs/upgrade-guide/v0.2.2-alpha.2/projection-event-frames/guide.md`）。

**上传通道**：`session-log-deepseek` 在官方 API 请求元数据启用时把规范会话日志增量随请求上传，用 `session-log-deepseek/delivery-accepted` 事件维护接受水位并重试；可整体关闭（`packages/session/session-log-deepseek/README.md`）。

## 3. 工具结果与结构化输出契约

**规范值不落盘**：`output.schema` 校验后的执行值只在进程内存在；`render` 与 `presentationMeta` 是纯投影，落盘的 meta 供回放复现展示。

**两个内容回调**：`projectContent` 在 post-execute 之前安装执行期准备好的内容，`finalizeContent` 是同步的最后一公里变换，对每个归一化结果（含绕过 post-execute 的管线失败）恰好调用一次。策略替换仍是权威来源。

**结构化输出**：工具可通过 `output` 声明任意受支持 JSON Schema，代理侧没有额外"结构化输出"工具；任务的最终结构化答复由子 Agent 的 `structured` 值承载（委派侧契约）。主对话的最终答案仍是文本/推理/图片块。

**失败表示**：工具失败以 isError 结果 + 结构化错误（消息与可选身份码）回注模型；`error` 字段与 v4 消息的 `isError` 必须一致，迁移转换器不修复矛盾（v3-to-v4 Native admission）。

**空结果与截断**：`finalizeContent` 可返回空内容，工具结果消息允许空 content；超长内容由 spill-policy 与 tool-result-pruner 在管线后段改写，而不是在执行函数里静默截断。

**折叠器**：`BlockAssembler` 内部只有单次折叠，不做重试；重试粒度在 LLM 调用层（`llm-retry`），折叠不跨尝试复用。

**持久化边界**：assistant 消息或 attempt 内嵌原始流，工具渲染内容、附件引用与展示 meta 随结果落盘；live assistant 帧属于进程内瞬时状态，不作为独立日志事件。未产生表面消息的 attempt 可供审计回放，但不会派生模型历史（`packages/core/session/src/surface.ts:129-150`）。

## 4. 输出形态与边界

**流式最小单位**：assistant 内容只有文本块与推理块两种，未发现块级增量元数据。客户端重放控制器把 chunk 增量累积成临时片段，在 assistant/message 到达时换成正消息（`packages/client/runtime/src/client/sessions/partial.ts`、ui-chat 的 conversation-nodes）。

**终端家族**：模型侧的终端能力由 terminal seam 上的 terminal-bash 后端提供，负责命令清洗与会话生命周期；对模型暴露的终端工具位于 `packages/experimental/tool-terminal`，需要跨调用保持的 shell 由 tool-bash-persistent 与 tool-pwsh-persistent 承担。终端会话在进程内以 `TerminalSessionId` 标识，不写入会话日志。

**后台任务**：`jobs` seam 加 `jobs-local`；`job_output` 支持流式与最终输出两种读取；job 身份与 `JobOutcome` 承载完成、被杀与失败。job 状态本身不落会话日志。

**附件与内容寻址**：`attachment` seam 加 `attachment-local`；store 负责写入与读取引用，媒体类型与维度在写入时确定。

**spill**：策略在其他 post-execute 决策接受后，对文本及图像副本计算 token 成本，基座预算为 12,500。恢复提示也计预算，图像不可拆分或重排；缺少定价、可读图像路径或存储会告警并保留原内容。read 工具避开结果二次 spill，PTC 的规范程序值不变，日志副本另经 dispatch 钩子处理（`packages/spill/spill-policy/src/index.ts:91-155`、`packages/bundle/base/cordis.patch.yml:425`）。

**交付物**：`packages/deliverables` 提供 `tool-present`、`deliverable-file-references`、`workspace-changes`。`present` 只做声明（把已有文件登记为交付物），不复制内容；引用与工作区变更投影供客户端展示。

**compaction**：`compaction` seam 加 `compaction-basic`、`compaction-image-offload`、`compaction-tool-result-pruner`；替换通过一次 `surfaceOp: replace` 的摘要消息完成，日志记录 compaction 事务事件。

**反馈与计量**：`message-feedback`（日志备注与 sidecar 评分两种契约）与 `command-feedback`；`token-meter` 提供 usage 投影与估算，统计走 `session-stats`。

**客户端消费**：会话事件与投影帧经 Gateway 的 streams 下发；Web 侧 `ui-chat` 派生对话节点（tool、turn-process、turn-tail），`ui-conversation` 提供容器与滚动，`ui-deliverables` 投影交付物。客户端不再消费宿主侧的工具 presenter 视图，而是从原始事件与 meta 自行派生卡片。

## 5. 设计取舍与已确认边界

- **日志优先、投影派生**：所有产物都是事件，模型历史、标题、统计、工具卡都是投影；代价是每条读取路径都要携带折叠逻辑。
- **规范值不落盘**：控制日志体积，回放无法重建中间值。
- **v4 把工具结果升为独立角色**：贴合模型协议、去掉包装层歧义；代价是所有旧会话必须过迁移边，且依赖 user-role 工具结果的消费方需要改读。
- **插件名命名空间化**：未知扩展不再靠约定名共存，`plugin:<原名>` 保证不同来源同名不冲突；代价是改名后旧名字符串语义变化。
- **投影帧按事件合并**：一次事件的多 key 变更在一帧内交付，消除同 seq 多帧；代价是消费者必须遍历 `changes`。
- **上传是可选而非默认前提**：官方 API 日志上送由事件水位驱动，可整体关闭。
- **已确认的移除/不变项**：模型输出仍无 G2 声明式控件、无 G3 专用运行环境；终端与 job 仍不持久化；无 diff 应用层与协作编辑。

## 6. 未验证事项

- 未运行流式会话或持久化往返：chunk 折叠、`session/flush` 时序、迁移边的实际恢复结果均为静态确认。
- v0→v4 各迁移边的拒绝条件与"不产生后继"行为只读了 v3→v4 文档，未逐边核对实现。
- `session-log-deepseek` 的上传体量、失败重试与关闭后的语义未验证。
- 投影缓存与 `onEventChanged` 的客户端消费细节只读了迁移说明。
- 附件读取改为引用语义后的 Gateway 权限判定细节未逐行核对。
- 交付物（present）在客户端的呈现与工作区变更投影未细读。

## 7. 关键源码索引

- 流与消息：`packages/llm/llm/src/{types,assembler,assistant-stream,message,content}.ts`、`llm-retry/src/*`
- 事件与表面：`packages/core/session/src/{types,surface,index}.ts`（developer/message 317、表面类型 449）
- 工具管线落盘：`packages/core/tools/src/{pipeline,batch}.ts`（batch 236-264）、`packages/core/tools/src/contracts.ts:16-101`
- 持久化与格式：`packages/session/session-persistence/src/{index,handle}.ts`、`session-persistence-jsonl/src/*`、`session-format/src/{catalog,chain,context}.ts`、`session-format-v{0..3}-to-v*`
- 迁移与契约：`packages/session/session-format-v3-to-v4/src/{tool-role,sources}.ts`
- 投影与统计：`packages/session/session-projection/src/*`、`session-projection-cache/src/*`、`session-stats/src/*`、`session-turn-outline/src/*`、`session-title*/src/*`
- 上传：`packages/session/session-log-deepseek/src/*`
- 输出形态：`packages/spill/spill-policy/src/index.ts`、`spill-local/src/index.ts`、`packages/util/output-retention/src/index.ts`、`packages/attachment/attachment-local/src/store.ts`、`packages/deliverables/*/src/*`
- 压缩：`packages/compaction/compaction-basic/src/*`、`compaction-image-offload/src/*`、`compaction-tool-result-pruner/src/*`
- 反馈与计量：`packages/feedback/message-feedback/src/index.ts`、`command-feedback/src/*`、`packages/llm/token-meter/src/{usage-projection,estimate}.ts`
- 客户端消费：`packages/client/runtime/src/client/sessions/{session,partial}.ts`、`packages/client/ui-chat/src/client/conversation-nodes/{assistant,tool,turn-process,turn-tail}.ts`、`packages/client/ui-deliverables/src/client/*`
- 文档：`docs/upgrade-guide/v0.2.1-rc.2/{session-store-writes,session-projection-handles}`、`docs/upgrade-guide/v0.2.2-alpha.2/projection-event-frames`

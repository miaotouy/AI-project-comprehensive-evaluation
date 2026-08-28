# Dify 对话请求与上下文调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态跟踪公开 WebChat 的 SSE 请求、service API、`AppGenerateService`、各应用生成器及流式实体；未配置模型或运行服务
>
> 调查范围：已发布应用的一次聊天/工作流运行，覆盖模式分流、上下文交接、流、停止和记录；节点内部算法、RAG 检索细节与真实模型行为不在本次范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 的请求主入口是 `api/services/app_generate_service.py:88` 的 `AppGenerateService.generate`。它不会把所有输入走同一聊天循环，而是依据应用模式分派：completion、chat、agent chat、agent、advanced chat 和 workflow 各有生成器；有 session 的 Agent 应用还会被视为 Agent Chat（170-174 行）。因此“上下文如何拼装、是否保存 conversation、能否 blocking 返回”都必须按模式判断。

公开 WebChat 的主链为：

```text
chat wrapper 组织 query / inputs / files / conversation_id / parent_message_id
  -> useChat.handleSend（response_mode=streaming）
  -> /chat-messages SSE
  -> AppGenerateService.generate
  -> 按 AppMode 调用生成器，创建或取得运行记录
  -> 队列/图运行时产出 StreamResponse
  -> 生成器转换为事件流
  -> useChat 回调更新当前消息、thought、文件和 workflow 状态
```

## 系统边界与模式分流

前端在 `web/app/components/base/chat/chat/hooks.ts:1156-1162` 发送 `query`、处理后的文件和输入变量，并将当前 conversation ID 写进 body；`chat-with-history/chat-wrapper.tsx:203-222` 另外放入 `parent_message_id`，首次回答后可请求建议问题和重新读取会话消息。网页只负责构造终端用户输入与消费事件，应用配置、模型凭据、工具及上下文读取都留在 API。

`AppGenerateService` 的 `_generate` 分支是运行所有权的第一道边界（170-318 行）：

| 应用模式 | 执行器 | 已确认的运行特征 |
| --- | --- | --- |
| completion | `CompletionAppGenerator` | 统一分派、可转事件流 |
| chat | `ChatAppGenerator` | 以 conversation/message 记录驱动 worker |
| agent chat | `AgentChatAppGenerator` | 只接受流式模式，先取得或创建对话 |
| agent | `AgentAppGenerator` | 独立 Agent 应用生成路径 |
| advanced chat | `AdvancedChatAppGenerator` | 取 workflow，按 workflow run 回收事件 |
| workflow | `WorkflowAppGenerator` | 可 blocking 或 streaming，按 workflow run 回收事件 |

各分支最终均经过 rate-limit 包装；这能确认统一入口接入限流，不能从当前阅读得出限额、超限排队或跨请求公平性。

## 1. 提交、记录初始化与状态对象

传统 chat 生成器在 worker 内重新取得 conversation 和 message（`core/app/apps/chat/app_generator.py:246-277`）。Agent Chat 在收到 query 后先按应用、用户和 conversation ID 查找会话（`agent_chat/app_generator.py:94-121`），构造包含应用配置、文件配置、输入、query、文件和父消息 ID 的生成实体（182-190 行），再由 `_init_generate_records` 创建本次 conversation/message 记录（204-217 行）。因此前端对会话 ID 的持有并不是权威创建动作，服务端会在发送时完成或拒绝对象绑定。

Advanced Chat 也读取 conversation，但 service API 传入不存在的 ID 时可改为新会话；其他调用来源会抛出不存在错误（`advanced_chat/app_generator.py:163-173`）。该差异意味着外部 API 与控制台/网页不能简单假定同样的“无效会话”恢复语义。

## 2. 上下文来源与拼装交接

本轮最早由浏览器明确提交的上下文是 query、inputs、files、当前 conversation 和父消息。生成器随后把应用配置、用户输入和文件转换为生成实体；Agent Chat 的实体明确含 `conversation_id`、`inputs`、`query`、`files` 与 `parent_message_id`（184-190 行）。聊天历史、应用提示、知识库、工具和模型参数在对应生成器/Agent 或工作流节点中解析，而非由 WebChat 拼接。

传统 Chat 的历史拼装已有可复查的预算规则。`TokenBufferMemory` 倒序读取当前消息链，最多读取 500 条记录，跳过尚无回答的当前轮；再按模型的 token 计数从最早的 prompt message 开始删除，默认历史预算为 2000 token（`core/memory/token_buffer_memory.py:123-226`）。这不是摘要或压缩回填：超过预算的旧消息直接不进入本次 prompt。具体窗口大小可由调用方传入，不能把默认值推广为所有 Agent 和 workflow 节点的统一限制。

Chat runner 先以模板、输入、文件、query 与历史组织一次 prompt，用于敏感词和 annotation shortcut 判断；随后填充外部数据变量、按应用数据集执行检索，并以检索上下文和文件重新组织最终 prompt（`chat/app_runner.py:79-223`）。最后才根据实际 prompt token 与模型上下文窗口收缩 `max_tokens`（`base_app_runner.py:56-90`）。因此传统 Chat 已有“历史 -> 外部变量/检索 -> 最终请求”的静态顺序；advanced chat 和 workflow 的变量图仍不应套用这一顺序。

高级聊天会创建工作流执行与节点执行 repository（`advanced_chat/app_generator.py:234-264`）；工作流应用先用 `WorkflowAppConfigManager` 将 workflow 转为应用配置，并按配置验证/转换输入和文件（`workflow/app_generator.py:166-213`）。这说明 Dify 的“上下文”至少分为会话型应用的消息上下文和图运行的变量上下文；二者的顺序、预算和可恢复性不能互相外推。

本次没有逐行追到每一个 chat/Agent 节点的历史截断、摘要或 RAG 注入逻辑，故不把 README 中的 RAG 能力写成所有模式的固定拼装顺序。

## 3. 模型、Provider 与工具交接

应用生成器只承担运行模式和记录边界。模型实例由 `ModelManager.get_model_instance` 在运行时按 tenant、Provider、模型类型和模型名解析（`core/model_manager.py:906-946`）；工具与 Agent 的实际目录进入 `core/tools` 和 workflow Agent 节点。工作流模式则由图节点决定何时请求 LLM、工具或知识库。

因此本笔记确认“生成任务何时请求模型/工具层”，而不把 Provider 连接、凭据、负载均衡写成请求链的一部分，详见 [LLM 渠道管理](../LLM渠道管理/Dify-LLM渠道管理调查笔记.md) 与 [Agent 工具](../Agent工具/Dify-Agent工具调查笔记.md)。

## 4. 流式事件、前端合并与最终化

`task_entities.py` 定义统一的 `StreamResponse`，每个事件都有 task ID（98-105 行）。消息型事件包含文本、音频开始/结束、文件、替换、结束、Agent thought 和 Agent message（117-203 行）；工作流事件进一步区分开始、完成、暂停、人工输入、节点开始/完成/重试、迭代、循环、文本 chunk、reasoning chunk 和文本替换（206-773 行）。这解释了公开聊天为何需要分别维护答案、thought、附件和 workflow 运行信息，而不是只 append 一段字符串。

对于 workflow/advanced chat 的流式请求，服务在取得 workflow run ID 后调用 `MessageBasedAppGenerator.retrieve_events`，再把事件转换为应用事件流（`app_generate_service.py:255-262,311-318`）。前端 `useChat` 在数据回调中会接收 conversation ID、message ID 和 task ID，首个事件可回填刚创建的 conversation ID（`hooks.ts:616-638`），结束回调把 workflow run ID 交给调用方（656-659 行）。

静态代码能确认事件种类和前端 state 合并入口；本次未运行，未确认 chunk 的节流频率、断线重连、事件乱序或半截流最终如何在数据库呈现。

## 5. 停止、重试、续写与并发

前端 `handleStop` 立即将本地 responding 状态设为 false，再在有 task ID 且非暂停状态时调用 stop API（`hooks.ts:527-530`）。这说明按钮反馈早于服务端确认，不能据此断言底层模型或工具已结束。restart 会清空本地树、建议问题和 task ID，并先走同一停止路径（539-548 行）。消息级重新生成使用父消息 ID（wrapper 214 行），实际是否复用完整旧上下文由后端生成器决定。

工作流的 stop 端点只声明支持 streaming；它同时写入旧的 `AppQueueManager` stop flag，并通过 `GraphEngineManager` 命令通道发送停止（`service_api/app/workflow.py:513-555`）。这表明存在新旧兼容双通道，未验证二者的竞争、队列持久化或 worker 崩溃后恢复。普通 chat/Agent 的 queue、同会话串行化和跨会话并行策略也未在本次单独审计。

## 6. 请求契约与恢复边界

公开 WebChat 最早明确提交的是 query、inputs、files、conversation ID 与 parent message ID；应用配置、模型凭据、工具目录、知识/RAG 和历史裁剪随后由服务端对应 generator 或 workflow 节点解析。因 mode 不同，Dify 同时存在“消息上下文”和“图变量上下文”两种主结构，不能把任一模式的历史、token 预算、摘要或检索顺序推广为全平台固定算法。

停止与重新生成也按运行对象区分。浏览器可立即停止显示并请求 task stop，workflow 还同时触及旧 queue flag 与 GraphEngineManager 命令通道；这只能确认发出控制命令，未证明每种模型连接、插件调用、异步 worker 或浏览器断线都会完成同样的取消和最终化。恢复、重试、去重与并发的结论必须在真实任务和多端场景中验证。

## 已确认边界与未验证事项

- 静态主链确认覆盖公开聊天、Agent Chat、advanced chat 和 workflow 的分派与事件交接；未运行任何真实模型或 Docker 服务。
- 传统 Chat 的消息窗口、最早消息裁剪、检索注入与 `max_tokens` 收缩已确认；摘要、Agent 记忆、advanced chat/workflow 的变量预算、工具循环与模型 fallback 仍需按具体节点继续核对。
- 未验证连接中断、浏览器关闭、服务器重启、限流后的用户反馈、队列公平性和多端同时向同一会话发送的行为。
- 任务停止只确认 API 与命令入口，不能代替模型请求、插件 HTTP 调用和异步 worker 的实际取消验证。

## 关键源码索引

- `api/services/app_generate_service.py:88-318`：统一生成入口、模式分派与流回收
- `api/core/app/apps/message_based_app_generator.py:118-335`：消息记录初始化、对象重取和 workflow 事件回收
- `api/core/app/apps/{chat,agent_chat,advanced_chat}/app_generator.py`：会话型应用生成路径
- `api/core/app/apps/workflow/app_generator.py:150-420`：工作流输入、repository 与图运行交接
- `api/core/app/entities/task_entities.py:98-773`：消息、Agent 与工作流事件契约
- `web/app/components/base/chat/chat/hooks.ts:527-1264`：浏览器请求、状态合并、停止和完成回调

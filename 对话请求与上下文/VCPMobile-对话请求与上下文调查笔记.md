# VCPMobile 对话请求与上下文调查笔记

> 调查对象：`VCPMobile`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`5fa2eb09e4f4dfab299cbb609a8b904b3485b5a5`（分支：`main`）
>
> 调查方式：静态阅读前端发送入口、Rust 应用服务、上下文装配器、SSE 客户端与恢复路径
>
> 调查范围：Agent/Group 主聊天的上下文、远端 VCP 请求、流式、取消与恢复；不调查 VCP 服务端内部模型/工具执行
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

生成任务由本地 Rust 发起并以助手消息 UUID 为任务 ID。客户端先本地持久化用户消息，读取同一 Topic 的轻量历史，再将 Agent 配置、时间/发言者元信息、附件文本或多模态文件、Tarven 规则组装成 VCP payload。远端 SSE 的可见状态经 Tauri Channel 进入全局流 store，终态以单一 SQLite 事务落库。

恢复分三层：仍挂在本进程的流可直接重连；进程重启后从活动生成记录恢复；若客户端在生成期间被系统回收，则用离线完成文件补交终态，只在 SQLite 提交成功后才消费该文件（`src-tauri/src/vcp_modules/infra/vcp_client.rs:3288-3600`）。WebSocket 侧另有一套活动策略控制心跳节奏与重连退避，前台恢复会打断退避（`vcp_ws_activity.rs:36-180`）。

## 系统边界与生成任务主链

`sendMessage` 生成用户消息并调用 `triggerGeneration`。后者先通过 `append_single_message` 使用户输入持久化，再按 owner type 调用单 Agent 或 Group 命令，并把 Channel 回调交给流 store，见 `src/core/stores/chatHistoryStore.ts:256-330,390-530`。

单 Agent 服务读取配置和纯文本历史，选择移动端 system prompt（无则回退普通 prompt），调用上下文装配器，建立活动请求 lease 与 pending 助手记录，发出 thinking 后发送远端请求。成功、取消和终结均进入 `finalize_stream_message`，见 `src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:70-160`。群聊复用相同的消息与流终结契约，但由群组服务决定后续发言策略。

## 1. 提交入口、任务对象与状态机

前端提交前要求当前会话 key 有效且附件均为完成状态。用户消息立即可见；助手消息仅在收到后端 thinking 或 aurora 事件时创建，因此其 ID 为后端 UUID，不是前端占位 ID，见 `src/core/stores/chatHistoryStore.ts:390-530` 与 `src/core/stores/chatStreamStore.ts:463-600`。

状态大致为 pending/thinking、aurora 流式、end 或 error。每个任务受 `ActiveRequestLease` 独占，同 ID 的重复请求会被拒绝；pending 消息同样受数据库约束保护，不会二次终结，见 `src-tauri/src/vcp_modules/infra/vcp_client.rs:851-980` 与 `src-tauri/src/vcp_modules/chat/message_service.rs:1692-1860`。

## 2. 历史与上下文拼装

请求用的历史查询刻意跳过渲染缓存和展示 shell，但包含附件提取文本。装配器先过滤 thinking 消息，再把群聊发言者前缀、可选时间锚定和附件内容写入内容部分；图片、音频、视频在本地可用时变为 `local_file` part，纯文本附件则内联进正文，见 `src-tauri/src/vcp_modules/chat/context_assembler.rs:117-300`。

基础 system prompt 插入 payload 头部，然后 Tarven 管线可加入环境元信息、系统/用户规则与虚拟节点；语音规则作为请求级节点插入 Tarven 与群聊邀请之后（`context_assembler.rs:348-400` 的测试固定了这个顺序）。Agent 配置还提供模型、最大输出、上下文限制、流式开关和可选 temperature，见 `src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:105-160`。本次未找到在 VCPMobile 内部计算 token 预算、历史摘要压缩或按 token 截断的实现；传入的上下文限制是模型配置字段，实际裁剪若有应由远端服务承担。

## 3. 流式、最终化与取消

SSE client 先对消息作多模态预处理并按设置切换目标路径。流事件传到 Channel 后，前端将 aurora 的稳定块、尾部文本和 AST diff 稀疏合并，并用 requestAnimationFrame 限制 DOM 可见状态的更新频率，见 `src-tauri/src/vcp_modules/infra/vcp_client.rs:1688-1720,2348-2700` 与 `src/core/stores/chatStreamStore.ts:463-600`。

停止按钮调用 `interruptRequest(messageId)`，它向本地活动请求表中的 oneshot 发出取消信号；前端同步把消息标为 interrupted 并移出会话活动集。Rust 在结果返回后用取消原因终结 pending 消息，因此 UI 立即反馈与持久化收口是两个阶段，见 `src/core/stores/chatStreamStore.ts:831-900` 和 `src-tauri/src/vcp_modules/infra/vcp_client.rs:2810-2910`。群聊另有按 Topic 停止整轮的命令（`vcp_client.rs:1358-1400`）。

最终化仅接受仍 pending、仍关联匹配活动记录的消息，随后在事务中写正文、渲染缓存、FTS 和 Topic 聚合数据，最后删除活动记录并发送 end。这是拒绝迟到响应覆盖终态的主要边界，见 `src-tauri/src/vcp_modules/chat/message_service.rs:1692-1860`。

## 4. 重试、恢复与并发

重新生成不会复用旧助手任务：前端找到目标前最后一个 user 消息、截断后续记录，然后以该用户消息调用重新生成命令。编辑重发也先截断后续记录；两者均为线性历史语义，见 `src/core/stores/chatHistoryStore.ts:685-760`。

活动流池按 `ownerId:topicId` 记录多个消息 ID，非当前 Topic 的新助手消息会增加未读数，说明前端可保留多会话/群聊的活动状态。恢复时先读取数据库活动记录，再优先使用 24 小时内的本地 SSE 缓存，Android 上还会查询 helper 进程的当前生成状态；helper 已分离时以观察模式接管（`src-tauri/src/vcp_modules/infra/vcp_client.rs:1925-2200,3165-3200`）。冷启动重建另走 `reconnect_chat_streams` 与两个恢复入口（:2998、:3544、:3593）。

WebSocket 活动通道是另一条独立状态机：连接空闲时停掉心跳计时，恢复需重新收到 pong；频繁短连接按退避拉开，前台恢复会立即打断退避（`vcp_ws_activity.rs:112-260`）。

## 设计取舍与已确认边界

此实现把请求可取消性、持久化骨架和前端实时投影绑定到同一个消息 ID，适合移动端前后台切换。它不拥有模型 Provider fallback、服务端重试、工具循环和最终 token 裁剪；这些应由 VCP 服务端或其他专项确认。

悬浮助手相关的无持久化对话路径已随悬浮窗口一并移除，当前快照中不存在 `floating.html`、`src/floating-main.ts`、`src/core/stores/floatingAssistant.ts`，主聊天是唯一带持久化的会话路径。

## 未验证事项

未连接真实服务，未验证 SSE 事件排序、取消是否中断远端推理、并行单 Agent 请求的服务端策略、Tarven 规则的运行结果及长上下文的实际截断；离线完成文件的补交顺序、helper 分离观察在真实系统回收场景下的行为也未运行验证。

## 关键源码索引

- `src/core/stores/chatHistoryStore.ts:256-330,390-530,685-760`
- `src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:70-160`
- `src-tauri/src/vcp_modules/chat/context_assembler.rs:117-300`
- `src-tauri/src/vcp_modules/infra/vcp_client.rs:851-980,1688-1720,2348-2700,2810-2910,2998-3600`
- `src/core/stores/chatStreamStore.ts:463-600,831-900`

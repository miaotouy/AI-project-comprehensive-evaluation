# Jan Chat 概览

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
>
> 调查方式：只读源码梳理（前端 store/hooks/Rust commands 全量行级阅读）；未修改 Jan 仓库
>
> 调查范围：Thread/Message 数据模型、文件与 SQLite 双持久化、流式管线、上下文管理、分支/版本/编辑/续写、队列、错误与恢复
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 现在有普通 Chat、桌面 Cowork 和独立 Agent CLI/TUI 三个对话表面。普通 Chat 沿用 AI SDK 的 useChat 与自定义 transport，配合 thread 文件与移动端 SQLite 持久化；Cowork 由前端循环持有执行权，会话存入设置后端；CLI 使用 Rust Agent 核心与项目会话。后文的主链对应普通 Chat 的实现，Cowork 的运行循环见 `web-app/src/lib/coworkRunner.ts:411` 的 runTurn 与会话侧的 web-app/src/hooks/useCoworkSessions.ts，CLI 的命令树见 `src-tauri/jan-cli/src/main.rs:229`。

关键事实：

1. **三个 store 协作**：三个前端 store 各管一层状态，useThreads 管线程列表、排序、搜索与增删改，useMessages 管消息的乐观写和异步持久化，useChatSessions 管 AI SDK 会话与流状态。三者共同支撑线程页，页面中枢 `$threadId.tsx`（约 2500 行）承载分支、编辑、续写与上下文扩展的全部仲裁。
2. **流式管线**：AI SDK 的 UI 状态按 50 毫秒节流，会话关闭 resume，重启后不恢复未完成的回合；transport 实例按 sessionId 复用。模型推理参数（temperature、top_k 等）由 createCustomFetch 注入 HTTP body。
3. **上下文管理在 transport 内**：max_context_tokens 大于 0 时，按 auto_compact 开关在模型总结与纯截断之间选择。回合因 length 结束且 token 消耗达到上下文窗口的 90% 时，部分消息被冻结并提示扩容，扩容按从小值起步、依次取 8192 与 32768、之后每次乘 1.5 的阶梯逐级提升。
4. **分支与编辑**：分支由 ensureBranched、parentId 树与 makeSibling 共同产生新版本；Continue 走原地续写（setContinueFromContent），留在原线程。编辑消息只保留纯文本，媒体内容会丢失并回退，助理消息编辑后不重新生成；流式进行中禁用删除与编辑。
5. **队列**：发送时若当前线程正在流式，新消息先入队，状态回到 ready 后自动发出下一条；遇到 error 或离开线程则清空队列，队列内容由输入区顶部的 QueuedMessageChip 显示。
6. **错误与恢复**：错误以 banner 置顶显示，涵盖 OOM、backend 与 context 三类，最后一条失败的 assistant 消息被隐藏。触发扩容时，新阶梯值写入 model.yml，llamacpp 下重启 router，其他 provider 调用 stopModel，随后消费续写并在 1s 后重新生成。

## 产品表面与系统边界

Cowork 进入 `web-app/src/routes/cowork.tsx:150-191`，模型必须支持 tools，运行循环在路由卸载后仍可继续；独立 CLI 的裸 `jan` 进入 TUI，仅使用远程 Provider，不加载 GUI 或本地推理（`web-app/src/routes/cowork.tsx:439-475`、`web-app/src/lib/coworkRunner.ts:15-25`、`src-tauri/jan-cli/src/main.rs:1-5`）。

- 产品表面：Tauri 桌面 GUI、Web 与 Android/iOS 移动端；聊天业务没有独立后端服务，模型生成由本地 llama-server/mlx-server 或远程 provider 完成，前端直连。
- 持久化后端分流：桌面端由 Rust 命令层写线程目录下的 thread.json 与 messages.jsonl；SQLite 只在 Android/iOS 生效，由 should_use_sqlite 判断（`helpers.rs:17-19`）。
- 边界：Rust 的 create_thread 用服务端生成的 v4 UUID 覆盖前端传入的 id；get_thread_assistant 等 3 个 Rust 命令没有 web 调用方，属于遗留 API 表面。

## 端到端聊天主链

```text
ChatInput.handleSendMessage → $threadId.processAndSendMessage（附件合并/摄取 → 持久化 userMessage 并写 parentId → sendMessage）
→ useChatSDK → CustomChatTransport.sendMessages（`custom-chat-transport.ts:1382`）
   模型创建（createModelOrAbort：合并模型采样默认/线程参数/reasoning 参数；llamacpp 固定 slot 0，并以 thread_id 交给本地引擎切换 KV 状态）
   → refreshTools → 上下文管理（compact/trim）
   → 消息清洗链（coalesce / resolveOrphan / 音视频编码 / 剔除不支持的图片 part）
   → streamText 流式 → toUIMessageStream 回写
→ 落盘（createMessage/modifyMessage，Rust 整文件重写）→ status==='ready' 时自动发下一条队列消息
```

## 核心对象与状态权威

- **Thread**（`core/src/types/thread/threadEntity.ts`）：线程实体由基础字段、助手快照和分支元数据组成。

  | 字段 | 含义 |
  | --- | --- |
  | id | 默认 ULID |
  | title | 线程标题 |
  | created / updated | 创建与更新时间 |
  | assistants | 嵌入的 ThreadAssistantInfo 快照，保存创建时的助手配置，与全局 assistant 配置分开存储 |
  | metadata | 分支状态，如 activeRootId |
  | isFavorite | 顶层收藏标记 |

  Rust 侧创建线程时，用服务端生成的 UUID 覆盖前端传入的 id。

- **Message**（`core/src/types/message/messageEntity.ts`）：消息实体保存结构化内容分片和 AI SDK 的运行状态。

  | 字段 | 含义 |
  | --- | --- |
  | content | 结构化 parts 数组，元素为 TEXT、FILE 或 REASONING |
  | status | 由 AI SDK 映射为 submitted、streaming、ready、error |
  | metadata.stopped | isAbort 或 finishReason 为 length 时写 true；Continue 按钮在消息为最后一条且处于停止态时显示 |

- **持久化权威**：三层各自负责一段写入。
  - Rust 层用全局的 per-thread 锁 MESSAGE_LOCKS 把同一线程的消息写串行化，write_messages_to_file 以 File::create 整文件重写（`helpers.rs`）；commands.rs 的创建与修改消息命令带 upsert 去重，消息已存在时直接返回。
  - 移动端 db.rs 依赖 SQLite 的幂等写（INSERT OR IGNORE 与 ON CONFLICT DO UPDATE）。
  - 前端 useMessages 先乐观写入，再按 id 替换（`addMessage` L46-55）。

- **会话流状态**：chat-session-store.ts 按 sessionId 保存 Chat 实例和对应的 transport，跨渲染复用（`use-chat.ts` 的 transportRef）。

## 专项导航

- 会话与消息管理：[Jan-会话与消息管理调查笔记.md](../会话与消息管理/Jan-会话与消息管理调查笔记.md)
- 对话请求与上下文：[Jan-对话请求与上下文调查笔记.md](../对话请求与上下文/Jan-对话请求与上下文调查笔记.md)
- Chat UI：[Jan-ChatUI调查笔记.md](<../Chat UI/Jan-ChatUI调查笔记.md>)
- 消息渲染：[Jan-消息渲染器调查笔记.md](../消息渲染器/Jan-消息渲染器调查笔记.md)
- 横向对比：[会话与消息管理横向对比.md](../会话与消息管理/会话与消息管理横向对比.md)、[对话请求与上下文横向对比.md](../对话请求与上下文/对话请求与上下文横向对比.md)、[ChatUI横向对比.md](<../Chat UI/ChatUI横向对比.md>)；跨层综合结论见 [Chat横向对比.md](../Chat/Chat横向对比.md)

## 关键能力与已确认边界

- **线程目录与 JSONL 整文件重写**：每条消息写入都用 File::create 重建整个 messages.jsonl（`helpers.rs:34-44`），长会话每轮产生与消息数成正比的文件 I/O；per-thread 锁只保证写入串行，没有增量维护。【代码确认】
- **未完成回合在重启后不恢复**：会话配置关闭 resume，重启时不会续上生成到一半的回合；首条消息经 stickySessionStorage 以 INITIAL_MESSAGE_PREFIX 加 threadId 为键暂存，恢复后重新发送。【代码确认】
- **按线程的 KV 状态缓存**（llamacpp）：请求仍固定落到 slot 0，transport 会同时传入 thread_id；worker 换入其他线程前先保存旧状态，再在同一模型与配置下恢复目标线程的状态。模型、预设、llama.cpp 构建或模型文件变化时，旧缓存被拒绝复用。运行时命中率与多窗口并发行为尚未验证，相关实现见 `web-app/src/lib/custom-chat-transport.ts` 的 spreadProviderOptions 附近与 `src-tauri/plugins/tauri-plugin-llamacpp/src/engine/http.rs:217-290`（with_slot_state 与恢复逻辑）、engine/slots.rs。
- **分支树跨重启一致性**：当前分支根 activeRootId 存在 thread.json 的 metadata 中，发送时由 backfillParentIds 铺平 parentId；旧数据的迁移完整性尚未验证。【代码确认（机制）+ 未验证行为】
- **compactMessages 退化为纯 trim**：摘要失败提示"摘要失败已退回截断"，摘要削减对关键上下文的影响未做质量实测。【代码确认 + 推测】
- **线程内助手快照**：编辑助手只在线程内生效，改动写入快照；从线程内的 SamplerPopover 编辑时，同一改动会同时写快照与 canonical 镜像。
- **错误呈现并存**：全局 banner 隐藏最后一条失败的 assistant 消息，同时把错误写入 metadata.error；两者在 UI 上的呈现由 banner 端配置决定，行为尚未实测。
- **消息列表**：全量渲染，没有窗口化或虚拟化；@tanstack/react-virtual 只用于 Hub 模型列表，本轮未找到 content-visibility 样式声明。

## 未验证事项

- 运行行为（视觉效果、时序、性能、真实 provider 上的流式）未实测；结论来自静态源码。
- 多窗口/多会话并发及按线程 KV 缓存的命中率、恢复时序未验证。
- 分支树旧数据迁移完整性、compactMessages 摘要质量未验证。
- banner 与 metadata.error 并存的 UI 呈现、队列在错误/离场场景的完整时序未实测。

## 关键源码索引

- 前端中枢：`web-app/src/routes/threads/$threadId.tsx`（分支/编辑/续写/错误挂载）
- 输入框/发送/队列：`web-app/src/containers/ChatInput.tsx`、`web-app/src/hooks/usePrompt.ts`、`web-app/src/stores/message-queue-store.ts`
- transport 与上下文：`web-app/src/lib/custom-chat-transport.ts`（`sendMessages :1382`）、`web-app/src/lib/context-manager.ts`
- 本地引擎缓存：`src-tauri/plugins/tauri-plugin-llamacpp/src/engine/http.rs:217-290`、`engine/slots.rs`
- 消息转换与分支：`web-app/src/lib/messages.ts`、`completion.ts`、`web-app/src/lib/message-branching.ts`
- Rust 持久化：`src-tauri/src/core/threads/commands.rs`、`helpers.rs`、`db.rs`、`constants.rs`
- 前端 store：`web-app/src/hooks/useThreads.ts`、`useMessages.ts`、`use-chat.ts`、`web-app/src/stores/chat-session-store.ts`

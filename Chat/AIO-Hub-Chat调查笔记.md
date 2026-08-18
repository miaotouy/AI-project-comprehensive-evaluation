# AIO-Hub Chat 概览

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`023bc63ac10201bf0f663bf49d642fd55c29a3d0`（分支：`main`）
>
> 调查方式：直接阅读源码（Vue 组件、composable、store、Rust 后端命令）。
>
> 调查范围：聊天会话、消息状态、存储、流式更新、上下文管道、压缩及交互机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

`llm-chat` 是 aio-hub（Tauri 桌面应用）内可独立分离窗口的聊天工具模块，基于**树形消息结构**，支持多 Agent、多分支、工具调用和上下文压缩，线性对话列表只是消息树的一种视图。分层清晰：`types/` 定义会话、消息节点等核心数据结构；`stores/llmChatStore.ts` 是 Pinia 入口，逻辑委托给 `stores/session/` 下的五个 Manager（访问、运行时、历史、生成、生命周期）；`composables/chat/` 承担请求执行、工具编排与流式响应；`composables/session/` 承担树形节点与分支操作；Rust 后端命令提供跨会话全文搜索。消息树 + 分支记忆、可重放流源驱动的流式渲染、非破坏性上下文遮罩是三个核心特征。

## 产品表面与系统边界

- **产品表面**：桌面 GUI（Vue 3 + Element Plus + Tauri）。三栏工作台（Agent 侧栏 / 消息区 / 会话侧栏），线性与树图（Vue Flow）双视图，输入框可独立成悬浮窗口，跨窗口状态经 `useWindowSyncBus` 同步。
- **数据归属**：数据完全本地。会话"索引与详情分文件"存储：`sessions-index.json` 存全部索引对象，每个会话的完整详情单独存 `sessions/{id}.json`；撤销/重做栈从不落盘。
- **不拥有的层级**：无外部平台/网关；系统托盘、通知中心是应用级基础设施，不承载聊天生成状态（生成完成无系统通知）。

## 端到端聊天主链

```text
MessageInput 提交 → useChatHandler.sendMessage（会话生成中则进排队集合，isQueued 占位节点）
→ 上下文压缩检查（useContextCompressor，可选）→ contextPipelineStore 11 处理器上下文管道（会话加载/世界书/Recall 检索/变量/Token 限制/格式化/附件 Base64 等）
→ useChatExecutor → useSingleNodeExecutor 请求 LLM（重试策略、前缀续写）
→ 流式返回：ReplayableMessageStreamSource 驱动 UI 渲染（即时），节点内容按定时节流写回并落盘
→ 工具调用循环 useToolCallOrchestrator（toolCallingStore 审批阻塞等待，默认无限等待、可配置超时自动拒绝）
→ finalizeNode 强制写出全部缓冲 → persistSession → 跨窗口同步总线
```

## 核心对象与状态权威

- **`ChatSessionIndex` / `ChatSessionDetail`**（`types/session.ts:22-110`）：轻量索引（含展示用 Agent 标识、消息计数）与重量详情（节点字典、根节点、活动叶节点与撤销栈）分离；`activeLeafId` 是"当前显示路径"的事实源。
- **`ChatMessageNode` 消息树**（`types/message.ts:110-416`）：由父、子与最近选中子节点三类指针构成；`getActivePath` 沿父指针回溯得到当前路径，`lastSelectedChildId` 实现分支位置记忆。
- **生成状态**：`sessionRuntimeManager` 的 `generatingNodes`/`abortControllers` 是全局响应式集合（非会话布尔值），天然支持多会话并发生成；消息 `status` 字段扩展为五种取值，其中排队（`queued`）与等待（`waiting`）有独立展示状态。
- **流式渲染状态**：`ReplayableMessageStreamSource`（模块级 Map）独立于节点内容——渲染逐帧节流、持久化默认两秒节流，两套路径解耦，崩溃可能丢失最后几秒流式内容。

## 专项导航

- 会话与消息管理：[`../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md`](../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md)（数据模型、索引自愈、生命周期、分支语义、搜索检索与恢复）。
- 对话请求与上下文：[`../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md`](../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md)（提交入口、11 处理器管道、压缩、流式节流、队列、注入点）。
- Chat UI：[`../Chat UI/AIO-Hub-ChatUI调查笔记.md`](<../Chat UI/AIO-Hub-ChatUI调查笔记.md>)（工作台、Composer、生成反馈、消息操作、树图视图、键盘关键路径）。
- 消息渲染：[`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)（rich-text-renderer 的 AST/Patch 渲染与流式节点细节）。
- 横向对比：[`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md)、[`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md)、[`../Chat UI/ChatUI横向对比.md`](<../Chat UI/ChatUI横向对比.md>)。
- 应用界面基础设施（弹窗库、Toast、主题、动画、灯箱等）：[`../应用界面基础设施/AIO-Hub-应用界面基础设施调查笔记.md`](../应用界面基础设施/AIO-Hub-应用界面基础设施调查笔记.md)。

## 关键能力与已确认边界

1. **分支语义完整**：创建分支=在同父节点下新增兄弟节点；重试=给同一用户消息新增助手兄弟；续写=带 `isContinuation` 前缀的节点（续请求时以该前缀标记，收尾时补回）；硬删除递归收集后代，压缩节点删除走"归还子节点"特殊路径。
2. **上下文压缩是"非破坏性遮罩"**：摘要节点 + `session-loader` 两遍回溯跳过原消息；原消息一直留存于会话 JSON。连续压缩已接入执行路径：`executeCompression()` 会把待压缩范围之前最近的已启用摘要节点内容作为 `previous_summary` 传给续写模板，新摘要创建后旧摘要一并隐藏（文档与实现已一致）。
3. **流式渲染与持久化解耦**：渲染走流源（订阅重放），节点内容落盘默认两秒节流、推理内容每帧写入；生成中节点先占位（生成集合先行）再发请求。
4. **撤销/重做不持久化**（重启清空）；崩溃残留的生成中节点在加载时按"是否有内容"自动修复为完成或错误状态（`repairInterruptedGeneratingNodes`），不再依赖僵死修复侦听器。
5. **搜索无索引**：跨会话=Rust 目录扫描 + 正则预过滤（仅定位会话，不定位消息）；会话内=当前活动路径内存线性扫描（最多 50 条，搜索不到分支外消息）。
6. **生成排队**：生成中提交消息进 `queuedSessionIds`，`queueReplyMode` 决定合并回复或链式追加；排队/等待节点有可见状态徽标（MessageHeader）。工具调用审批用 Promise 解析器让执行链阻塞等待，默认无限等待、可配置超时自动拒绝，支持 VCP 外部协议请求。

## 未验证事项

- `@/tools/tool-calling` 内部（`processCycle`/协议解析）未展开阅读；VCP 连接协议细节未核实。
- 树图大规模节点布局性能未压测；后端全文搜索大数据量延迟为静态推断。
- 多会话并行生成时后台压缩套用前台 Agent 配置/Token 统计的状态错位已由代码确认，实际误压缩未复现。
- 界面层运行态（弹窗堆叠像素、深色模式视觉效果、屏幕阅读器行为）未实测，相关内容随第 12 节移至应用界面基础设施笔记。

## 关键源码索引

- `src/tools/llm-chat/types/session.ts`、`types/message.ts`（核心数据结构）
- `src/tools/llm-chat/stores/session/sessionLifecycleManager.ts`、`sessionRuntimeManager.ts`、`sessionGenerationManager.ts`（生命周期/生成态/排队）
- `src/tools/llm-chat/composables/chat/useChatHandler.ts`、`useChatResponseHandler.ts`、`useStreamingMessageSources.ts`、`useToolCallOrchestrator.ts`（主链执行）
- `src/tools/llm-chat/composables/features/useContextCompressor.ts`、`src/tools/llm-chat/core/context-processors/session-loader.ts`（压缩与上下文管道）
- `src-tauri/src/commands/llmchat_search.rs`（跨会话全文搜索）

# Chatbox Chat 概览

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-08-07
>
> 代码快照：`f90fc31afd634494bdf8f074eca3e38fcf8da740`（分支：`main`）
>
> 调查方式：直接阅读源码（`src/renderer/routes/index.tsx`、`src/renderer/routes/session/$sessionId.tsx`、`src/renderer/components/session/*`、`src/renderer/stores/session/*`、`src/renderer/stores/chatStore.ts`、`src/renderer/stores/uiStore.ts`、`src/renderer/storage/SessionMetaStorage.ts`、`src/shared/session/message-forks.ts`、`src/shared/types.ts` 等），未凭空推断；不确定处标注"未核实"。
>
> 调查范围：聊天会话、消息构建、消息状态、存储、流式更新与交互机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

> 迁移状态（2026-08-11）：本文件原为旧版长文，内容已按新类目边界迁移：
>
> - 会话与消息管理：[`../会话与消息管理/Chatbox-会话与消息管理调查笔记.md`](../会话与消息管理/Chatbox-会话与消息管理调查笔记.md)（数据模型、生命周期、索引检索、缓存一致性）
> - 对话请求与上下文：[`../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md`](../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md)（流式、节流落盘、上下文注入、停止回写）
> - Chat UI：[`../Chat UI/Chatbox-ChatUI调查笔记.md`](<../Chat UI/Chatbox-ChatUI调查笔记.md>)（工作台、Composer、消息操作、无障碍、桌面集成）
> - 消息渲染：[`../消息渲染器/Chatbox-消息渲染调查笔记.md`](../消息渲染器/Chatbox-消息渲染调查笔记.md)（已有独立笔记）
> - 通用界面盘点（弹窗库、Toast 系统、主题、断点、动画、灯箱、openAboutDialog 死状态）：已搬入 [`通用界面盘点待迁移/Chatbox.md`](通用界面盘点待迁移/Chatbox.md)
>
> 2026-08-11 本文件已压缩为概览。

## 结论摘要

Chatbox 是一个 **local-first、以单个 Session 为存储单元**的多模型聊天系统，Electron 桌面 + Web 双端。核心特征：会话列表只认识 `SessionMetaRecord` 元信息，完全不知道 thread/fork/summary 的存在；首页是 id 固定为 `'new'` 的假会话，真正的 Session 直到发出第一条消息才创建；流式生成把"UI 立即刷新"和"落盘持久化"拆成两条频率完全不同的路径（UI 缓存逐 token、落盘 2 秒节流）；Agent 模式、知识库、网页浏览在架构上是同一个工具注册管线里的三个开关，而不是三套独立的 prompt 拼接逻辑。thread（同会话历史区间）、fork（消息位置平行分支）、summary（消息级压缩标记）、starred（侧栏分组）是四套互不隶属的数据结构，唯一交叉点是"move thread to conversations"把 thread 转成新顶层会话。

## 产品表面与系统边界

Chatbox 提供 Electron 桌面端与 Web 网页端两个产品表面，核心聊天工作台固定为 `Header → MessageList → InputBox` 三段式：消息列表是 react-virtuoso 虚拟列表（缓存每会话滚动快照），移动端一级导航是左侧滑出的 `SwipeableDrawer`（没有底部 Tab Bar），桌面端侧栏常驻挤压布局。数据完全 local-first：完整 Session 对象与消息存于通用 storage（IndexedDB），侧栏元信息存于独立的 IndexedDB meta store（游标分页、置顶优先），react-query 缓存是 UI 侧视图，两者靠每会话 `UpdateQueue` 串行合并保持最终一致。

外部系统边界：模型请求由 `packages/model-calls` 的 API 适配层组装并发出，provider 侧 token 截断与最终 HTTP payload 字段不在本次概览范围；Agent 角色/工具、知识库等能力分属 Agent 专项与渠道管理类目；消息渲染（Markdown、结构化 part、虚拟列表）由独立的消息渲染器笔记承接。

## 端到端聊天主链

```text
用户输入
 → InputBox.handleSubmit（首页为 createPersistedChatSession：把 'new' 临时会话迁移为真实 Session）
 → sessionHelpers.constructUserMessage（图片→contentParts、文件→files、链接→links）
 → submitNewUserMessage（写入用户消息 + 插入 assistant 占位）
 → orchestrateGeneration（选择当前 session/thread 的消息历史）
 → prepareAgentGenerationHarness / buildToolsForSession（按模型 isSupportToolUse 注册 agent/知识库/网页浏览工具）
 → model.chatStream 流式（provider）
 → 主循环逐 chunk：updateStreamingCache 只刷 UI 缓存；距上次落盘 ≥2s 或 chunk 为 tool-call 时 persistStreamingMessage 落盘（每会话 UpdateQueue 串行合并）
 → 流结束 / 出错 / 暂停 各补一次无条件落盘
 → storage（IndexedDB）持久化
```

## 核心对象与状态权威

- **`Session`**（`shared/types.ts`）：完整会话对象，含 `messages`、`threads: SessionThread[]`、`messageForksHash`、`settings`；权威源在 storage，react-query 缓存是 UI 侧视图。
- **`SessionMetaRecord`/`SessionMetaSchema`**（`shared/types.ts:390-400`）：侧栏唯一认知的元信息（`starred`/`hidden`/`archivedAt`/`sortOrder` 等，不含任何消息级字段）；权威源在 IndexedDB meta store（页大小 50，置顶记录优先游标扫描）。
- **`Message`**（`shared/types.ts`）：`contentParts`/`files`/`links`、`generating` 标记、`isSummary`、`isForkMarker` + `forkedFromSessionId`。
- **`uiStore`**：会话级开关（`sessionWebBrowsingMap`/`sessionKnowledgeBaseMap`/`sessionAgentModeMap`）与 `newSessionState`；`'new'` 假会话的待发送状态分散在本地 state、`newSessionState`、通用 map（以 `'new'` 作 key）三处，首次发送时统一迁移。
- **生成中的消息**：streaming cache（queryClient）→ 每会话 `UpdateQueue` → 磁盘；节流 2000ms，`mergeCachedGeneratingMessages` 保证落盘旧快照不回退生成中消息。

## 专项导航

| 文档 | 承接内容 |
|---|---|
| [`../会话与消息管理/Chatbox-会话与消息管理调查笔记.md`](../会话与消息管理/Chatbox-会话与消息管理调查笔记.md) | 数据模型、会话生命周期、分页/索引检索、缓存一致性（原第 3/4/5 节） |
| [`../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md`](../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md) | 流式主循环、2 秒节流落盘、上下文拼装、停止回写（原第 6 节） |
| [`<../Chat UI/Chatbox-ChatUI调查笔记.md>`](<../Chat UI/Chatbox-ChatUI调查笔记.md>) | 工作台、Composer、消息操作、无障碍、桌面集成及聊天相关弹窗/通知交点（10.1 节） |
| [`../消息渲染器/Chatbox-消息渲染调查笔记.md`](../消息渲染器/Chatbox-消息渲染调查笔记.md) | 消息模型、Markdown/结构化 part 渲染、消息列表虚拟化（既有独立笔记） |
| [`../通用界面盘点待迁移/Chatbox.md`](通用界面盘点待迁移/Chatbox.md) | 弹窗三套技术栈、Toast 两套系统、主题、断点、动画、灯箱、openAboutDialog 死状态（原第 13 节，待界面专题承接） |
| [`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md) | 跨项目对比：会话/消息存储与生命周期 |
| [`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md) | 跨项目对比：请求编排与上下文 |
| [`<../Chat UI/ChatUI横向对比.md>`](<../Chat UI/ChatUI横向对比.md>) | 跨项目对比：聊天界面与交互 |

## 关键能力与已确认边界

1. **分支（fork）**：重新生成/在新分支重试产生消息级平行分支（`messageForksHash`），`ForkNav` 在同一消息位置切换内容，不产生新侧栏条目；fork 与 thread 可叠加共存，`cleanupEmptyForkBranches` 在 root 层和 thread 层各有一套相似但不完全相同的清理逻辑。
2. **搜索**：`SearchDialog` 提供"当前会话/全部会话"两个入口，按消息模型扫描（覆盖 thread 历史与文本/reasoning/tool-call 状态），点击结果切换会话并 `scrollToMessage` 定位；无持久化倒排索引，跨会话按 IndexedDB 分页逐条扫描（每页 30，最多 50 条命中）。
3. **停止**：生成中消息的停止按钮调用其 `cancel()` 并以 `generating:false` 乐观写回；流结束/出错/暂停各补一次无条件落盘，保证最终态一定持久化。
4. **压缩**：自动压缩在消息上打 `isSummary` 标记，由 `SummaryMessage` 专用组件渲染，提供"删除摘要、恢复原文参与上下文计算"的操作；触发实现位于 `context-management` 包（未核实细节）。
5. **排序与归档边界**：拖拽排序仅在同一置顶分组内生效（`areSessionsInSamePinGroup` 只看 `starred`）；恢复归档会话不重置 `sortOrder`，会回到归档前位置；归档只置 `hidden`+`archivedAt`，不删除数据。
6. **并发落盘**：每会话一个 `UpdateQueue` 串行合并写入避免并发覆盖；批量归档刻意逐个走 `updateSession` 不做性能优化（代码注释明确承认）；`MAX_TOOL_CALLS_BEFORE_CONFIRMATION = 25` 表明 chat 与 agent 在实现上无清晰边界。

## 未验证事项

- `context-management` 包内摘要产生的具体触发逻辑未读取（仅确认调用点）。
- `localStorage.removeItem('new-chat')`（`routes/index.tsx:336`）未找到对应写入点，用途不明。
- provider 侧 token 截断策略与最终 HTTP JSON payload 字段未逐一核实。
- IndexedDB meta store 注释提到的"捕获 VersionError 后重试"兜底未见实现。
- UI 行为结论（视觉、键盘可用性、性能、平台行为）来自静态代码，未经运行验证。

## 关键源码索引

- `src/renderer/routes/index.tsx`：`'new'` 假会话与 `createPersistedChatSession` 迁移
- `src/renderer/routes/session/$sessionId.tsx`：会话页组装（Header → MessageList → InputBox）
- `src/renderer/components/session/SessionList.tsx`、`SessionItem.tsx`：分页列表、拖放排序、置顶/归档入口
- `src/renderer/components/chat/MessageList.tsx`：ThreadLabel、ForkNav、消息渲染调度
- `src/renderer/components/InputBox/InputBox.tsx`：Composer 与发送链入口
- `src/renderer/stores/chatStore.ts`：会话 CRUD、缓存合并、归档/删除
- `src/renderer/stores/session/orchestration.ts`、`messages.ts`：流式主循环、节流落盘、streaming cache
- `src/renderer/storage/SessionMetaStorage.ts`：IndexedDB 分页/索引/游标
- `src/shared/types.ts`：`Session`/`Message`/`SessionThread`/`MessageForkEntry` 等 schema

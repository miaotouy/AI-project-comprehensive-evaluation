# Chatbox Chat 概览

> 调查对象：`https://github.com/chatboxai/chatbox`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`d17455c5ca8fd3ff44385c6d4d2118599e4c970f`（分支：`main`）
>
> 调查方式：直接阅读源码（`src/renderer/routes/index.tsx`、`src/renderer/routes/session/$sessionId.tsx`、`src/renderer/components/session/*`、`src/renderer/stores/session/*`、`src/renderer/stores/session/`、`src/renderer/stores/uiStore.ts`、`src/renderer/storage/SessionMetaStorage.ts`、`src/shared/session/message-forks.ts`、`src/shared/types.ts` 等），未凭空推断；不确定处标注"未核实"。
>
> 调查范围：聊天会话、消息构建、消息状态、存储、流式更新与交互机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 是一个 **local-first、以单个 Session 为存储单元**的多模型聊天系统，Electron 桌面 + Web 双端。核心特征：会话列表只认识 `SessionMetaRecord` 元信息，不知道 thread/fork/summary 的存在（消息侧已改为行式消息树，权威数据是 `SessionTree` 的 thread 行与消息行）；首页是 id 固定为 `'new'` 的假会话，Session 直到发出第一条消息才创建；流式生成把 UI 立即刷新与落盘持久化拆成两条频率不同的路径——UI 缓存逐 token 更新，落盘按 2 秒节流。

Chatbox 现在明确区分 Chat Mode 与 Work Mode：前者保留 thread/fork 的结构自由，后者采用追加式单线工作流并开放消息队列、steering、Soul/Memory 与宿主工具。知识库和网页浏览仍通过同一工具注册管线注入；持久记忆也可在 Chat Mode 使用。thread、fork 与 summary 在落盘后都收进同一棵消息树（thread 是根到叶的路径、fork 是兄弟行与激活子节点、summary 是 `kind` 为 `summary` 的行），starred 只存在于 `session_meta`。

## 产品表面与系统边界

Chatbox 提供 Electron 桌面端与 Web 网页端两个产品表面，核心聊天工作台固定为 `Header → MessageList → InputBox` 三段式：消息列表是 react-virtuoso 虚拟列表（缓存每会话滚动快照），移动端一级导航是左侧滑出的 `SwipeableDrawer`（没有底部 Tab Bar），桌面端侧栏常驻挤压布局。侧栏会话项带"生成中/回复完成未读"指示（状态存于内存 zustand store，不落盘、不进入 `SessionMetaRecord`）。

数据保持 local-first：会话头、线程行与消息行组成权威消息树，侧栏元信息另存 meta，旧完整 Session 为兼容投影。桌面/Web 的行与 meta 均走 IndexedDB，移动端均走 SQLite；领域服务和行提交队列处理写入，react-query 承载 UI 视图。平台工厂见 `src/renderer/platform/{desktop_platform,web_platform,mobile_platform}.ts`，详见会话与消息管理笔记 2。

外部系统边界：模型请求由 `packages/model-calls` 的 API 适配层组装并发出，provider 侧 token 截断与最终 HTTP payload 字段不在本次概览范围；Agent 角色/工具、知识库等能力分属 Agent 专项与渠道管理类目；消息渲染（Markdown、结构化 part、虚拟列表）由独立的消息渲染器笔记承接。

## 端到端聊天主链

```text
用户输入
 → InputBox.handleSubmit（首页把 'new' 临时会话迁移为真实会话：SessionService.createSession + 草稿清理）
 → sessionHelpers.constructUserMessage（图片→contentParts、文件→files、链接→links）
 → submitNewUserMessage（写入用户消息 + 插入 assistant 占位）
 → orchestrateGeneration（选择当前 session/thread 的消息历史）
 → prepareAgentGenerationHarness / buildToolsForSession（按模型 isSupportToolUse 注册 agent/知识库/网页浏览工具）
 → model.chatStream 流式（provider）
 → 主循环逐 chunk：updateStreamingCache 只刷 UI 缓存；距上次落盘 ≥2s 或 chunk 为 tool-call 时 persistStreamingMessage 落盘（流式写协调器与领域行提交队列串行处理）
 → 流结束 / 出错 / 暂停 各补一次无条件落盘
 → 平台行存储持久化（桌面/Web IndexedDB，移动 SQLite；消息树与 meta 分离）
```

## 核心对象与状态权威

- **`SessionTree`**（`packages/chatbox-core/src/session/session-tree/types.ts`）：会话头、thread 行与消息行三段式；树形拓扑（父指针、激活子节点、兄弟序）就是权威数据，旧数组式 `Session` 由 `encode.ts`/`decode.ts` 与其互转，renderer 侧读的是窗口化投影。
- **`SessionMetaRecord`/`SessionMetaSchema`**（`src/shared/types/session.ts`）：侧栏唯一认知的元信息，含置顶、隐藏、归档时间与排序序号等字段，不含任何消息级字段；权威源是 `session_meta` 表，桌面/Web 走 IndexedDB 实现、移动端走 SQLite 实现。
- **`Message`**（`shared/types.ts`）：由内容部件、文件与链接组成，并带生成中标记、压缩摘要与分支标记（`isSummary`、`isForkMarker` + `forkedFromSessionId`）。
- **`uiStore`**：持久化网页浏览与知识库绑定，并保留模式默认值与新会话临时状态；正式 Agent 模式落会话设置。`'new'` 假会话的待发送状态分散在本地 state、`newSessionState` 与通用 map 三处，首次发送时统一迁移。
- **生成中的消息**：UI 缓存更新与落盘分离，流式写协调器按消息身份安排检查点和最终写入，再经会话领域服务提交行存储；终态写入覆盖未完成检查点。见 `src/renderer/stores/session/messages.ts:181-236`。

## 专项导航

| 文档 | 承接内容 |
|---|---|
| [`../会话与消息管理/Chatbox-会话与消息管理调查笔记.md`](../会话与消息管理/Chatbox-会话与消息管理调查笔记.md) | 数据模型、会话生命周期、分页/索引检索、缓存一致性（原第 3/4/5 节） |
| [`../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md`](../对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md) | 流式主循环、2 秒节流落盘、上下文拼装、停止回写（原第 6 节） |
| [`<../Chat UI/Chatbox-ChatUI调查笔记.md>`](<../Chat UI/Chatbox-ChatUI调查笔记.md>) | 工作台、Composer、消息操作、无障碍、桌面集成及聊天相关弹窗/通知交点（10.1 节） |
| [`../消息渲染器/Chatbox-消息渲染调查笔记.md`](../消息渲染器/Chatbox-消息渲染调查笔记.md) | 消息模型、Markdown/结构化 part 渲染、消息列表虚拟化（既有独立笔记） |
| [`../应用界面基础设施/Chatbox-应用界面基础设施调查笔记.md`](../应用界面基础设施/Chatbox-应用界面基础设施调查笔记.md) | 弹窗三套技术栈、Toast 两套系统、主题、断点、动画、灯箱、openAboutDialog 死状态 |
| [`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md) | 跨项目对比：会话/消息存储与生命周期 |
| [`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md) | 跨项目对比：请求编排与上下文 |
| [`<../Chat UI/ChatUI横向对比.md>`](<../Chat UI/ChatUI横向对比.md>) | 跨项目对比：聊天界面与交互 |

## 关键能力与已确认边界

1. **分支（fork）**：重新生成或在新分支重试会产出消息级平行分支（`messageForksHash`）；`ForkNav` 在同一消息位置切换内容，替代回复可折叠进 `ForkGroup` 分支组。fork 与 thread 可叠加共存，两类分支的清理逻辑共享同一入口（`cleanupEmptyForkBranches`）。
2. **搜索**：`SearchDialog` 提供"当前会话/全部会话"两个入口，按消息模型扫描（覆盖 thread 历史与文本/reasoning/tool-call 状态），点击结果切换会话并 `scrollToMessage` 定位；无持久化倒排索引，跨会话按 IndexedDB 分页逐条扫描（每页 30，最多 50 条命中）。
3. **停止**：生成中消息的停止按钮调用其 `cancel()` 并以 `generating:false` 乐观写回；流结束/出错/暂停各补一次无条件落盘；停止时仍在运行的 tool-call 会被收口为 `error` 态并落盘，不再悬挂 `call` 状态。
4. **压缩**：自动压缩在消息上打 `isSummary` 标记，由 `SummaryMessage` 专用组件渲染，提供"删除摘要、恢复原文参与上下文计算"的操作；压缩以 `CompactionPoint`（boundary+summary 消息对）落盘，在 fork 分支切换与复制会话时做完整性重映射（`shared/context/compaction-points.ts`）。
5. **排序与归档边界**：拖拽排序仅在同一置顶分组内生效（`areSessionsInSamePinGroup` 只看 `starred`）；恢复归档会话不重置 `sortOrder`，会回到归档前位置；归档只置 `hidden`+`archivedAt`，不删除数据。
6. **并发落盘**：每会话一个 `UpdateQueue` 串行合并写入避免并发覆盖；批量归档刻意逐个走 `updateSession` 不做性能优化（代码注释明确承认）；`MAX_TOOL_CALLS_BEFORE_CONFIRMATION = 25` 表明 chat 与 agent 在实现上无清晰边界（该确认点可按会话或全局关闭，`pauseOnToolCallLimit`）。
7. **Work Mode 队列与 steering**：生成中输入最多排队 20 条并跨刷新保留；队列默认等当前回复结束，用户显式请求时，纯文本条目可先持久化为 `steered` 用户消息并进入当前生成后续 step。Chat Mode 不接受新队列项。详见对话请求与上下文、会话与消息管理及 Chat UI 笔记。
8. **Soul 与 Memories**：Work Mode 的人格、Copilot overlay、长期记忆和工作区指令按会话冻结；记忆工具可写入全局或 Copilot 独立 scope，但默认只影响未来会话。详见 Agent 角色与 Agent 工具笔记。

## 未验证事项

- 自定义压缩提示词、按发送上下文窗口压缩至最新消息和 prompt cache 删除确认的实际长会话体验未运行验证。
- provider 侧 token 截断策略与最终 HTTP JSON payload 字段未逐一核实。
- IndexedDB meta store 注释提到的"捕获 VersionError 后重试"兜底未见实现。
- UI 行为结论（视觉、键盘可用性、性能、平台行为）来自静态代码，未经运行验证。

## 关键源码索引

- `src/renderer/routes/index.tsx`：`'new'` 假会话与 `createPersistedChatSession` 迁移
- `src/renderer/routes/session/$sessionId.tsx`：会话页组装（Header → MessageList → InputBox）
- `src/renderer/components/session/SessionList.tsx`、`SessionItem.tsx`：分页列表、拖放排序、置顶/归档入口
- `src/renderer/components/chat/MessageList.tsx`：ThreadLabel、ForkNav、消息渲染调度
- `src/renderer/components/InputBox/InputBox.tsx`：Composer 与发送链入口
- `src/renderer/stores/session/`：会话 CRUD、缓存合并、归档/删除
- `packages/chatbox-core/src/application/session/SessionService.ts`、`RowBackedSessionRepository.ts`：会话应用服务与行存储读写
- `packages/chatbox-core/src/generation/GenerationService.ts`、`generation-flow.ts`、`stream-chunk-processor.ts`：生成编排与流式增量处理
- `src/renderer/stores/session/orchestration.ts`、`messages.ts`：流式主循环、节流落盘、streaming cache
- `src/renderer/storage/SessionMetaStorage.ts`：IndexedDB 分页/索引/游标
- `src/shared/types.ts`：`Session`/`Message`/`SessionThread`/`MessageForkEntry` 等 schema

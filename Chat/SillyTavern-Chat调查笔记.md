# SillyTavern Chat 概览

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：2026-08-07
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：只读源码，逐文件通读 + 针对性 grep 定位后再展开读取上下文
>
> 调查范围：聊天会话、消息构建、消息状态、存储、流式更新与交互机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 是自托管式 Web 聊天应用（浏览器客户端 + Node 服务端），聊天核心状态全部驻留前端内存：`chat` 是 `ChatMessage[]` 可变数组（`public/script.js:410`），连同 `chat_metadata`（`:453`）定期整份序列化到 JSONL 文件，无增量日志或数据库表。

聊天状态机、swipe、checkpoint/branch 与流式渲染主体都集中在 `public/script.js`；`chats.js` 只是消息级工具函数，`streaming-display.js` 是与主聊天渲染脱钩的悬浮组件。详细结论已迁移至专项，本概览只保留端到端地图与入口。

## 产品表面与系统边界

- 产品表面：Web 应用（桌面/移动浏览器 + PWA），服务端提供静态资源与 `/api` 路由，无原生客户端。
- 聊天形态：单人（`<user>/chats/<角色>/<name>.jsonl`）与群聊（`<user>/group chats/<id>.jsonl`）两种文件布局，JSONL 结构一致：首行 `chat_metadata` 头对象 + 每行一条 `ChatMessage`。
- 外部系统拥有：聊天文件、主题 JSON、群组 JSON 由 Node 服务端持久化（`src/endpoints/chats.js`、`src/endpoints/groups.js`）；模型推理由外部 LLM Provider 承担，SillyTavern 只拼装请求与消费流式返回。
- 不拥有：无服务端会话状态，聊天状态在浏览器内存中，文件只是存档。

## 端到端聊天主链

```text
用户输入 → sendTextareaMessage()（script.js:1705）→ Generate()（:4231，开头可被 slash command 整体劫持短路，processCommands :3066-3074）
→ 历史筛选与角色转换 → World Info 注入与 generation interceptors → 按 API 分支生成 text completion 或 OpenAI messages 结构
→ 流式/非流式请求发出 → 流式分支由 StreamingProcessor（:3481-3853）把清洗后的文本逐段写回占位消息 DOM 与 chat[]
→ 流结束触发 saveReply()（:6583）落定消息 → saveChat()（:7336-7421）整份写回 JSONL
→ 渲染入口 printMessages()（:1475）→ redisplayChat()（:1497）整体重绘 DOM
```

## 核心对象与状态权威

- `chat`（`script.js:410`）：消息事实源，所有渲染、生成、保存逻辑直接读写该数组。
- 消息关键字段：正文 `mes` 与 swipe 候选（`swipe_id`/`swipes`/`swipe_info`）。
- `ensureSwipes()`（`:6778`）负责老文件读取时懒惰补齐 swipe 数据。
- `chat_metadata`（`:453`）：
  - `main_chat`：checkpoint 回链；
  - `tainted`：是否脱离"纯净"首条问候语；
  - `integrity`：防并发覆写 UUID slug；
  - `attachments`。
- 群聊对象：成员/设置存 `<user>/groups/<id>.json`，`chats: string[]` 列出该群聊天文件；群聊消息用 `extra.gen_id` 标记同一轮生成。
- 持久化权威：服务端文件；加载时一次性整份读入内存（`getChat()` `:7575-7623`、`getGroupChat()` `group-chats.js:255-320`），无分页读取。
- 可见 UI 状态：`power_user` 设置、DOM 节点与 body 属性（如 `data-generating`）为展示层状态，不是消息事实源。

## 专项导航

- 会话与消息管理：[`../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md`](../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md)（加载判定、无虚拟化渲染、checkpoint/branch/swipe 数据语义、群聊差异、消息隐藏与附件）
- 对话请求与上下文：[`../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md`](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md)（Generate 主链、slash command 拦截、正则分层、宏与 Quick Reply 介入点）
- Chat UI：[`../Chat UI/SillyTavern-ChatUI调查笔记.md`](<../Chat UI/SillyTavern-ChatUI调查笔记.md>)（消息操作、swipe 工作流、生成反馈、快捷键、键盘可达性）
- 消息渲染：[`../消息渲染器/SillyTavern-消息渲染调查笔记.md`](../消息渲染器/SillyTavern-消息渲染调查笔记.md)
- 横向对比：[`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md)、[`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md)、[`../Chat UI/ChatUI横向对比.md`](<../Chat UI/ChatUI横向对比.md>)
- 应用界面基础设施（弹窗、Toastr、主题、无障碍等）：[`../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md`](../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md)

## 关键能力与已确认边界

- **Swipe**：消息级候选回复（`swipes` 并行数组），备选开场白复用 swipe 机制塞进第 0 条消息，Swipe Picker 支持从某个候选开分支；越界行为由 `getOverswipeBehavior()`（`:9163-9181`）状态机决定，四档取值：
  - `REGENERATE`、`LOOP`、`PRISTINE_GREETING`、`NONE`
- **Checkpoint 与 Branch 不对称**：共用"截断另存为新文件"的底层（`bookmarks.js`），但 checkpoint 不跳转、`extra.bookmark_link` 单值且新建覆盖；branch 必定跳转、`extra.branches` 数组追加、支持连同指定 swipe 版本截断。回到主聊天只能靠 `/checkpoint-exit` 手动切文件，无树状导航 UI。
- **流式渲染两套机制**：主聊天走 `StreamingProcessor`（直接写 `innerHTML`，流式期间隐藏 swipe 按钮，渲染事件只在流结束时 emit 一次）；`streaming-display.js` 是仅 `/profile-genstream` 使用的独立浮层，脱离 `chat[]`。
- **渲染模型非虚拟化**：默认只渲染最近 100 条（`power_user.chat_truncation`，`power-user.js:133`），"Show more"单向向前追加永不回收；`refreshSwipeButtons()`（`:9190-9249`）全量扫描已渲染 DOM。
- **并发保护**：服务端保存前比对文件首行 `chat_metadata.integrity` 与内存值，不一致抛 `IntegrityMismatchError`，前端弹窗要求手输 `OVERWRITE` 才强制覆盖，否则整页刷新。
- **群聊与单聊机制不同**：单聊重新生成靠 swipe 候选保留；群聊靠 `extra.gen_id` 分组 + 物理删除尾部消息再触发（`regenerateGroup()`，`group-chats.js:167-188`）；单聊转群聊是不可逆格式迁移（`bookmarks.js:328-441`）。

## 未验证事项

- `is_system`（隐藏消息）是否在 prompt 组装阶段被过滤，未追踪到具体构建函数验证。
- `extra.files`（消息内嵌附件）与 Data Bank 附件（`extension_settings.attachments` 等）在 World Info/prompt 注入层面的关系。
- `promptOnly` 正则脚本的具体调用点（仅从枚举值推断存在）。
- `StreamingProcessor` 缓存 DOM 引用失效与长聊天 `refreshSwipeButtons`/`redisplayChat` 性能，仅代码层分析，未运行时实测。
- 应用界面基础设施笔记中的无障碍、触屏体验等为静态代码结论，未做运行或读屏软件验证（见 [`../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md`](../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md)）。

## 关键源码索引

- `public/script.js`：`chat`/`chat_metadata`（410, 453）；`Generate()`（4231）；`saveReply()`（6583）；`saveChat()`（7336-7421）；`getChat()`/`getFirstMessage()`/`openCharacterChat`（7575-7693）；`printMessages`/`redisplayChat`/`showMoreMessages`（1431-1530）；swipe 全链路（9100-9329, 9894-10110）；`StreamingProcessor`（3481-3853）。
- `public/scripts/bookmarks.js`：checkpoint/branch/回主线（112-469）；`convertSoloToGroupChat`（328-441）。
- `public/scripts/group-chats.js`：`getGroupChat`/`saveGroupChat`（255-320, 623-675）；`regenerateGroup`（167-188）。
- `public/scripts/chats.js`：`hideChatMessageRange`（147-169）；附件/媒体处理（198-1120）。
- `src/endpoints/chats.js`：完整性检查与保存/读取路由（310-544, 797-872）。

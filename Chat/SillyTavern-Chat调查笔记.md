# SillyTavern Chat 概览

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`06bde939fb1e9c4c8d8641d810f0a916b5bce127`（分支：`release`）
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

- 产品表面：SillyTavern 的客户端就是浏览器页面，桌面与移动浏览器均可访问，也支持 PWA；Node 服务端负责提供静态资源与 `/api` 路由。
- 聊天形态：单聊与群聊各用一种文件布局，单聊落在 `<user>/chats/<角色>/<name>.jsonl`，群聊落在 `<user>/group chats/<id>.jsonl`；两者 JSONL 结构一致，首行是 `chat_metadata` 头对象，之后每行一条 `ChatMessage`。
- 外部系统拥有：聊天文件、主题 JSON 和群组 JSON 都由 Node 服务端负责持久化（`src/endpoints/chats.js`、`src/endpoints/groups.js`）；模型推理交给外部 LLM Provider，SillyTavern 只拼装请求并消费流式返回。
- 会话状态归属：服务端不保存会话状态，聊天状态驻留浏览器内存，磁盘文件承担存档角色。

## 端到端聊天主链

```text
用户输入 → sendTextareaMessage()（script.js:1705）→ Generate()（:4231，开头可被 slash command 整体劫持短路，processCommands :3066-3074）
→ 历史筛选与角色转换 → World Info 注入与 generation interceptors → 按 API 分支生成 text completion 或 OpenAI messages 结构
→ 流式/非流式请求发出 → 流式分支由 StreamingProcessor（:3481-3853）把清洗后的文本逐段写回占位消息 DOM 与 chat[]
→ 流结束触发 saveReply()（:6583）落定消息 → saveChat()（:7336-7421）整份写回 JSONL
→ 渲染入口 printMessages()（:1475）→ redisplayChat()（:1497）整体重绘 DOM
```

## 核心对象与状态权威

- 消息事实源是内存中的 `chat` 数组：渲染、生成与保存逻辑都直接读写它（`script.js:410`）。
- 每条消息用 `mes` 存正文，swipe 候选由 `swipes` 数组及配套的 `swipe_id`、`swipe_info` 字段共同表达。
- 读取旧聊天文件时，`ensureSwipes()` 才懒惰补齐缺失的 swipe 数据（`script.js:6778`）。
- `chat_metadata` 是随文件首行保存的头对象，承载四类元信息（`script.js:453`）：
  - `main_chat`：checkpoint 回链；
  - `tainted`：是否脱离"纯净"的首条问候语；
  - `integrity`：防并发覆写的 UUID slug；
  - `attachments`：附件。
- 群聊的成员与设置存在 `<user>/groups/<id>.json`，其中 `chats` 数组列出该群名下的聊天文件；群聊消息用 `extra.gen_id` 标记属于同一轮生成。
- 服务端文件是持久化权威；加载时整份文件一次读入内存，没有分页读取，单聊走 `getChat()`，群聊走 `getGroupChat()`（`script.js:7575-7623`、`group-chats.js:255-320`）。
- `power_user` 设置、DOM 节点与 body 上 `data-generating` 一类属性只服务于展示层，判断消息事实仍以 `chat` 数组为准。

## 专项导航

| 专项 | 笔记 | 覆盖内容 |
| --- | --- | --- |
| 会话与消息管理 | [SillyTavern-会话与消息管理调查笔记](../会话与消息管理/SillyTavern-会话与消息管理调查笔记.md) | 加载判定、无虚拟化渲染、checkpoint/branch/swipe 数据语义、群聊差异、消息隐藏与附件 |
| 对话请求与上下文 | [SillyTavern-对话请求与上下文调查笔记](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md) | Generate 主链、slash command 拦截、正则分层、宏与 Quick Reply 介入点 |
| Chat UI | [SillyTavern-ChatUI调查笔记](<../Chat UI/SillyTavern-ChatUI调查笔记.md>) | 消息操作、swipe 工作流、生成反馈、快捷键、键盘可达性 |
| 消息渲染 | [SillyTavern-消息渲染调查笔记](../消息渲染器/SillyTavern-消息渲染调查笔记.md) | — |
| 应用界面基础设施 | [SillyTavern-应用界面基础设施调查笔记](../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md) | 弹窗、Toastr、主题、无障碍等 |

横向对比笔记：[会话与消息管理](../会话与消息管理/会话与消息管理横向对比.md)、[对话请求与上下文](../对话请求与上下文/对话请求与上下文横向对比.md)、[Chat UI](<../Chat UI/ChatUI横向对比.md>)。

## 关键能力与已确认边界

- **Swipe**：每条消息都能保留多份候选回复，并列存放在 `swipes` 数组里；备选开场白沿用同一机制塞进第 0 条消息，Swipe Picker 可以从任一候选新开分支。继续越界时由 `getOverswipeBehavior()` 的状态机决定行为，共四档（`script.js:9163-9181`）：
  - `REGENERATE`、`LOOP`、`PRISTINE_GREETING`、`NONE`
- **Checkpoint 与 Branch 不对称**：两者共用"截断另存为新文件"的底层实现（`bookmarks.js`），差别在跳转与记录方式。checkpoint 停在原地，只把新文件记进 `extra.bookmark_link` 这个单值字段，再建一次就覆盖旧值；branch 立即跳转，把链接追加进 `extra.branches` 数组，还能连同指定的 swipe 版本一起截断。回到主聊天只能手动执行 `/checkpoint-exit` 切换文件，界面上没有树状导航。
- **流式渲染两套机制**：主聊天由 `StreamingProcessor` 负责，它把增量文本直接写进 `innerHTML`，流式期间隐藏 swipe 按钮，渲染事件到流结束才 emit 一次。另有一个独立浮层 `streaming-display.js`，只在 `/profile-genstream` 场景使用，与 `chat` 数组无关联。
- **渲染模型非虚拟化**：DOM 里默认只渲染最近 100 条消息，条数由 `power_user.chat_truncation` 控制；点 "Show more" 只向前追加，已渲染的节点不会回收。每次刷新 swipe 按钮，`refreshSwipeButtons()` 都要全量扫描已渲染 DOM（`power-user.js:133`、`script.js:9190-9249`）。
- **并发保护**：服务端写盘前比对文件首行的 `chat_metadata.integrity` 与内存值，对不上就抛 `IntegrityMismatchError`；前端随即弹窗，要求手动输入 `OVERWRITE` 才强制覆盖，取消则整页刷新。
- **群聊与单聊机制不同**：单聊重新生成时把旧回复留作 swipe 候选；群聊则用 `extra.gen_id` 分组，再物理删除尾部消息触发重生成，入口是 `regenerateGroup()`（`group-chats.js:167-188`）。单聊转群聊是一次不可逆的格式迁移（`bookmarks.js:328-441`）。

## 未验证事项

- 带 `is_system` 标记的隐藏消息是否会在 prompt 组装阶段被过滤，本次没有追踪到具体的构建函数来验证。
- 消息内嵌附件（`extra.files`）与 Data Bank 附件（`extension_settings.attachments` 等）在 World Info 和 prompt 注入层面如何相互作用，尚未厘清。
- 正则脚本的 `promptOnly` 选项在何处生效，目前只从枚举值推断它存在，未定位到实际调用点。
- 流式渲染缓存的 DOM 引用何时失效，以及长聊天时 `refreshSwipeButtons()`、`redisplayChat()` 的性能，仅有代码层分析，未做运行时实测。
- 应用界面基础设施笔记中的无障碍、触屏体验等结论来自静态代码阅读，未在真机或读屏软件上验证（见 [应用界面基础设施调查笔记](../应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md)）。

## 关键源码索引

- `public/script.js`：`chat`/`chat_metadata`（410, 453）；`Generate()`（4231）；`saveReply()`（6583）；`saveChat()`（7336-7421）；`getChat()`/`getFirstMessage()`/`openCharacterChat`（7575-7693）；`printMessages`/`redisplayChat`/`showMoreMessages`（1431-1530）；swipe 全链路（9100-9329, 9894-10110）；`StreamingProcessor`（3481-3853）。
- `public/scripts/bookmarks.js`：checkpoint/branch/回主线（112-469）；`convertSoloToGroupChat`（328-441）。
- `public/scripts/group-chats.js`：`getGroupChat`/`saveGroupChat`（255-320, 623-675）；`regenerateGroup`（167-188）。
- `public/scripts/chats.js`：`hideChatMessageRange`（147-169）；附件/媒体处理（198-1120）。
- `src/endpoints/chats.js`：完整性检查与保存/读取路由（310-544, 797-872）。

# SillyTavern 会话与消息管理调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：直接阅读源码（前端 JS 脚本、服务端端点 `src/endpoints/chats.js`/`groups.js`/`characters.js`、IndexedDB/localStorage 客户端存储），针对全部必查问题逐一核对当前 HEAD 的可执行路径
>
> 调查范围：聊天/群聊/checkpoint/branch/swipe 的数据模型与 JSONL 持久化、加载与保存链、消息操作数据语义、聊天列表与搜索、一致性机制、导入导出与格式转换、附件与外部对象绑定；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的"聊天"是**内存可变数组 + 定期整份序列化到 JSONL 文件**的模型，不是增量事件日志或数据库表：

- 运行时事实源是 `chat: ChatMessage[]`（`public/script.js:410`）与 `chat_metadata`（`public/script.js:453`），全部渲染、生成、保存逻辑直接读写该数组；消息没有持久化全局 ID，`mesid` 是数组下标（DOM 属性由 `updateViewMessageIds` 维护，`public/script.js:9407`）。
- 单人聊天与群聊是两个存储位置，JSONL 文件格式一致：首行头对象 `{chat_metadata, user_name:'unused', character_name:'unused'}` + 每行一条消息；加载时一次性整份读入内存与 DOM（`getChat` `public/script.js:7575-7623`、`getGroupChat` `public/scripts/group-chats.js:255-320`），没有分页读取或流式解析。
- 服务端保存带 `integrity` 完整性检查（配置项 `backups.chat.checkIntegrity` 默认 true，`src/endpoints/chats.js:29`）：不一致抛 `IntegrityMismatchError` 返回 `{error:'integrity'}`，前端弹窗要求手输 `OVERWRITE` 才强制覆盖，否则整页刷新（`public/script.js:7400-7416`）。
- **checkpoint 与 branch 共用"截断另存为新文件"逻辑**（`public/scripts/bookmarks.js`），区别：checkpoint 不跳转、`extra.bookmark_link` 单值且新建覆盖；branch 必定跳转、`extra.branches` 数组追加、支持连同指定 swipe 版本截断。
- swipe 是消息级候选版本机制：`mes`/`swipe_id`/`swipes`/`swipe_info` 四字段并行，`ensureSwipes` 对老文件惰性补齐（`public/script.js:6778-6828`）。
- 除 JSONL 外还有三类客户端旁路存储：IndexedDB（localforage，`SillyTavern_Prompts` 库）存 itemized prompt 与 token 缓存；localStorage 存草稿、置顶聊天等 UI 状态；sessionStorage 存"无角色临时聊天"。它们都不是消息事实源。

## 系统边界与数据主链

```text
openCharacterChat(file_name) / openGroupChat(groupId, chatId)（bookmarks.js:449-469 等入口）
  -> clearChat({clearData:true}) 清空内存与 DOM（script.js:1584-1603）
  -> getChat()（script.js:7575）/ getGroupChat()（group-chats.js:255）
       -> /api/chats/get 或 /api/chats/group/get 一次性读完整 JSONL（服务端 getChatData，chats.js:502-515）
       -> data.shift() 摘头对象得到 chat_metadata
       -> 空文件时 getFirstMessage() 现造问候语（备选开场白直接塞成 swipes 数组，script.js:7651-7683）
       -> chat_metadata.integrity 缺失时客户端生成 uuidv4（script.js:7606-7608）
  -> 内存 chat[] 为运行时事实源，渲染/生成/保存都读写它
  -> saveChatConditional()（script.js:9352-9379）串行执行：
       -> saveChat()（script.js:7336）/ saveGroupChat()（group-chats.js:623）
       -> 服务端 trySaveChat()（src/endpoints/chats.js:457-468）：读文件首行比对 integrity -> 整份写回 JSONL + 节流备份
       -> 另存 IndexedDB：saveTokenCache() + saveItemizedPrompts(getCurrentChatId())（script.js:9372-9373）
```

边界：生成请求如何构建（`Generate()` 的历史筛选、注入与 provider 分支）在对话请求与上下文；消息如何进 DOM（`printMessages`/`redisplayChat` 首屏 100 条截断、`StreamingProcessor` 流式写回、正则渲染层）在消息渲染器；swipe 按钮、Swipe Picker、checkpoint 旗标等用户工作流在 Chat UI。

## 1. 会话单位与消息数据模型

### 1.1 会话单位

| 单位 | 表示 | 标识生成 |
|---|---|---|
| 单人聊天 | `<user>/chats/<角色avatar去.png>/<name>.jsonl`（`src/endpoints/chats.js:476`） | 新聊天名 `"${name2} - ${humanizedDateTime()}"`（`doNewChat`，`public/script.js:10581`） |
| 群聊文件 | `<user>/group chats/<id>.jsonl` 扁平目录（`src/endpoints/chats.js:803, 855`） | `humanizedDateTime()` 字符串（`createNewGroupChat`，`group-chats.js:2147`） |
| 群组本体 | `<user>/groups/<id>.json`，含 `members`、`chat_id`、`chats: string[]` | `/api/groups/create` 生成（`src/endpoints/groups.js:156`） |
| checkpoint/branch | 上述目录中的独立聊天文件 | `"<原名> - Checkpoint #N"` / `"<原名> - Branch #N"`（`bookmarks.js:89-95, 207-213`） |

角色对象（角色卡 JSON）保存 `chat` 字段指向当前聊天文件名（`src/endpoints/characters.js:375, 489`），群组对象保存 `chat_id` 与全部历史聊天 id 列表；因此"当前会话指针"属于角色/群组实体，聊天文件本身不含回链（checkpoint 文件例外，靠 `chat_metadata.main_chat` 回链主聊天）。

### 1.2 消息模型

消息是**线性数组中的扁平对象**，不是树、父子 part 或事件日志。稳定字段（`saveReply` 构造，`public/script.js:6684-6701`）：

- `name`/`is_user`/`is_system`/`send_date`：角色名、user/assistant 角色、是否系统消息（隐藏消息即 `is_system=true`）、时间戳；
- `mes`：正文；`title`：工具提示；
- `gen_started`/`gen_finished`：生成起止时间；
- `extra`：自由形态对象，按用途分几类——
  - 生成来源快照：`api`/`model`；
  - 内容扩展：`reasoning`（思考链）、`token_count`、`bias`；
  - 附件与工具：`media`/`files`（附件）、`tool_invocations`（工具调用）；
  - 群聊与系统消息：`gen_id`（群聊生成批次）、`isSmallSys`（小型系统消息）、`type`（narrator 等系统消息类型）；
  - swipe 行为覆盖：`overswipe_behavior`/`swipeable`。
- swipe 四字段：
  - `mes`：当前显示正文，是 `swipes[swipe_id]` 的镜像；
  - `swipe_id`：当前候选下标；
  - `swipes: string[]`：候选版本；
  - `swipe_info`：与 `swipes` 等长的 `{send_date, gen_started, gen_finished, extra}` 数组。

`ensureSwipes(message)`（`public/script.js:6778-6828`）负责老文件字段的惰性补齐：

- 消息缺失字段时用当前 `mes` 现造长度为 1 的数组；
- `swipes[i]` 类型不对时强制纠正为空串；
- 用户消息与 `extra.isSmallSys` 消息显式排除在 swipe 体系外（6787-6789）。

### 1.3 Swipe 同步方向

两个方向职责严格分离：

- `syncMesToSwipe(messageId)`（`public/script.js:6837-6883`）：把当前 `mes`/时间戳/`extra` 写回 `swipes[swipe_id]`/`swipe_info[swipe_id]`。仅在 `chat_metadata.tainted || chat.length > 1` 时才写回 `swipes[swipe_id]`（6873），注释说明这是为了让"纯净首条问候语"在每次进聊天时宏还能重新解析——第 0 条消息在全新状态下故意不落盘同步。
- `syncSwipeToMes(messageId, swipeId, targetMessage)`（`public/script.js:6895-6959`）：反方向，把 `swipes[swipeId]` 读出来覆盖 `mes`/时间戳/`extra`。支持传 `targetMessage` 操作游离对象——branch 快照选 swipe 复用此路径。

`deleteSwipe(swipeId, messageId)`（`public/script.js:9279-9345`）：至少保留 1 个 swipe；删除后按"删的是否当前选中项"重算 `swipe_id`；删除后置 `chat_metadata.tainted = true`（9323）。

## 2. 事实源、索引与持久化

### 2.1 三种存储的权威关系

- **JSONL 文件（服务端）**：持久化权威。服务端只做整文件读写（`getChatData` 逐行 parse，`src/endpoints/chats.js:502-515`）与首行 integrity 比对，不解析消息结构。
- **内存 `chat[]`**：运行时事实源。服务端文件在加载时整份灌入（`chat.splice(0, chat.length, ...data)`，`public/script.js:7599`），此后所有修改直接作用于数组。
- **IndexedDB（localforage 实例 `SillyTavern_Prompts`）**：存 itemized prompt（每条消息的 raw prompt 与 token 分项）与 token 计数缓存，key 为聊天名（`public/scripts/itemized-prompts.js:15, 46-57`；`saveTokenCache` `public/scripts/tokenizers.js:181`）。聊天删除时同步清除（`itemized-prompts.js:352-357`）。这是可重建的派生数据，不是消息事实源。

### 2.2 加载与保存链

- 保存：`saveChatConditional()`（`public/script.js:9352-9379`）先用 `isChatSaving` 互斥等待上一次保存结束，再按群聊/单聊分发 `saveGroupChat`/`saveChat`，结束后写 IndexedDB 缓存。`saveChatDebounced()`（7302-7323）以 1000ms 防抖调用它，并在超时回调里校验 `this_chid`/`selected_group` 未变（防止切换后误写旧聊天）。
- 服务端 `trySaveChat()`（`src/endpoints/chats.js:457-468`）分四步：
  1. 序列化整数组；
  2. `checkChatIntegrity`（316-335，读文件首行比对 slug，文件不存在或无 integrity 字段视为通过）；
  3. 原子写文件（`write-file-atomic`）；
  4. 节流备份（`backupChat` 41-61，每用户节流 10s，`_` 前缀 + 时间戳，受 `backups.chat.*` 配置控制）。
- 加载：`/api/chats/get`（服务端 517-544）与 `/group/get`（797-806）返回整文件数组；前端 `getChatResult()`（7625-7649）在 `chat.length === 0` 时调 `getFirstMessage()` 造问候语并 `saveChatConditional()` 让文件首次落盘，随后发 `CHAT_CHANGED`，全新聊天再发 `CHAT_CREATED`（7641-7642）。
- 群聊加载（`getGroupChat`，`group-chats.js:255-320`）：先 `validateGroup`（剔除不存在的成员、去重 chat id，218-247），`freshChat = !metadata.tainted && 无数据` 时遍历 `group.members` 为每个成员各造一条首条消息并立即 `saveGroupChat`（283-304）。

### 2.3 无索引结构

聊天消息没有任何索引表：checkpoint 定位靠 `Object.entries(chat)` 全数组扫描（`/checkpoint-list`，`bookmarks.js:654-658`）；消息 ID 靠数组下标连续反推 DOM 顺序（渲染侧假设，见消息渲染器笔记）。token/上下文统计的"索引"即 IndexedDB 中的 itemized prompts，也是按消息下标关联的派生缓存。

## 3. 创建、切换、归档、删除与恢复

- **新建**：`doNewChat`（`public/script.js:10558-10587`）先确认弹窗（含"同时删除当前聊天"勾选，11554-11561），然后按类型分两条路：
  - 单聊：改 `characters[this_chid].chat` 为新文件名后 `getChat()` 走首次落盘；
  - 群聊：`createNewGroupChat`（`group-chats.js:2139-2154`，push 进 `group.chats` 并 `editGroup` 落盘群组 JSON）。
- **惰性创建**：进入新角色聊天时 `getChatResult()` 在空文件分支现造问候语（见 2.2）；`openCharacterChat`（7685-7693）与 `openGroupChat`（2194-2209）都先 `clearChat({clearData:true})` 清空再加载。
- **切换**：角色与群聊分别处理——
  - 角色列表点击 `selectCharacterById`（873-907，`isChatSaving`/`is_send_press` 期间拒绝切换）；
  - 群聊切换 `openGroupById`/`select_group_chats`（group-chats.js:2017, 1802）。
  - 切换本身不触发保存，依赖切换前各操作的 `saveChatConditional`/`saveChatDebounced` 完成。
- **重命名**：`/api/chats/rename`（`src/endpoints/chats.js:546-577`）用"复制新文件 + 删旧文件"实现；前端 `renameGroupOrCharacterChat`（10598+）同时更新群组 `chats` 数组或角色 `chat` 指针，并同步更新置顶条目（`welcome-screen.js:947`）。
- **删除**：单聊与群聊各自处理——
  - 单聊：`delChat`（1336）走 `/api/chats/delete`（`src/endpoints/chats.js:579-602`）；
  - 群聊：`deleteGroupChatByName`（`group-chats.js:2241-2268`）删文件并从 `group.chats` 移除，若删的是当前聊天则切到列表最后一个，若列表空则新造 `humanizedDateTime()` 名；
  - 清理：删除后发 `GROUP_CHAT_DELETED`/`CHAT_DELETED`，IndexedDB itemized prompts 随之清除（`itemized-prompts.js:352-357`）。
- **归档**：本次未找到"归档/置顶聊天"的持久化对象——欢迎屏的 pinned 是"最近聊天列表置顶"（`PinnedChatsManager`，`welcome-screen.js:83-202`，存 accountStorage），不是消息文件的归档标记。
- **恢复**：聊天文件损坏时 `getChatData` 只丢弃解析失败的行；空文件按新聊天处理。崩溃恢复无专门机制（见未验证事项）。"无角色临时聊天"在切换时用 sessionStorage 保存/恢复（`preserveNeutralChat`/`restoreNeutralChat`，`public/scripts/chats.js:1857-1879`，调用点 `public/script.js:1684, 1693`），只跨导航不跨会话。

## 4. 编辑、重试、续写、回退与分支语义

| 操作 | 数据语义 |
|---|---|
| 编辑消息 | 原地修改：`updateMessage` 写回 `mes.mes` 并同步 `mes.swipes[swipe_id]`（`public/script.js:8080-8124`），`messageEditDone` 后 `saveChatConditional`（8373）；不产生新版本 |
| 删除消息 | `deleteMessage` 从 `chat` splice + 同步 DOM + `deleteItemizedPromptForMessage` + `saveChatDebounced`（1618-1672）；编辑态删除可选"只删当前 swipe" |
| 复制消息 | `mes_edit_copy` 用 `structuredClone` 复制消息插入编辑位之后（11895-11920），新建 `send_date`，保留 swipe 结构 |
| 重新生成 | 单聊 `Generate('regenerate')` 在 `Generate` 内 `removeLastMessage` 删掉旧回复再生成（4344-4353）；群聊 `regenerateGroup` 按 `extra.gen_id` 分组删尾部（见 6） |
| 续写 | `Generate('continue')` 不删消息，`saveReply` 的 append/appendFinal 分支在 `mes` 后追加（6638-6681），swipes 同步到当前候选 |
| 回退/分支/checkpoint | 见下节；"回退到旧消息"没有独立对象，只能通过 swipe 候选（消息内）或 checkpoint/branch（聊天文件）表达 |

### 4.1 Checkpoint（`createNewBookmark`，`bookmarks.js:253-298`）

`saveChat({chatName: name, withMetadata: newMetadata, mesId})` 内部用 `chat.slice(0, Number(mesId)+1)` 截断另存新文件（`public/script.js:7362-7366`），当前主聊天不受影响。其余语义分三点：

- **回链**：触发消息的 `extra.bookmark_link = name` 记回链（bookmarks.js:290），随后 `saveChatConditional()` 把该字段写回主聊天文件；
- **覆盖**：多次在同一条消息建 checkpoint 会覆盖旧 `bookmark_link`（273 行的 `isReplace` 只改弹窗文案，逻辑上直接覆盖，无历史列表）；
- **父聊天记录**：`chat_metadata.main_chat` 记录父聊天名；老版本 checkpoint 文件无此字段时由 `getMainChatName` 从文件名 `"xxx - Checkpoint #N"` 推断并回填（bookmarks.js:119-122）。

### 4.2 Branch（`createBranch`/`branchChat`，`bookmarks.js:186-243, 449-469`）

快照函数 `getBranchChatSnapshot(mesId, {swipeId})`（171-183）`structuredClone(chat.slice(0, mesId+1))`，若指定 `swipeId` 则用 `syncSwipeToMes(null, swipeId, snapshot[mesId])` 把快照最后一条替换成该候选版本——操作游离对象，不碰真实 `chat[]`。与 checkpoint 的三点差异：

1. 支持连同具体 swipe 版本截断（swipeId 参数）；
2. 保存后向触发消息 `extra.branches` **数组**追加分支文件名（233-241），可一条消息开多个分支；
3. `branchChat` 保存成功后**必定跳转**（`openGroupChat`/`openCharacterChat`，462-466），与 checkpoint 不跳转形成对照。

两者都不支持"合并回主线"：回到主聊天只能靠 `/checkpoint-exit`（`backToMainChat`，bookmarks.js:312-326）依赖 `chat_metadata.main_chat` 手动切文件，没有树状导航。分支/checkpoint 全部入口（旗标、Swipe Picker、`/branch-create`、`/checkpoint-create` 等 slash command）最终汇到 `createBranch`/`createNewBookmark`。

## 5. 列表、分页、搜索与定位

- **最近聊天列表**：`/api/chats/recent`（`src/endpoints/chats.js:979-1077`）扫描角色聊天目录 + 群聊文件 + 根目录三处，按 mtime 排序、pinned 优先，逐文件 `getChatInfo`（359-431，readline 流式读首行元数据与最后一条消息，不整读文件）得到文件大小/消息数/最后消息/预览。欢迎屏消费它（`welcome-screen.js:763-817`），折叠阈值 `collapsedDisplayed`。
- **单个角色的聊天列表**：`/api/characters/chats`（`src/endpoints/characters.js:1497-1533`），`simple` 模式只回文件名数组。
- **搜索**：`/api/chats/search`（`src/endpoints/chats.js:874-977`）在**单个角色的聊天目录或单个群组的 chats 列表**范围内按查询词过滤：`getChatInfo` 逐行把 `mes` 累积成缓冲交给 `hasTextMatch`（所有词都出现在同一缓冲内即命中），结果含 `preview_message`（最后 400 字符）。本次未找到跨角色/全局的聊天内容搜索入口。- **分页**：消息读取与保存均不分页；渲染层"首屏 100 条 + Show more"只是显示截断（`power_user.chat_truncation` 默认 100，`public/scripts/power-user.js:133`，渲染细节在消息渲染器笔记）。
- **定位**：搜索命中后跳转目标聊天靠 `displayPastChats` 的 `highlightNames` 参数滚动定位（`public/script.js:8560-8564`）。

## 6. 缓存、一致性、多窗口与并发写入

- **防抖与串行**：`saveChatConditional` 用 `isChatSaving` 互斥（9354-9363）；`saveChatDebounced` 1000ms 防抖且带 chid/group 变更守卫（7308-7317）；`swipe()` 开始时 `cancelDebouncedChatSave()` 防过期写入覆盖 swipe_id（9932-9933）。
- **跨窗口/多端**：无实时同步。保护机制是服务端 integrity 比对 + 前端 `OVERWRITE` 强制覆盖流程（`public/script.js:7394-7416`，群聊同款 `group-chats.js:644-669`）。两个标签页各自持有自己的 `chat_metadata.integrity`（加载时缺失才生成），后保存者若文件已被对方改写则被拒。
- **加载期间的写保护**：`openCharacterChat` 等待 `!isChatSaving` 才清空（7686）；`selectCharacterById` 在保存中拒绝切换（878-881）。
- **流式临时状态**：流式生成把文本逐 token 写内存 `chat[messageId].mes`（`StreamingProcessor.onProgressStreaming`，3624），只有流结束才 `saveChatConditional`（3756）；中途停止/错误不落盘半截消息。`beforeunload` 只 `onStopStreaming()` 不做保存（12401-12407）。
- **IndexedDB 一致性**：itemized prompts 在 `clearChat` 时先存后清（1599-1600），`deleteItemizedPromptForMessage` 负责下标移位（`itemized-prompts.js:389-398`），与消息删除同点调用。

## 7. 格式转换、导入导出与保留策略

- **旧格式字段惰性补齐（客户端）**：`ensureSwipes`（见 1.2）、`ensureMessageMediaIsArray`（1991）、`swipe_info` 回填（`syncSwipeToMes` 6931-6939）都在读取/使用路径上补齐老文件字段，不改文件本身直到下次保存。
- **服务端格式升级**：`migrateGroupChatsMetadataFormat`（`src/endpoints/groups.js:34-90`）启动时执行（`server-main.js:302`），把群组 JSON 中废弃的 `chat_metadata`/`past_metadata` 逐聊天转移到各自 JSONL 首行头对象，转换前备份到 `backups/_group_metadata_update/`。
- **导入**：`/api/chats/import`（`src/endpoints/chats.js:696-795`）支持 jsonl（含 Chub 格式的 `mes`/`swipes` 扁平化，258-279）与 json（按结构识别 Ooba、Agnai、CAI Tools、Kobold Lite、RisuAI 五种格式，110-308），统一输出头对象 + 消息行的 JSONL。
- **导出**：`/api/chats/export`（604-674）jsonl 原样导出或文本模式（跳过 `is_system` 行，用 `extra.display_text || mes`）。
- **单聊转群聊**：`convertSoloToGroupChat`（`bookmarks.js:328-441`）一次性不可逆转换（确认文案明确"This cannot be reverted"，339），给非用户/系统消息写 `force_avatar`/`original_avatar`/`extra.gen_id`（400-419）。
- **备份**：每次保存节流备份到 `<user>/backups/`（`backupChat`，`src/endpoints/chats.js:41-61`），`maxTotalBackups` 负值不限制总数；恢复入口是聊天历史弹窗里的 Chat Backups 浏览器（`public/scripts/chat-backups.js:326`，调 `/api/backups/chat/get|delete|download`，`src/endpoints/backups.js:9-54`）。

## 8. 外部对象绑定与附件

- **角色**：角色 JSON 持有 `chat`（当前聊天文件名）与 `date_last_chat`（`src/endpoints/characters.js:375, 423`），即会话级绑定，保存的是文件引用而非消息快照；角色级附件在 `extension_settings.character_attachments[avatar]`（见下）。
- **群组**：群组 JSON 持有 `members`（avatar id 数组）、`chat_id`、`chats` 数组（`group-chats.js:255-320` 读写）；消息级绑定 `force_avatar`/`original_avatar`/`extra.gen_id` 在转群聊或群聊生成时写入（`public/script.js:6714-6716`）。
- **模型/渠道**：消息保存 `extra.api`/`extra.model` **历史快照**（`saveReply`，6690-6691），不保存渠道引用；后续请求不读取这些字段回放，仅用于展示与 reasoning 签名校验（`openai.js:615-621`）。
- **消息附件**：两类附件都存 URL 引用，内容在 prompt 组装时展开进消息文本——
  - 图片：`extra.media: MediaAttachment[]`（`switchMessageMediaDisplay`/`expandMessageMedia`，`public/scripts/chats.js:875-1067`）；
  - 文件：`extra.files: FileAttachment[]`（`populateFileAttachment`/`deleteMessageFile`，`public/scripts/chats.js:198-427`）；
  - 展开：文件内容经 `appendFileContent` 进入消息文本（调用点 `public/script.js:4448`）。
- **Data Bank（知识库）**：附件管理器的三个作用域——
  - 全局：`extension_settings.attachments`；
  - 角色：`extension_settings.character_attachments[avatar]`；
  - 聊天：`chat_metadata.attachments`（`ATTACHMENT_SOURCE`，`public/scripts/chats.js:77-81`；读写 1488-1492, 1733-1742, 1779-1804）。
  - **注入路径已核实**：Data Bank 文件不直接进 prompt，而是由 vectors 扩展摄取进向量索引（`extensions/vectors/index.js:644-669` 的 `ingestDataBankAttachments`，`EXTENSION_PROMPT_TAG_DB = '4_vectors_data_bank'` 第 53 行），生成时按查询检索注入为 `extension_prompts['4_vectors_data_bank']` 块（第 582-586 行；`public/script.js:5291` 记录到 itemized prompt）。
  - 这与消息级 `extra.files` 是两套并行体系：消息文件随消息文本注入，Data Bank 文件经向量检索注入。

## 9. 设计取舍与已确认边界

- **整份读写、无分页、无索引**：文件一次性读入内存和 DOM，长聊天读写/渲染成本线性增长；checkpoint 定位靠全数组扫描；消息 ID 靠数组下标，删除后需全局 `updateViewMessageIds` 维护 DOM 一致性。
- **integrity 防并发覆写**：以"弹窗手输 OVERWRITE"换取多标签页/多设备数据安全，交互代价高；跨窗口实时同步不存在。
- **checkpoint/branch 不对称**：单值覆盖 vs 数组追加，是有意的数据设计差异（4.1/4.2）。
- **群聊与单聊的"重新生成"是两套机制**：
  - 单聊：swipe 保留候选（`swipes` 数组）；
  - 群聊：`regenerateGroup` 按 `extra.gen_id` 分组物理删除尾部消息再触发（`group-chats.js:167-188`，`gen_id = Date.now()` 批次号在 `generateGroupWrapper` 988 行生成）。
- **"纯净问候语"特例**：`tainted` 标记在多处写入（`public/script.js:1659, 4288, 5846, 8131, 9323, 11669`），控制首条问候语的宏重解析与 overswipe 循环行为。
- **类目边界**：本笔记只回答数据语义；`Generate()` 的请求构建在对话请求与上下文；swipe/Swipe Picker/checkpoint 旗标用户工作流在 Chat UI；DOM 渲染与流式更新在消息渲染器笔记。

## 10. 未验证事项

- 崩溃恢复（保存中断、文件损坏、浏览器强杀）行为未实测；静态代码显示流式中途的消息不落盘、`getChatData` 静默丢弃解析失败的行。
- 多标签页同时写入的竞争窗口未实测（integrity 检查与写入之间仍有 TOCTOU 窗口）。
- 大文件下 `/api/chats/search` 逐文件流式扫描的性能未实测。
- 导入格式转换（Ooba/Agnai/CAI/Kobold Lite/Risu/Chub）只核实了转换函数存在与调用入口，未逐格式用样本文件验证。

## 11. 关键源码索引

- `public/script.js`：`chat`/`chat_metadata`（410, 453）；`saveChat`（7336-7421）；`saveChatDebounced`（7302-7323）；`saveChatConditional`（9352-9379）；`getChat`/`getChatResult`/`getFirstMessage`/`openCharacterChat`（7575-7693）；`ensureSwipes`/`syncMesToSwipe`/`syncSwipeToMes`（6778-6959）；`saveReply`（6583-6771）；`deleteSwipe`（9279-9345）；`deleteMessage`（1618-1672）；`doNewChat`/`renameGroupOrCharacterChat`（10558-10679）；`updateMessage`（8080-8124）
- `public/scripts/bookmarks.js`：`getBranchChatSnapshot`/`createBranch`（171-243）；`createNewBookmark`/`backToMainChat`（253-326）；`branchChat`（449-469）；`convertSoloToGroupChat`（328-441）；slash commands 与 `initBookmarks`（471-737）
- `public/scripts/group-chats.js`：`getGroupChat`（255-320）；`saveGroupChat`（623-675）；`regenerateGroup`（167-188）；`generateGroupWrapper`（945-1092）；聊天 CRUD（2139-2268）
- `public/scripts/chats.js`：`hideChatMessageRange`（147-169）；附件上传/删除/媒体（198-1120）；Data Bank（1334-1804）
- `public/scripts/itemized-prompts.js`：IndexedDB 存储（15-57, 83-107）
- `src/endpoints/chats.js`：`trySaveChat`/`checkChatIntegrity`/`getChatData`/`getChatInfo`（316-515）；`/save` `/get` `/rename` `/delete` `/import` `/export`（470-795）；`/group/*`（797-872）；`/search` `/recent`（874-1077）
- `src/endpoints/groups.js`：群组 CRUD（113-203）；元数据格式升级（34-90）
- `src/endpoints/characters.js`：`/chats`（1497-1533）

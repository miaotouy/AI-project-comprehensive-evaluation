# Risuai 会话与消息管理调查笔记

> 调查对象：`E:\works\GitStudyNotes\Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：直接阅读源码（`src/ts/storage` 持久化层、`globalApi.svelte.ts` 的保存循环、`bootstrap.ts` 加载主链、`process/index.svelte.ts` 生成入口、UI 层 Chat/DefaultChatScreen/SideChatList/ChatList、冷存储、角色与聊天导入导出、多用户同步），针对必查问题逐一核对当前 HEAD 的可执行路径；本次为静态调查，未运行应用
>
> 调查范围：会话/消息/分支/reroll/冷存储的数据模型、.bin 保存格式与事实源、加载与格式迁移、删除与恢复、导入导出边界、多窗口与多端一致性；生成请求的上下文拼装与流式事件、界面操作的具体交互流程分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 的会话与消息没有独立持久化单位，而是**整库单文件（.bin）+ 内存响应式状态**的模型：

- 角色（含群聊）对象内嵌 `chats: Chat[]` 数组，`chatPage` 下标即"当前会话指针"（`database.svelte.ts:1817-1839`，`character.chats`）；会话 `id` 为 UUID，由启动时的 `assignIds` 补齐与去重（`bootstrap.ts:645-671`）。
- 消息是**线性数组中的扁平对象**：`role: 'user'|'char'`、`data`、`saying`（说话角色 chaId）、`chatId`、`time`、`generationInfo`/`promptInfo` 快照、`disabled`（含 'allBefore' 语义）、`isComment`（`database.svelte.ts:1848-1860`）；无 swipe/版本字段。
- 运行时与持久化事实源都是 `DBState.db` 这一个响应式内存对象：`saveDb()`（`globalApi.svelte.ts:292-486`）用 `$effect` 快照监听变化，500ms 防抖后由 `RisuSaveEncoder` 做**块级增量编码**（root 块 + 每角色一块），整库重写为 `database/database.bin`，并每次保存都额外写一份 `dbbackup-<ts>.bin`（保留 20 份）。加载失败时按时间倒序尝试备份。
- 分支 = **复制整个会话对象并截断**，再在尾部插入一条 `isComment` 的 `branchedfrom` 特殊注释消息作为回链；父会话不记录子分支。分支导航视图由 `getChatBranches` 对消息内容哈希做前缀树**实时计算**，不依赖持久化元数据（`gui/branches.ts:69-93`）。
- Reroll（重生成）是**纯内存候选机制**：候选文本挂在 `process/prereroll.ts` 的 `Map<generationId, string[]>` 上，切换时原地替换最后一条消息的 `data`，候选不落盘；没有候选时则物理删除尾部 char 消息后重新生成。
- 冷存储（Cold Storage）是自动归档机制：角色 10 天未交互或会话 10 天无新消息（且 ≥4 条）时，把消息等数据外置到 Tauri 文件/OPFS/账户远端，原地留下带 `COLDSTORAGE` 头的占位消息，打开时惰性恢复（`process/coldstorage.svelte.ts`）。
- 本次未找到会话/消息内容搜索能力（检查范围见第 5 节）；多窗口一致性靠 `BroadcastChannel` 互斥让后到标签页刷新，无落盘合并（见第 6 节）。

## 系统边界与数据主链

```text
bootstrap.loadData()（bootstrap.ts:55-269）
  -> Tauri: 读 AppData/database/database.bin（fetch assetUrl） / Web: forageStorage 读 'database/database.bin'
  -> decodeRisuSave()（risuSave.ts:623-667）：按魔数头分派 4 种编码（msgpack raw/compressed/stream + RISUSAVE 块式）
  -> setDatabase() 补默认值 -> checkNewFormat() 逐版本迁移（formatversion -> 5）
  -> assignIds() 补 chaId/chat.id -> makeColdData() 归档过期数据 -> cleanChunks() 清理孤儿资源
  -> saveDb() 常驻循环（$effect 监听 -> 500ms 防抖 -> 块级重编码 -> 整库写回 + 备份）
```

保存主链（`globalApi.svelte.ts:292-486`）：`saveDb()` 对 `DBState.db` 建 `$effect`，快照读取除大块外的全部字段与"当前角色"（`selIdState`）的所有字段和 `chats` 数组；任一变化经 500ms 防抖置 `changed`。变化只记录最近修改的 `[chaId, chat.id]` 对，循环里调用 `encoder.set()` 只重编码这些块，最后整文件写回。**会话与消息没有按条或按会话的落盘单位**，任何修改的持久化路径都是"块重编码 + 整库覆写"。

边界：请求如何从 `chat.message` 组装上下文、流式事件如何驱动 `message[i].data` 属于对话请求与上下文类目；消息渲染窗口、滚动与折叠交互属于消息渲染器/Chat UI 类目。本笔记只记录这些操作改变的数据对象与最终持久化结果。

## 1. 会话、消息与分支数据模型

### 1.1 会话单位

| 单位 | 表示 | 标识 |
|---|---|---|
| 角色 | `character`（`type:'character'`），`chats: Chat[]`、`chatPage`、`chatFolders`、`trashTime` 等 | `chaId`（UUID，`assignIds` 启动补齐去重） |
| 群聊 | `groupChat`（`type:'group'`），另含 `characters: string[]`（成员 chaId）、`characterTalks`、`characterActive` | 同上，与角色并存于 `db.characters[]` |
| 会话 | `Chat`：`message: Message[]`、`note`、`name`、`localLore`、`id`、`folderId`、`lastDate`、`bookmarks`/`bookmarkNames`、`fmIndex`、`bindedPersona`、`hypaV2Data`/`hypaV3Data`/`scriptstate`、`suggestMessages` | `chat.id`（UUID）；会话列表顺序 + `chatPage` 下标是"当前会话"的指针 |
| 会话文件夹 | `chatFolders: ChatFolder[]`，会话经 `folderId` 归属 | `folder.id`（UUID） |

角色/群聊对象**内嵌全部会话**（随角色卡一起导入导出），会话不包含回链到角色的字段；`branch` 的"源会话"回链靠消息注释字段（见 4.4）。"当前会话"由 `char.chats[char.chatPage]` 决定，切换即改下标（`changeChatTo`，`globalApi.svelte.ts:2410-2429`）。

### 1.2 消息模型

消息是线性 `Message[]`，不是树、父子 part 或事件日志。字段分四组：

- 身份与角色：`role`（`user`/`char`）、`name`、`otherUser`（多用户房间中区分他人发言）、`saying`（char 消息的说话者 chaId，群聊据此渲染发言者）。
- 内容与状态：`data`（正文，可含 `{{inlayed::id}}` 附件内联语法与 `{{specialcomment::...}}` 注释）、`isComment`（注释消息，分支回链用）、`disabled`（`false`/`true`/`'allBefore'`：单条禁用或该条之前全部禁用，渲染为不同分隔线）。
- 生成快照：`generationInfo`（模型、`generationId`、输入输出 token 数、`maxContext`、各阶段耗时的 `stageTiming`）、`promptInfo`（`promptName`、`promptToggles`、`promptText`，仅 `db.promptInfoInsideChat` 开启时写入，web 端被强制为 false，`database.svelte.ts:696-699`）。
- 时间与标识：`time`（Date.now 毫秒）、`chatId`（UUID，发送时对缺失的旧消息惰性补齐，`process/index.svelte.ts:256-259`；书签添加时也会补，`Chat.svelte:287-290`）。

`generationId` 是**本次生成回合的标识**，同时写入消息 `generationInfo` 与内存 reroll 候选表，是两者关联的键（见 4.2）。没有 swipe 数组、没有消息级版本历史、没有消息级附件字段（附件内容经 inlay 语法进 `data`，资源存 `assets/`）。

### 1.3 首条消息的虚拟化

角色会话的"第 0 条"不进入 `message` 数组：`chat.fmIndex === -1` 时渲染角色 `firstMessage`，否则渲染 `alternateGreetings[fmIndex]`（`DefaultChatScreen.svelte:837-838`）；fmIndex 随会话持久化，UI 左右切换改写该值。群聊例外：新会话创建时直接把每个成员的 `firstMessage` 各 push 一条进消息数组（`SideChatList.svelte:146-153`），因此群聊无虚拟首条。

## 2. 事实源、索引与持久化

### 2.1 权威关系

- **内存 `DBState.db` 是唯一权威源**：所有读写入口（`getDatabase`/`setDatabase`/`getCurrentChat`，`database.svelte.ts:724-780`）都指向这个 `$state` 对象；渲染、生成、保存都直接操作它。
- **`database/database.bin` 是持久化副本**：整库序列化，启动时整份读入，运行中由 saveDb 整份覆写；不存在"会话级文件"或消息级增量日志。
- 旁路存储均非消息事实源：`risuSaveCache`（IndexedDB，risuSave.ts:121）缓存各块原始 JSON 用于远程块缺失时回填；`dbbackup-*` 是整库快照；`coldstorage/`（Tauri 文件/OPFS/账户远端）是被归档会话与角色的外置副本。

### 2.2 .bin 容器格式

文件有 4 种魔数头（`risuSave.ts:33-36, 669-716`）：旧版 msgpack 编码（`\0RISUSAVE\0` + 版本 7/8，可选 gzip 或流式压缩）与新块式容器（文本头 `"RISUSAVE\0"`）。解码器按头分派，无法识别时逐级降级尝试（含 ZIP 解压后 JSON/msgpack 回退，`decodeRisuSave` 的兜底分支）。

块式容器结构（`RisuSaveEncoder`，`risuSave.ts:124-326`）：

- 每块为 `[类型字节][压缩标志][名称长度][名称][长度][数据]`，数据是 JSON 文本（可 gzip）；根块内含 `__directory` 块名清单作为**块索引**。
- 块类型十余种，覆盖配置、角色、预设、模块、插件与插件存储等；其中决定机制边界的是三种：root（普通配置与 `__directory` 块索引的宿主）、character-with-chat（角色含全部会话）、remote（外置数据占位）。完整枚举见 `risuSave.ts:93-106`。
- 每个角色（含全部会话）是一个以 `chaId` 命名的块；增量保存时只重编码变化角色块与根块，再拼装整文件。
- **remote 块**：Tauri/Node 端（`enableRemoteSaving` 开启时）角色数据不写入 bin，而写到 `remotes/<chaId>.local.bin`（Tauri AppData 或 forageStorage），bin 内只放 REMOTE 占位块；解码时按名称读回，文件缺失时尝试从 `risuSaveCache` 恢复（`risuSave.ts:378-422, 554-591`）。解码器对损坏块静默跳过，root 块损坏才抛错。

### 2.3 保存触发与节流

- 触发：`$effect` 对 `DBState.db` 的深层快照读取建立依赖（除 characters/botPresets/modules 等大块外的所有键 + 当前角色全部字段 + `chats` 数组），任何可观察变化都在 500ms 防抖后进入保存循环（`globalApi.svelte.ts:330-404`）。
- 周期内多次变化只保留最近一组 `[chaId, chat.id]`（`changeTracker` 只留首项，429-430），因此高频修改（流式写 `message[i].data`）只会触发一次整库保存。
- 写入：Tauri 为 `writeFile('database/database.bin')` 与 `database/dbbackup-<ts>.bin`；web 为 `forageStorage.setItem` 同两个键。**每次保存都产生一份备份**，`getDbBackups` 保留最近 20 份并清理更旧的（`globalApi.svelte.ts:493-529`）。
- 账户模式（`forageStorage.isAccount`）：编码时压缩、不写本地备份、保存后等待 3 秒；失败重试 4 次后弹错（474-482）。

### 2.4 加载主链

`loadData`（`bootstrap.ts:55-269`）按平台分路：Tauri 用 fetch 读 AppData 下的 bin；web 走 `forageStorage.Init()`（后端选择见 6.3）。解码失败时**按时间倒序逐个尝试 dbbackup-* 备份**，全部失败才报"save file is corrupted"；账户模式先从本地读、再读远端 `database/database.bin`。加载后依次执行格式迁移、ID 分配、冷存储归档、插件加载、启动 `saveDb()`。

## 3. 创建、切换、归档、删除与恢复

- **新建会话**：`chats.unshift({message:[], note:'', name:'New Chat N', localLore:[], fmIndex:-1})`（`ChatList.svelte:71-90` 与 `SideChatList.svelte:139-158`）——内存惰性创建，首次落盘由 saveDb 自动完成，无独立"新建"持久化动作；会话列表顺序即创建/排序顺序。
- **复制会话**：`$state.snapshot` 深拷贝整个 Chat，`createChatCopyName` 生成不重复的 `(Copy N)` 名字、换新 `id`，`unshift` 到列表头（`SideChatList.svelte:267-272`）。
- **切换**：`changeChatTo(index|id)` 改写 `chatPage`（`globalApi.svelte.ts:2410-2429`）；切换本身不触发保存，依赖反应式监听。
- **重命名/笔记**：`chat.name`、`chat.note` 直接双向绑定修改（`SideChatList.svelte:254`、`CharConfig.svelte:331`）。
- **删除会话**：`chats.splice(i, 1)`（确认弹窗，`ChatList.svelte:49-66`），不产生回收站对象；`message` 内消息删除见 4.1。
- **删除角色（软删）**：`removeChar` 的 normal 模式只写 `trashTime = Date.now()`，角色仍在列表（垃圾桶视图），3 天后 `checkNewFormat` 启动清理时物理移除（`characters.ts:809-840`、`bootstrap.ts:497-504`）；垃圾桶中恢复即置 `trashTime = undefined`（`GridCatalog.svelte:144`）。
- **会话文件夹**：`chatFolders` 增删与拖拽排序直接改数组和 `folderId`；删文件夹把其中会话的 `folderId` 置空（`SideChatList.svelte:221-237`）。
- **归档（冷存储）**：见下。

### 3.1 冷存储（Cold Storage）归档与恢复

启动时 `makeColdData()`（`coldstorage.svelte.ts:529-574`，开关 `db.coldstorage`，无插件时默认开启，`database.svelte.ts:713`）对两类对象判龄归档，每批 5 个串行处理：

- **角色级**：`lastInteraction` 距今超 10 天且未归档的角色，整体写入冷存储（键为 UUID），原对象替换为只含 `image/name/chaId/chats 占位/coldstorage: id/coldStoragedChats` 的"瘦身壳"；打开角色时 `changeChar` 按壳内键读回完整对象（`characters.ts:884-893`）。
- **会话级**：最后一条消息时间距今超 10 天、且消息数 ≥4、且未归档的会话，把 `message`、`hypaV2Data`、`hypaV3Data`、`scriptstate`、`localLore` 写入冷存储，原地替换为一条占位消息 `'\uEF01COLDSTORAGE\uEF01' + key`（`coldstorageData.ts:4` 定义头）；打开会话时 `preLoadChat` 读回并恢复这些字段（`coldstorage.svelte.ts:576-614`），数据缺失时替换为显式错误提示消息。

冷存储后端按平台分派：账户远端（`/hub/account/coldstorage`）、Node 文件、Tauri `AppData/coldstorage/<key>.json`、web OPFS（`coldstorage.svelte.ts:40-197`）；值统一 JSON + fflate 压缩。写入后**先读回验证再替换原对象**（390-410、499-505）。无引用的条目由 `cleanColdStorage` 定期清理；迁移到账户模式时冷存储条目单独迁移并做资源路径重写（`autoStorage.ts:85-131`）。

## 4. 编辑、重试、续写、回退与分支语义

### 4.1 消息操作

| 操作 | 数据语义 |
|---|---|
| 编辑 | 原地修改 `message[idx].data`（`Chat.svelte:129-131`）；块级部分编辑（`PartialEditController`）同样只改 `data`，不产生版本 |
| 删除 | `rm()`：Shift 点击 = `slice(0, idx)` 截断至该条之前；普通 = `splice(idx, 1)`；`instantRemove` 模式弹确认（`Chat.svelte:100-127`） |
| 禁用 | `disabled` 在 `true`（单条）/`'allBefore'`（其前全部）/`false` 间切换（`Chat.svelte:867-887`） |
| 复制消息 | 剪贴板级操作，无数据对象变更 |
| 续写 | `sendMain(true)` 不新增消息，`sendChat(..., {continue:true})` 把新文本接在最后一条 char 消息 `data` 尾部（`process/index.svelte.ts:1595-1599, 1807-1834`） |

### 4.2 Reroll：内存候选机制

- **候选来源**：流式结束时 `addRerolls(generationId, Object.values(lastResponseChunk))`（`process/index.svelte.ts:1759`，chunk 内容是累积全文）；非流式 multiline 时，多个 choices 中第一个成为消息、其余进入候选（1864-1866）。`genTime > 1` 且模型为 gpt 且非续写时请求层才启用多候选（`request/request.ts:464`、`openAI/requests.ts:851-869`）。
- **切换**：`reroll()` 先用最后一条消息的 `generationInfo.generationId` 查 `Prereroll`，命中则**原地替换该消息 `data`**；否则回退到组件内 `rerolls: Message[][]` 数组（每次生成结束的尾部消息快照）替换数组尾部；两者皆空时物理 `pop` 尾部 char 消息（同一 `saying` 最多删 2 条，直到 user 消息）并重新生成（`DefaultChatScreen.svelte:218-271`）。`unReroll` 是反向流程（273-301）。
- **持久化边界**：候选表（`prereroll.ts` 模块级 Map）与组件内 `rerolls` 都是内存态，重启即失；切换后写入消息数组的版本随 saveDb 落盘，未选中的候选**不持久化**。这与 SillyTavern 的 swipes 数组字段形成对照。
- 首次消息（虚拟首条）的"reroll"按钮语义不同：切换 `fmIndex` 选择不同开场白（`DefaultChatScreen.svelte:845-870`）。

### 4.3 分支：复制会话 + 注释回链

分支按钮流程（`Chat.svelte:830-865`）：

1. 可选：若当前会话无 `folderId` 且 `createFolderOnBranch` 开启，先建"Branches of <name>"文件夹并绑定；
2. `$state.snapshot(currentChat)` 深拷贝整个会话（含全部字段），`createChatCopyName(name,'Branch')` 改名（剥离旧 `(Branch N)` 后缀再编号）、换新 `chat.id`；
3. 消息截断为 `message.slice(0, idx+1)`；
4. 尾部插入回链注释消息：`data: '{{specialcomment::branchedfrom::<源chatId>::<源会话名>::<源消息chatId>::}}'`，`isComment: true`、`disabled: true`；
5. `chats.unshift(newChat)` + `changeChatTo(0)` 跳转到新分支。

父会话**不写任何子分支记录**。注释消息在渲染时变为可点击的"Branched from ..."按钮，点击后 `changeChatTo(源chatId)` + `foldChatToMessage(源消息chatId)` 跳回源位置（`Chat.svelte:396-411`）。

### 4.4 分支视图：内容哈希前缀树

`getChatBranches()`（`gui/branches.ts:69-93`）遍历当前角色的**所有**会话，把 `[开场白哈希, 每条消息 data 哈希]` 作为路径插入树，公共前缀即共享历史、分叉处即分支点；输出带坐标的渲染节点。分支列表弹层（`AlertComp.svelte:832-903`）据此绘制节点连线。这是纯计算视图：**不读取任何分支元数据**，消息文本改动会改变哈希从而改变视图形状；该功能对 `isComment` 的 branchedfrom 消息不敏感。

## 5. 列表、分页、搜索与定位

- **会话列表**：无独立索引，直接遍历 `chara.chats`，按 `folderId` 分组渲染，Sortable 拖拽改顺序（`SideChatList.svelte:39-121`）；顺序、分组、文件夹折叠都是持久化数据。
- **消息渲染分页**：`loadPages` 初始 30 页（`chatLoadPages.ts:1-2` 的 `DEFAULT_CHAT_LOAD_INITIAL_PAGES`），滚动到顶部时按附加页数增加（`DefaultChatScreen.svelte:575-576`）；`Chats.svelte` 用消息哈希 diff 增量挂载/卸载尾部窗口（`Chats.svelte:65-167`）。这是渲染窗口化，`chat.message` 数组本身不分页。
- **搜索**：角色列表按名称过滤（`GridCatalog.svelte:41`）、模型网格与 HypaV3 摘要等局部搜索存在，但**聊天消息内容搜索本次未找到**：检查了 `src/lib` 全部 svelte 组件与 `src/ts` 下 search/filter 相关入口，未发现对 `chat.message` 做关键词检索的 UI 或工具函数；MCP 只提供 `risu-get-chat-history`（按 offset/count 分页读取当前角色当前会话，`process/mcp/risuaccess/chats.ts:42-82`），也没有内容搜索。此结论受上述检查范围限制。
- **定位**：书签列表跳转用 `ScrollToMessageStore` 设置下标，`scrollToMessage` 临时扩大 loadPages 后滚动到 `[data-chat-index]` 元素并高亮（`DefaultChatScreen.svelte:73-135`）；折叠定位用 `chatFoldedState`（内存态，见下）。

### 5.1 折叠（Chat Fold）与分支跳转

`foldChatToMessage` 把目标消息的 `{characterId, chatId, messageId}` 写入内存态 `chatFoldedState`，渲染窗口改为该消息附近的 `loadPages` 条（`globalApi.svelte.ts:2341-2408`、`Chats.svelte:86-89`），提供"加载更多"按钮；不持久化，切换角色/会话时自动清空。这是渲染定位机制，不是数据修改。

## 6. 缓存、一致性、多窗口与并发写入

### 6.1 单窗口写入节流与流式临时状态

- 保存循环本身串行：`changed` 置位后开始编码写入，期间 `saving.state` 防止重入；失败重试 4 次（`globalApi.svelte.ts:406-485`）。
- 流式生成直接写 `message[msgIndex].data` 并置 `chat.isStreaming = true`；该状态与 `activeStreamingDisplayOptimizationMode` 每次启动时被强制复位（`database.svelte.ts:714-719`），避免重启后遗留"流式中"标记。流式中止时**已写入的半截消息留在数组内**（sendChat 的 abort 分支只 `return false`，不删除消息；最终是否保留取决于 `removeIncompleteResponse` 对输出文本的截断而非数据层）。

### 6.2 多窗口：BroadcastChannel 互斥，无合并

`saveDb` 在启动时创建 `BroadcastChannel('risu-db')`：每次保存前广播本会话 UUID，收到其他标签页的广播后 `gotChannel=true`，此后跳过保存循环、弹提示并 `location.reload()`（`globalApi.svelte.ts:293-313, 433-440`）。即**后写者放弃写入并整页刷新**，靠刷新后的重新加载与备份兜底，不存在字段级合并或最后写入者赢。静态代码未发现对多窗口竞态的进一步保护（如写入前校验），竞争窗口未实测。

### 6.3 Web 存储后端选择

`AutoStorage.Init`（`autoStorage.ts:165-219`）按优先级：账户模式（localStorage 标记 `accountst=able`）→ Node 服务器 → OPFS（`opfs_flag!=able`，首次从 IndexedDB 迁移，标记 `migrated`）→ localforage IndexedDB。`checkAccountSync`（40-163）负责本地↔账户迁移：先问用户"加载远端或覆盖远端"，覆盖需手输 `RISUAI`，迁移过程重写资源路径（`replaceDbResources`）并单独迁移冷存储。

### 6.4 多用户（WebRTC）实时同步

房间内（`multiuser.ts`，peerJS）`peerSync` 发送当前会话对象；接收端 `request-chat-sync`/`receive-chat` 直接**用收到的整个 Chat 对象覆盖本地 `char.chats[chatPage]`**（`multiuser.ts:127-162`），不合并差异；生成前 `peerSafeCheck` 轮询所有成员、失败则 `peerRevertChat` 回滚到最近同步快照 `latestSyncChat`（369-435）。这是会话级整对象覆盖，接收方对 `setDatabase` 的调用同样走 saveDb 落盘。

### 6.5 孤儿资源清理

启动 `cleanChunks`（`bootstrap.ts:512-639`）遍历 `assets/` 与 `remotes/`：未被数据库引用的资产删除；`remotes/<chaId>.local.bin` 在角色不存在时先写 `.meta` 时间戳，**7 天**宽限期后删除（`remoteSaveCleanup.ts:1-38`）。账户/Node 模式跳过资产清理（`db.account?.useSync` 时直接返回）。

## 7. 迁移、导入导出与保留策略

### 7.1 格式迁移与兼容

`checkNewFormat`（`bootstrap.ts:335-507`）在每次启动时执行：角色/模块/人设的 null 补默认、`formatversion` 逐级升到 5 的版本迁移（资产路径 `assets/` 前缀清理、`sdData` 默认值、`loreBookToken` 下限、`trashTime` 过期清理；版本 4 的迁移被注释为"removed due to issues"直接置位）。与 SillyTavern 的"读取路径惰性补齐"不同，Risuai 的迁移是**启动时一次性改写内存对象**，由随后的 saveDb 落盘为新格式；旧字段未读到则不迁移（快照升级语义，不保留原文件）。

### 7.2 备份与恢复

- **自动备份**：每次保存写 `dbbackup-<ts>.bin`（见 2.3），加载失败时自动回退（2.4）；`getDbBackups` 同时负责清理超龄备份。
- **手动备份**：`SaveLocalBackup` 打包数据库（压缩编码）+ 全部资产 + 冷存储条目为 `.risudat`，可选 AES-GCM 加密；账户模式的解密密钥从 `sv.risuai.xyz/cryptokey` 按时间分发（`backuplocal.ts:162-169, 533-536`）。`LoadLocalBackup` 反向恢复；恢复前校验冷存储条目完整（缺失/损坏需用户确认继续）。
- 密码学实现为 WebCrypto AES-GCM，密钥由口令 SHA-256 派生，IV 固定 12 字节全零（`util.ts:378-426`）。

### 7.3 会话/数据库导入导出

- 导出：单会话 JSON（`type:'risuChat'` ver 2，含 `folders`）、TXT（`--名字\n正文` 文本流）、HTML 文件/HTML embed（`.idat` 隐藏节点内嵌会话 JSON，用于网页传播后回导）；全部会话 JSON（`risuAllChats` ver 2）（`characters.ts:192-521`）。
- 导入：JSON 按 `type/ver` 识别 risuChat/risuAllChats v1/v2，folderId 冲突时重映射；JSONL 按 Tavern 格式（`name/is_user/mes`）转换，首行视为元数据跳过；HTML 从 `.idat` 取 JSON；导入的会话换新 `id` 后 `unshift`（`characters.ts:371-505`）。
- 数据库整体迁移：账户同步（6.3）、Drive 云同步（`drive/`，`syncDrive` 每次保存前调用）、KEI 服务器备份（`kei/backup.ts`）属于本类目边界外的多端同步，不展开。

### 7.4 角色卡与预设格式

角色导入支持 JSON（spec v2/v3 与 Tavern off-spec）、`.charx`（容器 zip，内含 `card.json` + 可选 `module.risum`）、加密卡（AES-GCM，密码或内置密钥，`characterCards.ts:327-357`）；导出支持 PNG（spec v2/v3 嵌入）、CharX、JSON。`.risum` 是模块容器，`.risup`/`.risupreset` 是加密预设（密钥串 `risupreset`，`database.svelte.ts:2291-2359`）。这些格式都**内嵌 `chats` 数组**，因此角色卡的导出即会话的跨端搬迁载体；独立的 `exportAsDataset`（`storage/exportAsDataset.ts`）把全部角色会话导出为训练数据集 JSON（跳过群聊）。

## 8. 外部对象绑定

| 绑定对象 | 粒度 | 表示 |
|---|---|---|
| 角色 | 会话级（内嵌） | `character.chats` 数组随角色对象整体保存/导出；角色 `chaId` 是会话的唯一父级标识 |
| 群聊成员 | 群聊级 | `groupChat.characters: string[]`（chaId 引用）；消息级说话人 `saying` 记录 chaId |
| Persona | 会话级 | `chat.bindedPersona` 保存 persona 的 `id`（引用而非快照；persona 删除后仅失效），可解绑（`SideChatList.svelte:386-406`） |
| 模型/预设 | 消息级快照 | `generationInfo.model`（生成时定格，展示用，不用于回放）；`promptInfo` 记录 prompt 名与开关 |
| 附件 | 消息级（内联引用） | 消息 `data` 内 `{{inlayed::<assetId>}}` 引用 `assets/` 资源（`process/files/inlays.ts`、`multisend.ts`），跨端迁移时资源路径由 `replaceDbResources` 重映射 |
| 会话内记忆/脚本 | 会话级 | `hypaV2Data`/`hypaV3Data`/`scriptstate`/`localLore`/`suggestMessages` 随会话持久化；冷存储归档时一并外置（见 3.1） |

## 9. 设计取舍与已确认边界

- **整库单文件 + 块级增量**：会话与消息没有独立持久化单位，任何操作（含一次编辑）最终都是"角色块重编码 + 整库覆写"，配合每次保存的备份；换取的是实现简单、跨端文件易迁移，代价是保存粒度粗、`remotes/` 外置与 `risuSaveCache` 补回链条增加了加载复杂度。
- **reroll 不持久化**：候选仅存内存，重启丢失；与"复制会话做分支"形成两种互斥的回退手段——回退到旧版本只能靠分支/复制会话，不能靠消息内版本切换。
- **分支不对称**：子分支只在自身保存 `branchedfrom` 回链注释，父会话无子列表；分支视图靠内容哈希前缀树实时计算，文本编辑会改变树形，且对 branchedfrom 注释本身不参与树构建（`isComment` 消息的 `data` 是注释文本哈希，仍会入树）。多分支的导航依赖"跳回源会话"单向链路。
- **多窗口不合并**：BroadcastChannel 互斥让后到标签页刷新，无字段级冲突解决；多用户实时同步是会话级整对象覆盖，无写冲突检测以外的保护（`peerSafeCheck` 只检查是否正在生成）。
- **保留策略分层**：消息编辑删除无 undo（无事件日志）；会话删除即物理移除；角色删除有 3 天垃圾桶期；会话/角色过期走冷存储（10 天）而非删除；冷存储只受 `db.coldstorage` 开关控制，默认随是否装插件变化。
- **加密边界**：`database.bin` 本身**不加密**（AGENTS.md 所称"加密支持"实际落在备份 `.risudat`、角色加密卡、`.risup` 预设、翻译预设等处）；`cipherChat` 是接口中的遗留字段，全代码库仅一处定义与一处置 false 的赋值（`database.svelte.ts:821`、`openAI/requests.ts:348`），无功能实现。
- **流式中止的语义**：中止后已写入的半截 char 消息保留在数组中（数据层不删除），`removeIncompleteResponse` 只影响输出文本的标点截断，不产生"完成标记"字段。

## 10. 未验证事项

- 全部结论基于静态代码；未运行应用，冷存储读写、备份回退、账户迁移、WebRTC 多用户同步、多标签页竞争均未实测。
- 多窗口写入的竞争窗口（BroadcastChannel 广播与 bin 写入之间）与"后到者刷新"时的数据丢失概率未实测。
- 流式中止后半截消息的实际 UI 行为与下次启动后的呈现未验证（数据层保留已确认，展示与清理路径未追踪）。
- 导入导出（risuChat v1/v2、risuAllChats、JSONL Tavern 行、HTML `.idat`、加密角色卡）只核实了识别与转换代码，未用样本文件验证；`exportChat` 的 TXT/HTML 模式同理。
- remote 块加载链条（bin 内占位 → `remotes/*.local.bin` → `risuSaveCache` 回填 → 缺失跳过）在账户模式与 Node 模式下未实测。
- "消息内容搜索不存在"的结论受检查范围限制：已检查 `src/lib` 与 `src/ts` 的 search/filter 入口与 MCP 聊天接口，未覆盖插件第三方能力与 Hub 服务端。

## 11. 关键源码索引

- `src/ts/storage/database.svelte.ts`：`Database`（802-1278）；`character`（1343-1499）；`groupChat`（1510-1580）；`Chat`（1817-1839）；`Message`/`MessageGenerationInfo`/`MessagePresetInfo`（1848-1880）；`setDatabase` 默认值补全（30-722）；`getCurrentChat`/`setCurrentChat`（771-780）；`isStreaming` 启动复位（714-719）；预设 `.risup` 加密导入导出（2291-2359）
- `src/ts/storage/risuSave.ts`：魔数与 4 种格式识别（33-36, 669-716）；`RisuSaveEncoder`（124-423，remote 块 378-422）；`RisuSaveDecoder`（425-621）；`decodeRisuSave` 兜底链（623-667）
- `src/ts/globalApi.svelte.ts`：`saveDb` 保存循环（292-486）；`getDbBackups`（493-529）；`changeChatTo`（2410-2429）；`createChatCopyName`（2431-2441）；`foldChatToMessage`/`chatFoldedState`（2341-2408）
- `src/ts/bootstrap.ts`：`loadData`（55-269）；`checkNewFormat` 迁移（335-507）；`assignIds`（645-671）；`cleanChunks`（512-639）
- `src/ts/process/index.svelte.ts`：`sendChat`（99-2208）；chatId 惰性补齐（256-259）；流式写 `message[i].data`（1591-1794）；续写合并（1595-1599, 1807-1834）；multiline 候选（1795-1866）；`addRerolls` 调用点（1759, 1864-1866）
- `src/ts/process/prereroll.ts`：内存候选表（1-29）
- `src/lib/ChatScreens/DefaultChatScreen.svelte`：`sendMain`（144-216）；`reroll`/`unReroll`（218-301）；`sendChatMain`（305-329）；分页滚动加载（47, 575-576）；虚拟首条与 fmIndex 切换（832-875）
- `src/lib/ChatScreens/Chat.svelte`：`rm`（100-127）；`edit`（129-131）；书签（279-328）；分支按钮（830-865）；`disabled` 切换（867-887）；branchedfrom 渲染（396-411）
- `src/lib/ChatScreens/Chats.svelte`：渲染窗口哈希 diff（65-167）
- `src/lib/SideBars/SideChatList.svelte`：新会话/复制/删除/文件夹/persona 绑定（139-460）
- `src/lib/Others/ChatList.svelte`：新会话与删除（28-103）
- `src/lib/Others/GridCatalog.svelte`：垃圾桶视图与恢复（35-38, 134-144）
- `src/lib/Others/BookmarkList.svelte`：书签列表
- `src/ts/gui/branches.ts`：`getChatBranches` 哈希前缀树（69-93）
- `src/lib/Others/AlertComp.svelte`：分支弹层渲染（832-903）
- `src/ts/process/coldstorage.svelte.ts`：读写/归档/恢复（40-614）；`coldstorageData.ts` 头常量（4）
- `src/ts/characters.ts`：`exportChat`/`importChat`/`exportAllChats`（192-521）；`removeChar` 软删（809-840）；`changeChar` 冷存储恢复（876-898）
- `src/ts/characterCards.ts`：`importCharacterProcess`（52+）；`exportCharacterCard`（1245+）
- `src/ts/storage/autoStorage.ts`：后端选择与账户迁移（12-222）
- `src/ts/storage/remoteSaveCleanup.ts`：孤儿 remote 宽限期（1-38）
- `src/ts/sync/multiuser.ts`：房间与会话整对象覆盖（60-436）
- `src/ts/process/request/request.ts`：`multiGen` 条件（464）；`openAI/requests.ts` multiline（851-869）、`cipherChat` 置位（348）
- `src/ts/process/mcp/risuaccess/chats.ts`：`risu-get-chat-history`（42-82）
- `src/ts/drive/backuplocal.ts`：`.risudat` 备份与加密（22-169, 533-536）
- `src/ts/util.ts`：`encryptBuffer`/`decryptBuffer`（378-426）

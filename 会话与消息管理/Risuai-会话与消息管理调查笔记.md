# Risuai 会话与消息管理调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`39f1ac1472d0ef6907ee933c4cf25182ee2aec9f`（分支：`main`）
>
> 调查方式：直接阅读源码（`src/ts/storage` 持久化层、`globalApi.svelte.ts` 的保存循环、`bootstrap.ts` 加载主链、`process/index.svelte.ts` 生成入口、UI 层 Chat/DefaultChatScreen/SideChatList/ChatList、冷存储、角色与聊天导入导出、多用户同步），针对必查问题逐一核对当前 HEAD 的可执行路径；本次为静态调查，未运行应用
>
> 调查范围：会话/消息/分支/reroll/冷存储的数据模型、.bin 保存格式与事实源、加载与格式迁移、删除与恢复、导入导出边界、多窗口与多端一致性；生成请求的上下文拼装与流式事件、界面操作的具体交互流程分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 的会话和消息内嵌于角色数据，主存档采用块编码并由前端响应式状态驱动保存；remote 角色、冷归档和资源库另有外置后端：

- 角色（含群聊）对象内嵌一个会话数组 chats，当前会话就是 chatPage 下标指向的那一项；会话的 id 是 UUID，启动时由 assignIds 统一补齐并去重（`database.svelte.ts:1817-1839`、`bootstrap.ts:645-671`）。
- 消息是**线性数组中的扁平对象**，正文、说话角色、会话标识、时间戳、生成快照与禁用态等字段都平铺在同一条目上，`disabled` 含 'allBefore' 语义，无 swipe/版本字段（`database.svelte.ts:1848-1860`，字段定义见 1.2）。
- 运行时与持久化的事实源都是内存中的 `DBState.db`：渲染、生成与保存都直接操作这个响应式对象；保存入口 `saveDb`（`globalApi.svelte.ts:292-486`）以快照依赖加 500ms 防抖触发，由编码器做**块级增量编码**（根块 + 每角色一块）并整库写回主存档 database/database.bin，每次保存另写一份 dbbackup 备份（保留 20 份），加载失败时按时间倒序回退；外置角色与冷数据通过存档内的引用接入。
- 分支 = **复制整个会话对象并截断**，再在尾部插入一条 `isComment` 的 `branchedfrom` 特殊注释消息作为回链；父会话不记录子分支。分支导航视图由 `getChatBranches` 对消息内容哈希做前缀树**实时计算**，不依赖持久化元数据（`gui/branches.ts:69-93`）。
- Reroll（重生成）是**纯内存候选机制**：候选文本挂在 `process/prereroll.ts` 按生成 ID 索引的模块级对象上，切换时原地替换最后一条消息的 `data`，候选不落盘；没有候选时则物理删除尾部 char 消息后重新生成。
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

保存主链由 `saveDb()` 承担（`globalApi.svelte.ts:292-486`）：它用 `$effect` 对 `DBState.db` 建立深层依赖，快照读取除大块外的全部字段、当前角色（`selIdState` 指向的对象）的全部字段以及 chats 数组；任一可观察变化先置 changed，经 500ms 防抖后进入保存。变化只记下最近修改的一组 [chaId, chat.id]，循环里通过 encoder.set() 重编码这些块，最后把整个文件写回。会话与消息没有按条或按会话的落盘单位，任何修改的持久化路径都是块重编码加整库覆写。

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

- 身份与角色：`role` 取 user 或 char，`name` 是显示名；`otherUser` 在多用户房间里区分他人发言，`saying` 记录 char 消息的说话者（chaId），群聊据此渲染发言者。
- 内容与状态：正文存于 data 字段，可带 `{{inlayed::id}}` 附件内联语法与 `{{specialcomment::...}}` 注释；isComment 标记用于分支回链的注释消息；disabled 取 false、true 或 `'allBefore'`，分别表示未禁用、单条禁用和该条之前全部禁用，渲染成不同样式的分隔线。
- 生成快照：`generationInfo` 记录模型、`generationId`、输入输出 token 数、上下文上限和各阶段耗时；`promptInfo` 记录提示词名称、开关与文本，只在 `db.promptInfoInsideChat` 打开时写入，web 端该开关被强制为 false（`database.svelte.ts:696-699`）。
- 时间与标识：`time` 是毫秒时间戳；`chatId` 是 UUID，旧消息缺失时在发送过程中惰性补齐，添加书签时也会补（`process/index.svelte.ts:256-259`、`Chat.svelte:287-290`）。

`generationId` 是**本次生成回合的标识**，同时写入消息 `generationInfo` 与内存 reroll 候选表，是两者关联的键（见 4.2）。没有 swipe 数组、没有消息级版本历史、没有消息级附件字段（附件内容经 inlay 语法进 `data`，inlay 资源存独立 localforage 实例；角色资产另走 assets 路径）。

### 1.3 首条消息的虚拟化

角色会话的"第 0 条"存放在会话对象之外：fmIndex 为 -1 时渲染角色开场白，否则渲染对应索引的备选开场白；fmIndex 随会话持久化，UI 左右切换改写该值（`DefaultChatScreen.svelte:837-838`）。群聊例外：新会话创建时把每个成员的开场白各 push 一条进消息数组，因此群聊没有虚拟首条（`SideChatList.svelte:146-153`）。

## 2. 事实源、索引与持久化

### 2.1 权威关系

- **内存 `DBState.db` 是唯一权威源**：所有读写入口（`getDatabase`/`setDatabase`/`getCurrentChat`，`database.svelte.ts:724-780`）都指向这个 `$state` 对象；渲染、生成、保存都直接操作它。
- **`database/database.bin` 是持久化副本**：整库序列化，启动时整份读入，运行中由 saveDb 整份覆写；不存在"会话级文件"或消息级增量日志。
- 旁路存储均非消息事实源：`risuSaveCache`（IndexedDB，risuSave.ts:121）缓存各块原始 JSON 用于远程块缺失时回填；`dbbackup-*` 是整库快照；`coldstorage/`（Tauri 文件/OPFS/账户远端）是被归档会话与角色的外置副本。

### 2.2 .bin 容器格式

文件有 4 种魔数头（`risuSave.ts:33-36, 669-716`）：旧版 msgpack 编码（`\0RISUSAVE\0` + 版本 7/8，可选 gzip 或流式压缩）与新块式容器（文本头 `"RISUSAVE\0"`）。解码器按头分派，无法识别时逐级降级尝试（含 ZIP 解压后 JSON/msgpack 回退，`decodeRisuSave` 的兜底分支）。

块式容器结构（`RisuSaveEncoder`，`risuSave.ts`）：

- 每块为 `[类型字节][压缩标志][名称长度][名称][长度][数据]`，数据是 JSON 文本（可 gzip）；根块内含 `__directory` 块名清单作为**块索引**。
- 块类型十余种，覆盖配置、角色、预设、模块、插件、插件存储与会话内 KV 等；其中决定机制边界的是四种：root（普通配置与 `__directory` 块索引的宿主）、character-with-chat（角色含全部会话）、remote（外置数据占位）、`kv:<namespace>`（保存格式内的非响应式键值块）。
- 每个角色（含全部会话）是一个以 `chaId` 命名的块；增量保存时只重编码变化角色块与根块，再拼装整文件。
- **kv 块**：`saveKV.ts` 提供不进入 `DBState` 的 JSON 键值存储，每个命名空间对应一个 `kv:<namespace>` 块，只有该命名空间发生变化时才重编码；值以 JSON 字符串保存在普通 `Map` 里，因此读取与写入都是同步的，也不产生响应式开销。容量分层上，大对象归冷存储而不是这里。
- **remote 块**：Tauri/Node 端（`enableRemoteSaving` 开启时）角色数据不写入 bin，而写到 `remotes/<chaId>.local.bin`（Tauri AppData 或 forageStorage），bin 内只放 REMOTE 占位块；解码时按名称读回，文件缺失时尝试从 `risuSaveCache` 恢复。解码器对损坏块静默跳过，root 块损坏才抛错。

### 2.3 保存触发与节流

- 触发：`$effect` 对 `DBState.db` 的深层快照读取建立依赖（除 characters/botPresets/modules 等大块外的所有键 + 当前角色全部字段 + `chats` 数组），任何可观察变化都在 500ms 防抖后进入保存循环（`globalApi.svelte.ts:330-404`）。
- 周期内多次变化只保留最近一组 `[chaId, chat.id]`（`changeTracker` 只留首项，429-430），因此高频修改（流式写 `message[i].data`）只会触发一次整库保存。
- 写入：Tauri 为 `writeFile('database/database.bin')` 与 `database/dbbackup-<ts>.bin`；web 为 `forageStorage.setItem` 同两个键。**每次保存都产生一份备份**，`getDbBackups` 保留最近 20 份并清理更旧的（`globalApi.svelte.ts:493-529`）。
- 账户模式（`forageStorage.isAccount`）：编码时压缩、不写本地备份、保存后等待 3 秒；失败重试 4 次后弹错（474-482）。

### 2.4 加载主链

`loadData`（`bootstrap.ts:55-269`）按平台分路：Tauri 用 fetch 读 AppData 下的 bin；web 走 `forageStorage.Init()`（后端选择见 6.3）。解码失败时**按时间倒序逐个尝试 dbbackup-* 备份**，全部失败才报"save file is corrupted"；账户模式先从本地读、再读远端 `database/database.bin`。加载后的插件启动前会等待一次插件存储迁移尝试；随后继续插件加载、ID 分配和冷归档等初始化，再启动保存循环。迁移异常被捕获并记录，插件加载在迁移尝试之后继续（`bootstrap.ts:200-214,253`）。

## 3. 创建、切换、归档、删除与恢复

- **新建会话**：聊天页与角色侧栏的按钮都只在内存里向列表头部插入一个空会话，标题取 `New Chat N`，`fmIndex` 置 -1 以便渲染角色开场白；首次落盘由 saveDb 自动完成，没有独立的"新建"持久化动作，列表顺序即创建/排序顺序（`ChatList.svelte:71-90`、`SideChatList.svelte:139-158`）。
- **复制会话**：对当前会话做深拷贝，由 createChatCopyName 生成不重复的 `(Copy N)` 名称、换新 id 后插到列表头部（`SideChatList.svelte:267-272`）。
- **切换**：changeChatTo 按下标或会话 id 改写当前下标 chatPage；动作本身不写盘，落盘交给响应式监听（`globalApi.svelte.ts:2410-2429`）。
- **重命名/笔记**：名称与笔记分别双向绑定到会话的 name、note 字段，输入即改内存值（`SideChatList.svelte:254`、`CharConfig.svelte:331`）。
- **删除会话**：确认弹窗后从会话数组里移除该项，不生成回收站对象；消息级删除见 4.1（`ChatList.svelte:49-66`）。
- **删除角色（软删）**：removeChar 的 normal 模式只给角色写一个 `trashTime` 时间戳，对象仍留在数据里供垃圾桶视图展示；3 天后由启动迁移阶段（checkNewFormat）物理移除，垃圾桶里的恢复操作则把这个时间戳清空（`characters.ts:809-840`、`bootstrap.ts:497-504`、`GridCatalog.svelte:144`）。
- **会话文件夹**：文件夹的增删与拖拽排序直接改 chatFolders 数组，会话归属靠 folderId 字段；删除文件夹时把其中会话的归属置空（`SideChatList.svelte:221-237`）。
- **归档（冷存储）**：见下。

### 3.1 冷存储（Cold Storage）归档与恢复

启动时先尝试迁移插件存储，再加载插件；后续 `makeColdData()` 会启动插件存储的后台加载，这一步不受冷归档开关控制。角色和会话判龄归档仍由该开关控制，每批至多 5 项并行、批次顺序等待（`bootstrap.ts:200-214,253`；`process/coldstorage.svelte.ts:560-614`）：

- **角色级**：`lastInteraction` 超过 10 天且未归档的角色，整体写入冷存储（以 UUID 为键），原位置换成只保留 image、name、chaId、chats 占位、coldstorage 引用与 coldStoragedChats 的瘦身壳；打开角色时 changeChar 按壳内引用读回完整对象（`characters.ts:884-893`）。
- **会话级**：归档门槛是最后一条消息距今超过 10 天、消息数不少于 4 条且尚未归档；命中后把 message 数组连同 hypaV2Data、hypaV3Data、scriptstate、localLore 写入冷存储，原地替换为一条占位消息 `'\uEF01COLDSTORAGE\uEF01' + key`；打开会话时 preLoadChat 读回并恢复这些字段，数据缺失则替换为显式错误提示（`coldstorageData.ts:4`、`coldstorage.svelte.ts:627-665`）。
- **插件存储布局**：小值 JSON 集中在一份冷索引里，大值写到独立冷条目，数据库只留 `_coldpluginIndex` 指针。默认大值阈值约为 256 Ki 字符，索引软预算约 8 Mi 字符，4 Ki 以下的单值始终留在索引中；计量用的是 JSON 字符串长度，UTF-8 文件字节限额要按编码后的字节数折算（`process/pluginStorageStore.ts:34-60,372-401`）。
- **迁移与提交**：旧内联值和旧逐键映射在加载时合并进新索引。新索引冷写成功后，才同步移动数据库指针并移除已迁移的旧副本；失败保留旧指针并安排重试。主数据库仍由独立的保存循环落盘，插件 API 的写入完成、索引指针提交和整库存档写出因此落在三个时点（`process/pluginStorageStore.ts:225-316,433-519`）。
- **读写与回收**：小值写入只改内存，索引随后批量刷新；大值先写冷条目再登记进索引，同键的后到操作会让早先的写入失效。被替换的条目先进入垃圾列表，等后续加载时才按宽限期清理，普通条目一天、旧索引一小时。页面隐藏时另有一次尽力而为的 flush，强制退出能否落盘没有保证（`process/pluginStorageStore.ts:319-341,372-401`、`process/coldstorage.svelte.ts:684-692`）。

冷存储后端按平台分派：账户远端（`/hub/account/coldstorage` 接口）、Node 文件、Tauri AppData 目录下按 key 命名的 JSON 文件与 web OPFS，值统一 JSON + fflate 压缩（`process/coldstorage.svelte.ts:40-197,253-359,390-410,499-505`）。写入后**先读回验证再替换原对象**。无引用的条目由清理逻辑定期回收，其保护清单合并插件索引、大值与待回收条目，备份遍历也收集索引引用，避免把在用项当作孤儿删除。迁移到账户模式时冷存储条目单独迁移并重写资源路径（`autoStorage.ts:85-131`）。

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

- **流式候选来源**：候选表只在流式结束时记下最后一帧的全部候选文本，中间时间片不保留；OpenAI 多生成路径按 choice index 分别累计。因此切换候选只能在最后一帧的几种完整文本之间回退（`process/index.svelte.ts:1702-1704,1759`、`request/openAI/requests.ts:851-869,1036-1052`）。
- **非流式候选来源**：multiline 的第一段文本进入显示消息，同时与其余文本一起进入候选数组；候选超过一个时保存整份数组，游标从首段所在的下标 0 开始（`process/index.svelte.ts:1836-1865`、`process/prereroll.ts:26-28`）。请求层启用多候选的条件是 genTime 大于 1、模型为 gpt 且当前非续写（`request/request.ts:464`）。
- **切换**：先按最后一条消息的生成 ID 查询文本候选，命中就原地替换正文；否则使用组件内的尾部消息段快照。没有可切换候选时截去尾部回复并重新生成；删除在遇到第二条同一说话者消息或 user 消息时停止。反向切换沿同样两层缓存回退（`DefaultChatScreen.svelte:219-301`）。
- **持久化边界**：候选表（`prereroll.ts` 模块级对象）与组件内 `rerolls` 都是内存态，重启即失；切换后写入消息数组的版本随 saveDb 落盘，未选中的候选**不持久化**。这与 SillyTavern 的 swipes 数组字段形成对照。
- 首次消息（虚拟首条）的"reroll"按钮语义不同：切换 `fmIndex` 选择不同开场白（`DefaultChatScreen.svelte:845-870`）。

### 4.3 分支：复制会话 + 注释回链

分支按钮流程（`Chat.svelte:830-865`）：

1. 若当前会话还没有 folderId，且设置项 createFolderOnBranch 已开启，先建一个 "Branches of <name>" 文件夹并把新分支归入其中；
2. 深拷贝整个会话对象，用 createChatCopyName 生成带 Branch 后缀的新名字（先剥离旧的 `(Branch N)` 后缀再编号），并换新 chat.id；
3. 消息数组保留到触发分支的那一条为止，即截断为前 idx+1 条；
4. 尾部插入回链注释消息，正文为 `{{specialcomment::branchedfrom::<源chatId>::<源会话名>::<源消息chatId>::}}`，同时把 isComment 与 disabled 都置 true；
5. 把新会话插到列表头部并切换过去。

父会话**不写任何子分支记录**。注释消息在渲染时变为可点击的"Branched from ..."按钮，点击后 `changeChatTo(源chatId)` + `foldChatToMessage(源消息chatId)` 跳回源位置（`Chat.svelte:396-411`）。

### 4.4 分支视图：内容哈希前缀树

`getChatBranches()`（`gui/branches.ts:69-93`）遍历当前角色的**所有**会话，把 `[开场白哈希, 每条消息 data 哈希]` 作为路径插入树，公共前缀即共享历史、分叉处即分支点；输出带坐标的渲染节点。分支列表弹层（`AlertComp.svelte:832-903`）据此绘制节点连线。这是纯计算视图：**不读取任何分支元数据**，消息文本改动会改变哈希从而改变视图形状；该功能对 `isComment` 的 branchedfrom 消息不敏感。

## 5. 列表、分页、搜索与定位

- **会话列表**：没有独立索引，渲染时直接遍历当前角色的 chats 数组，按 folderId 分组，Sortable 拖拽改的也是数组顺序；列表顺序、分组与文件夹折叠状态都随角色一起持久化（`SideChatList.svelte:39-121`）。
- **消息渲染分页**：loadPages 默认 30 页，滚动到顶部时按附加页数递增，Chats 组件用消息哈希做 diff，增量挂载或卸载尾部窗口；chat.message 数组本身始终完整，分页只影响渲染（`chatLoadPages.ts:1-2`、`DefaultChatScreen.svelte:575-576`、`Chats.svelte:65-167`）。
- **搜索**：角色列表按名称过滤，模型网格与 HypaV3 摘要各有局部搜索；**聊天消息内容搜索本次未找到**——检查了 `src/lib` 全部 Svelte 组件与 `src/ts` 下 search/filter 相关入口，没有对 chat.message 做关键词检索的 UI 或工具函数，MCP 的 `risu-get-chat-history` 也只在当前角色当前会话里按 offset/count 分页读取（`GridCatalog.svelte:41`、`process/mcp/risuaccess/chats.ts:42-82`）。此结论受上述检查范围限制。
- **定位**：书签跳转先把目标下标写进 `ScrollToMessageStore`，再由 scrollToMessage 临时扩大 loadPages、滚动到对应的 data-chat-index 元素并高亮；折叠定位另用内存态 chatFoldedState（`DefaultChatScreen.svelte:73-135`）。

### 5.1 折叠（Chat Fold）与分支跳转

折叠定位由 foldChatToMessage 实现：它把目标消息的角色、会话与消息标识写入内存态 `chatFoldedState`，渲染窗口收缩到该消息附近的 loadPages 条（`globalApi.svelte.ts:2341-2408`、`Chats.svelte:86-89`），提供"加载更多"按钮；该状态不持久化，切换角色或会话时自动清空，消息数组本身保持不变。

## 6. 缓存、一致性、多窗口与并发写入

### 6.1 单窗口写入节流与流式临时状态

- 保存循环本身串行：changed 置位后进入编码与写入，期间用 saving.state 挡住重入，失败重试 4 次（`globalApi.svelte.ts:406-485`）。
- 流式生成直接写最后一条消息的正文并置 chat.isStreaming 标记；该标记与 activeStreamingDisplayOptimizationMode 在每次启动时被强制复位，重启后不会遗留"流式中"状态（`database.svelte.ts:714-719`）。中止时已写入的半截消息留在数组内，sendChat 的中止分支只返回 false 而不删消息，最终是否保留取决于 removeIncompleteResponse 对输出文本的截断。

### 6.2 多窗口：BroadcastChannel 互斥，无合并

`saveDb` 在启动时创建 `BroadcastChannel('risu-db')`：每次保存前广播本会话 UUID，收到其他标签页的广播后 `gotChannel=true`，此后跳过保存循环、弹提示并 `location.reload()`（`globalApi.svelte.ts:293-313, 433-440`）。即**后写者放弃写入并整页刷新**，靠刷新后的重新加载与备份兜底，不存在字段级合并或最后写入者赢。静态代码未发现对多窗口竞态的进一步保护（如写入前校验），竞争窗口未实测。

### 6.3 Web 存储后端选择

后端选择入口 AutoStorage.Init（`autoStorage.ts:40-219`）按账户模式、Node 服务器、OPFS、localforage IndexedDB 的优先级依次尝试；OPFS 首次启用时从 IndexedDB 迁移并落下迁移标记。同一入口内的账户同步检查负责本地↔账户迁移：先问用户"加载远端或覆盖远端"，覆盖需手输 `RISUAI`，迁移过程重写资源路径（`replaceDbResources`）并单独迁移冷存储。

### 6.4 多用户（WebRTC）实时同步

房间内通过 peerJS 建连，发送方的 peerSync 把当前会话对象整份发出；接收方处理 request-chat-sync 与 receive-chat 时，直接用收到的 Chat 覆盖本地 char.chats[chatPage]，不做差异合并。生成前 peerSafeCheck 会轮询所有成员，检查失败则用 peerRevertChat 回滚到最近一次同步快照 latestSyncChat。这类同步都是会话级整对象覆盖，接收方改完同样经 setDatabase 走 saveDb 落盘（`multiuser.ts:127-162,369-435`）。

### 6.5 孤儿资源清理

启动清理入口 cleanChunks（`bootstrap.ts:512-639`）遍历 assets 与 remotes 两个目录：删除无人引用的资产；每个角色的 remote 外置文件在角色不存在时先写 `.meta` 时间戳，**7 天**宽限期后才删除（`remoteSaveCleanup.ts:1-38`）。账户或 Node 同步模式下整段资产清理直接跳过。

## 7. 迁移、导入导出与保留策略

### 7.1 格式迁移与兼容

每次启动都会执行格式检查 checkNewFormat（`bootstrap.ts:335-507`）：为角色、模块与人设补齐 null 默认值，再把 formatversion 逐级升到 5，涵盖资产路径前缀清理、若干字段默认值补全、token 下限修正与垃圾时间戳过期清理。版本 4 的迁移被注释为"removed due to issues"直接置位。与 SillyTavern 的"读取路径惰性补齐"不同，Risuai 的迁移在启动时**一次性改写内存对象**，由随后的保存循环落盘为新格式；未读到的旧字段不迁移，原文件也不保留（快照升级语义）。

### 7.2 备份与恢复

- **自动备份**：每次保存都写一份 dbbackup-<ts>.bin（见 2.3），加载失败时按备份回退（2.4）；getDbBackups 既供回退枚举备份，也负责清理超龄备份。
- **手动备份**：SaveLocalBackup 把压缩编码后的数据库、全部资产与冷存储条目打成一个 `.risudat`，可选 AES-GCM 加密；账户模式的解密密钥按时间从 `sv.risuai.xyz/cryptokey` 分发。LoadLocalBackup 反向恢复，恢复前校验冷存储条目完整性，缺失或损坏时由用户确认是否继续（`backuplocal.ts:162-169,533-536`）。
- 密码学实现为 WebCrypto AES-GCM，密钥由口令 SHA-256 派生，IV 固定 12 字节全零（`util.ts:378-426`）。

### 7.3 会话/数据库导入导出

- 导出有四种形态：单会话 JSON（type 为 risuChat、版本 2，带 folders）、TXT 文本流（每段以 `--名字` 起头，后接正文）、HTML 文件与 HTML embed（会话 JSON 藏在 .idat 隐藏节点里，便于网页传播后再导回）、全部会话 JSON（risuAllChats 版本 2）。实现集中在 `characters.ts:192-521`。
- 导入按 type/ver 区分 risuChat 与 risuAllChats 的 v1、v2，folderId 冲突时重新映射；JSONL 按 Tavern 的 name/is_user/mes 行格式转换，首行当元数据跳过；HTML 从 .idat 节点里取 JSON。导入的会话一律换新 id 后插到列表头部（`characters.ts:371-505`）。
- 数据库整体迁移：账户同步（6.3）、Drive 云同步（`drive/`，`syncDrive` 每次保存前调用）、KEI 服务器备份（`kei/backup.ts`）属于本类目边界外的多端同步，不展开。

### 7.4 角色卡与预设格式

角色导入接受三类来源：角色卡 JSON（spec v2/v3，另兼容 Tavern 的 off-spec 变体）、.charx 容器（zip，内含 card.json 与可选的 module.risum）、AES-GCM 加密卡（用密码或内置密钥解开）。导出提供 PNG（把 spec v2/v3 数据嵌入图片）、CharX 与 JSON。.risum 是模块容器，.risup 与 .risupreset 是加密预设，密钥串为 `risupreset`。这些格式都内嵌 chats 数组，角色卡本身即会话跨端搬迁的载体；exportAsDataset 另把全部角色会话导出为训练数据集 JSON，跳过群聊（`characterCards.ts:327-357`、`database.svelte.ts:2291-2359`、`storage/exportAsDataset.ts`）。

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

- **整库单文件 + 块级增量**：会话与消息没有独立的持久化单位，任何操作（包括改一条消息）最终都表现为角色块重编码加整库覆写，并顺带写一份备份。这样实现简单、跨端文件容易搬移，代价是保存粒度粗；remotes 外置与 risuSaveCache 回填又拉长了加载链条。
- **reroll 不持久化**：候选只存在内存里，重启即丢。回到旧版本有两套互斥手段，即分支与复制会话；消息内没有版本切换。
- **分支不对称**：子会话携带一条 branchedfrom 回链注释，父会话不记录任何子列表；分支视图由内容哈希前缀树实时算出，回链关系不参与建树，注释消息的正文照样按哈希入树，因此编辑消息文本就会改变树形。多分支导航走"跳回源会话"的单向链路。
- **多窗口不合并**：BroadcastChannel 只做互斥，后到的标签页直接整页刷新，没有字段级冲突处理；多用户实时同步按会话整对象覆盖，写前检查只有 peerSafeCheck，它只看对方是否正在生成。
- **保留策略分层**：消息的编辑与删除没有 undo，也没有事件日志可回溯；会话删除直接物理移除，角色删除先进垃圾桶 3 天再清理；会话与角色过期后转入冷存储（10 天门槛），对象继续保留；判龄归档受冷归档开关控制，插件冷存储独立加载。
- **加密边界**：database.bin 以明文落盘；AGENTS.md 提到的"加密支持"落在备份 `.risudat`、加密角色卡、`.risup` 预设和翻译预设上。cipherChat 是接口里的遗留字段，全库只有一处定义与一处赋 false，没有对应的功能实现（`database.svelte.ts:821`、`openAI/requests.ts:348`）。
- **流式中止的语义**：中止后已写入的半截 char 消息留在数组里，removeIncompleteResponse 只影响输出文本的标点截断，数据侧不写"完成标记"字段。

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
- `src/ts/process/coldstorage.svelte.ts`：读写/归档/恢复（40-665，插件存储迁移 529-573）；`coldstorageData.ts` 头常量（4）与在用键清单（79-95）
- `src/ts/characters.ts`：`exportChat`/`importChat`/`exportAllChats`（192-521）；`removeChar` 软删（809-840）；`changeChar` 冷存储恢复（876-898）
- `src/ts/characterCards.ts`：`importCharacterProcess`（52+）；`exportCharacterCard`（1245+）
- `src/ts/storage/autoStorage.ts`：后端选择与账户迁移（12-222）
- `src/ts/storage/remoteSaveCleanup.ts`：孤儿 remote 宽限期（1-38）
- `src/ts/sync/multiuser.ts`：房间与会话整对象覆盖（60-436）
- `src/ts/process/request/request.ts`：`multiGen` 条件（464）；`openAI/requests.ts` multiline（851-869）、`cipherChat` 置位（348）
- `src/ts/process/mcp/risuaccess/chats.ts`：`risu-get-chat-history`（42-82）
- `src/ts/drive/backuplocal.ts`：`.risudat` 备份与加密（22-169, 533-536）
- `src/ts/util.ts`：`encryptBuffer`/`decryptBuffer`（378-426）

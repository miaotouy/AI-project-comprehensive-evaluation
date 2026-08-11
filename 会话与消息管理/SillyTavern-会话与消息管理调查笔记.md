# SillyTavern 会话与消息管理调查笔记

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：从 [`../Chat/SillyTavern-Chat调查笔记.md`](../Chat/SillyTavern-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：聊天与消息的内存模型、JSONL 持久化、checkpoint/branch/swipe 数据语义、群聊数据差异；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 把"聊天"实现为一个**驻留在内存里的可变数组 + 定期整份序列化到 JSONL 文件**的模型，而不是增量事件日志或数据库表：

- 核心状态 `chat: ChatMessage[]` 与 `chat_metadata`（`main_chat` 回链、`tainted` 纯净标记、`integrity` 防并发覆写 UUID、`attachments` 等）都直接暴露在 `public/script.js` 顶层，所有渲染、生成、保存逻辑直接读写这个数组本身。
- 单人聊天与群聊是两个存储位置，JSONL 文件格式一致：第一行头对象 + 每行一条 `ChatMessage`；加载时一次性整份读入内存与 DOM，**没有分页读取或流式解析**。
- 服务端保存带 `integrity` 完整性检查：不一致抛 `IntegrityMismatchError`，前端要求用户手输 `OVERWRITE` 强制覆盖，否则整页刷新。
- **Checkpoint 与 Branch 共用"截断另存为新文件"的底层逻辑**，区别是 checkpoint 不跳转、branch 必跳转，且只有 branch 支持连同某个具体 swipe 版本一起截断。
- **checkpoint 与 branch 的数据设计不对称**：`extra.bookmark_link` 是单值（新建覆盖旧值），`extra.branches` 是数组（可追加多个分支）。
- swipe 是消息级候选版本机制：`mes`/`swipe_id`/`swipes`/`swipe_info` 四字段并行，`ensureSwipes` 对老文件惰性迁移。

## 系统边界与数据主链

```text
openCharacterChat(file_name) / openGroupChat
  -> clearChat 清空内存与 DOM
  -> getChat()/getGroupChat()：一次性读完整 JSONL 文件（data.shift() 摘头对象）
  -> 空文件时 getFirstMessage() 现造问候语（备选开场白直接塞成 swipes 数组）
  -> 内存 chat[] 为唯一事实源，渲染/生成/保存都读写它
  -> saveChat()：chat_metadata.integrity 与服务端比对 -> 整份写回 JSONL
```

边界：生成请求如何构建（`Generate()` 的筛选、注入与 provider 分支）在对话请求与上下文；消息如何进 DOM（`printMessages`/`redisplayChat` 首屏 100 条截断、`StreamingProcessor` 流式渲染、正则渲染层）在消息渲染器（`../消息渲染器/SillyTavern-消息渲染调查笔记.md`）；swipe 按钮、Swipe Picker 等用户工作流在 Chat UI。

## 1. 消息与元数据模型

`chat_metadata` 挂着聊天级元数据：`main_chat`（checkpoint 回链父聊天名）、`tainted`（是否已脱离"纯净"首条问候语状态，`script.js:1659`/`4288`/`5846`/`8131`/`9323`/`11669` 等多处写入）、`integrity`（防止并发覆写用的 UUID slug）、`attachments`（聊天级附件）等。

### 1.1 Swipe 数据结构

一条可 swipe 的消息在稳定状态下有三个并行数组/字段：

```js
message.mes         // 当前显示的正文（=swipes[swipe_id] 的镜像）
message.swipe_id     // 当前选中的候选下标
message.swipes       // string[]，每个候选版本的正文
message.swipe_info   // 与 swipes 等长的数组，每项 {send_date, gen_started, gen_finished, extra}
```

`ensureSwipes(message)`（`script.js:6778-6828`）是懒惰迁移函数：老聊天文件里消息可能没有这三个字段，读取时如果缺失就用当前 `mes` 现造一个长度为 1 的 `swipes` 数组、`swipe_id=0`、对应的 `swipe_info`；如果 `swipes[i]` 类型不对也会强制纠正为空字符串并打印警告。用户消息和"小型系统消息"（`extra.isSmallSys`）被显式排除在 swipe 体系外（`script.js:6787-6789`）。

两个同步方向的函数职责严格区分：

- `syncMesToSwipe(messageId)`（`script.js:6837-6883`）：把当前 `message.mes`/时间戳/`extra` **写回**到 `swipes[swipe_id]`/`swipe_info[swipe_id]`——用在"用户编辑了正文之后要更新到对应的 swipe 存档里"的场景。有个细节：只有 `chat_metadata.tainted || chat.length > 1` 时才真的写回 `swipes[swipe_id]`（`script.js:6873`），注释说明是为了让"纯净首条问候语"在每次进聊天时宏还能重新解析——即第 0 条消息在全新/未变动状态下故意不落盘同步，保留重新求值的空间。
- `syncSwipeToMes(messageId, swipeId, targetMessage)`（`script.js:6895-6959`）：反方向，把 `swipes[swipeId]` **读出来**覆盖 `message.mes`/时间戳/`extra`——用在"用户切到某个候选版本"时。这个函数支持传入 `targetMessage` 直接操作一个游离对象（不一定是 `chat[]` 里的真实消息），这正是 Branch 快照选 swipe 时复用的路径。

`deleteSwipe(swipeId, messageId)`（`script.js:9279-9329`）：至少保留 1 个 swipe（不允许删空），删除后按"删的是不是当前选中项"决定新 `swipe_id`（删除项在当前项之前就整体减 1，删的正好是当前项就选下一个或前一个），并把 `chat_metadata.tainted = true`（删除 swipe 后聊天不再"纯净"，影响 `PRISTINE_GREETING` 判定）。

## 2. 事实源与持久化

聊天的"载体"分两种，文件格式相同，存储位置不同：

- 单人聊天：`src/endpoints/chats.js:470-495`（`/api/chats/save`）写到 `<user>/chats/<角色avatar去掉.png>/<chatName>.jsonl`。
- 群聊：`src/endpoints/chats.js:847-872`（`/api/chats/group/save`）写到 `<user>/group chats/<chatId>.jsonl`（扁平目录，不按角色分文件夹），群本身的成员/设置存在单独的 `<user>/groups/<groupId>.json`，其中 `chats: string[]` 字段列出属于该群的所有聊天文件 id（`public/scripts/group-chats.js` 里 `saveGroupChat` L623-675、`getGroupChat` L255-320 都读写这个字段）。

两种文件的 JSONL 结构完全一致：第一行是头对象

```js
/** @type {ChatHeader} */
const chatHeader = { chat_metadata: metadata, user_name: 'unused', character_name: 'unused' };
```

（单人聊天见 `script.js:7368-7373`，群聊见 `group-chats.js:631-636`），之后每行一个 `ChatMessage` 的 JSON。加载时 `getChat()`（`script.js:7575-7623`）和 `getGroupChat()`（`group-chats.js:255-320`）都用 `data.shift()` 把头对象摘掉，取出 `chat_metadata` 后把剩余行整份 `chat.splice(0, chat.length, ...data)` 灌回内存数组——**没有分页读取或流式解析，一次性把整个聊天文件读进内存和 DOM**。

服务端保存路径带有一个"完整性检查"机制（`src/endpoints/chats.js:316-335, 457-468`）：保存前会读文件首行的 `chat_metadata.integrity` 与内存中当前值比对，不一致就抛 `IntegrityMismatchError`，前端 `saveChat()`（`script.js:7336-7421`）捕获后弹窗要求用户手输 `OVERWRITE` 才强制覆盖，否则整页刷新——这是防止多标签页/多设备并发写导致互相覆盖数据的兜底手段，但代价是普通用户遇到这个弹窗基本不知道发生了什么。

## 3. 创建与惰性初始化

`openCharacterChat(file_name)`（`script.js:7685-7693`）流程：等待没有正在进行的保存 → `clearChat({clearData:true})` 清空内存和 DOM → 设置 `characters[this_chid].chat = file_name` → `getChat()`。`getChat()` 读完文件后调用 `getChatResult()`（`script.js:7625-7649`），其中有个关键分支：如果 `chat.length === 0`（文件不存在或为空），会调用 `getFirstMessage()`（`script.js:7651-7683`）现造一条问候语消息塞进去，且**问候语的多个 `alternate_greetings` 直接被塞成这条消息的 `swipes` 数组**（`swipes = [message.mes, ...alternateGreetings...]`，`swipe_id = 0`）——也就是说，角色卡的"备选开场白"功能，底层实现就是把 swipe 机制直接复用在第 0 条消息上。

群聊加载 `getGroupChat()`（`group-chats.js:255-320`）在"全新聊天"（`freshChat = !metadata.tainted && 数据为空`）分支下，会遍历 `group.members`，给每个成员各生成一条首条消息（`getFirstCharacterMessage`），这意味着群聊的"开场"可以是多条消息（每个成员各一条），而单人聊天只有一条。

## 4. 消息操作数据语义

### 4.1 隐藏/恢复：标记为系统消息，不删除

`hideChatMessageRange(start, end, unhide, nameFitler)`（`chats.js:147-169`）：遍历区间内消息，把 `message.is_system` 置为 `hide`，同时同步 DOM 上 `.mes` 的 `is_system` 属性，最后调 `refreshSwipeButtons()`（因为最后一条消息隐藏会影响能不能 swipe）并 `saveChatConditional()`。隐藏是"标记为系统消息"，不是删除、不改变数组顺序；对 prompt 构建的影响没有在这个文件里体现——**未核实** `is_system` 是否真的在 prompt 组装阶段被过滤（原调查未深入 prompt 组装函数验证）。

### 4.2 附件删除：只改消息 `extra`，不触碰正文

`deleteMessageFile`（`chats.js:395-427`）、`deleteMessageMedia`（`chats.js:978-1060`）都是"改 `message.extra.files`/`extra.media` 数组 + 调服务器 `/api/files/delete` 或 `/api/images/delete` + `saveChatConditional()` + 重新渲染该条消息的媒体区块"，附件本身是独立于 `chat[]` 消息文本之外的对象数组（`extra.media: MediaAttachment[]`、`extra.files: FileAttachment[]`），删除只影响这条消息的 `extra`，不触碰 `mes` 正文文本。

### 4.3 Data Bank：与消息 `extra` 并行的另一套体系

附件系统还有一层"数据库"概念（Data Bank / Attachment Manager，`chats.js:1330-1627`）：附件可以挂在三个不同作用域——全局 `extension_settings.attachments`、角色 `extension_settings.character_attachments[avatar]`、聊天 `chat_metadata.attachments`（`ATTACHMENT_SOURCE` 常量 `chats.js:77-81`），这套东西和消息本身的 `extra.files` 是两套并行体系（一个是"消息自带附件"，一个是"知识库文件，可能被 WI/prompt 注入用到"）。这两者关系没有在本次调查中完全打通验证——**未核实**具体注入路径。

## 5. Checkpoint 与 Branch：共用截断逻辑，数据语义不同

`bookmarks.js` 里两者共享的核心动作是"把 `chat` 数组截到某条消息为止，另存为一个新聊天文件"，区别在于：**Checkpoint 不跳转，Branch 会跳转**，且只有 Branch 支持"连同某个具体 swipe 版本"一起截断。

### 5.1 Checkpoint（`createNewBookmark`, `bookmarks.js:253-298`）

```js
const lastMes = chat[mesId];
if (typeof lastMes.extra !== 'object') lastMes.extra = {};
const isReplace = lastMes.extra.bookmark_link;   // 之前是否已经创建过 checkpoint
let name = await getBookmarkName({ isReplace, forceName });
...
await saveChat({ chatName: name, withMetadata: newMetadata, mesId });   // 单人聊天：截断保存为新文件
lastMes.extra.bookmark_link = name;   // 回链：这条消息记住了它对应的 checkpoint 文件名
const mes = $(`.mes[mesid="${mesId}"]`);
updateBookmarkDisplay(mes, name);
await saveChatConditional();   // 保存"当前主聊天"，把 bookmark_link 字段写回主聊天文件
```

`saveChat({..., mesId})` 内部（`script.js:7336-7421`）用 `chat.slice(0, Number(mesId) + 1)` 截断出快照另存新文件，**当前主聊天完全不受影响**。

`bookmark_link` 字段挂在**触发 checkpoint 的那条消息**的 `extra.bookmark_link` 上（存的是文件名字符串）。多次在同一条消息上创建 checkpoint 会覆盖旧的 `bookmark_link`（`isReplace` 分支只是改了弹窗提示文案，逻辑上就是直接覆盖，没有历史列表）。全聊天范围内有哪些消息带 checkpoint，靠 `/checkpoint-list` slash command（`bookmarks.js:650-677`）扫一遍 `chat` 数组找 `extra.bookmark_link` 存在的项，**没有维护一个专门的索引结构**。

### 5.2 Branch（`createBranch`/`branchChat`, `bookmarks.js:186-243, 449-469`）

```js
function getBranchChatSnapshot(mesId, { swipeId = null } = {}) {
    const snapshot = structuredClone(chat.slice(0, Number(mesId) + 1));
    if (swipeId === null) return snapshot;
    if (!syncSwipeToMes(null, swipeId, snapshot[mesId])) return null;  // 把快照里那条消息换成指定 swipe 版本
    return snapshot;
}
```

- **区别一**：Branch 的快照函数支持 `swipeId` 参数，把截断出来的最后一条消息**替换成某个特定 swipe 版本**（调用 `syncSwipeToMes(null, swipeId, snapshot[mesId])`，传入 `targetMessage` 参数直接操作快照对象而不碰真实 `chat[]`，避免了截断分支时污染主聊天当前显示的 swipe）。
- **区别二**：`createBranch` 保存完之后会往触发消息的 `extra.branches` 数组里追加分支文件名（`bookmarks.js:233-241`）。`extra.branches` 是数组（可以从同一条消息开多个分支），和 `extra.bookmark_link`（单值，会被覆盖）在语义上不同——**checkpoint 是"一条消息对应最多一个快照，新建会覆盖"；branch 是"一条消息可以有多个分支，新建是追加"**。
- **区别三（跳转）**：`branchChat()`（`bookmarks.js:449-469`）在 `createBranch` 成功后直接 `await openGroupChat(...)` 或 `await openCharacterChat(fileName)`，**必定跳转**。这与 Checkpoint 的"不跳转"形成对照。

两者都不支持群聊之外的"合并回主线"——一旦分叉，回到主聊天只能靠 `/checkpoint-exit`（`backToMainChat`，`bookmarks.js:312-326`，依赖 `chat_metadata.main_chat` 字段）手动切换文件，没有"树状导航 UI"，是纯粹的"另存为新文件"模型。

## 6. 群聊数据差异

- 群聊消息用 `extra.gen_id` 标记"同一轮生成"（`saveReply` 里 `newMessage.extra.gen_id = group_generation_id`，`script.js:6716`；转换单聊为群聊时也会手工造 `genIdFirst + index`，`bookmarks.js:400-419`），`regenerateGroup()`（`group-chats.js:167-188`）靠比较 `lastMes.extra.gen_id` 是否等于本轮 `generationId` 来决定要删掉几条尾部消息重新生成——这是群聊"重新生成"和单聊"swipe"完全不同的两套机制：单聊靠 `swipes` 数组保留候选，群聊靠 `gen_id` 分组 + 物理删除消息重新触发。
- 单人转群聊（`convertSoloToGroupChat`，`bookmarks.js:328-441`）会给除用户/系统消息外的每条消息强制写 `force_avatar`/`original_avatar`/`extra.gen_id`，这是一次性的、不可逆的格式迁移（确认提示里也写了"This cannot be reverted"，`bookmarks.js:339`）。

## 7. 设计取舍与已确认边界

- **整份读写、无分页**：聊天文件一次性读进内存和 DOM，长聊天的读写与渲染成本随长度线性增长（渲染层的"首屏截断 100 条"只是显示截断，数据仍是整份在内存）。
- **无索引结构**：checkpoint 定位靠全数组扫描，消息 ID 靠 DOM 顺序 + mesid 连续反推（后者是渲染层的脆弱假设，见消息渲染器笔记）。
- **integrity 防并发覆写**：以"弹窗要求手输 OVERWRITE"换取多标签页/多设备下的数据安全，交互代价高。
- **checkpoint/branch 不对称**：单值覆盖 vs 数组追加，是明确的数据设计差异（5.1/5.2）。
- **群聊与单聊的"重新生成"是两套机制**：swipes 保留候选 vs gen_id 物理删除（6）。
- **类目边界**：本笔记只回答数据语义；`Generate()` 的请求构建在对话请求与上下文；swipe/Swipe Picker/checkpoint 旗标的用户工作流在 Chat UI；DOM 渲染与流式更新在消息渲染器笔记。

## 8. 未验证事项

- `is_system`（隐藏消息）是否真的在 prompt 组装阶段被过滤（4.1）。
- `extra.files`（消息内嵌附件）与 Data Bank 之间在 World Info / prompt 注入层面的具体关系（4.3）。
- 崩溃恢复（保存中断、文件损坏）行为未实测。

## 9. 关键源码索引

- `public/script.js`：`chat`/`chat_metadata` 声明（410, 453）；`getChat`/`getChatResult`/`getFirstMessage`/`openCharacterChat`（7575-7693）；`saveChat`（7336-7421）；`ensureSwipes`/`syncMesToSwipe`/`syncSwipeToMes`（6773-6959）；`saveReply`（6583-6770）；`deleteSwipe`（9279-9329）
- `public/scripts/bookmarks.js`：`createNewBookmark`/`updateBookmarkDisplay`（253-310）；`getBranchChatSnapshot`/`createBranch`/`branchChat`（165-243, 449-469）；`backToMainChat`（112-126, 312-326）；`convertSoloToGroupChat`（328-441）
- `public/scripts/chats.js`：`hideChatMessageRange`（147-169）；附件上传/删除/媒体切换（198-1120）
- `public/scripts/group-chats.js`：`getGroupChat`（255-320）；`saveGroupChat`（623-675）；`regenerateGroup`（167-188）
- `src/endpoints/chats.js`：`trySaveChat`/完整性检查（310-468）；`/save` `/get` `/group/save` `/group/get` 路由（470-544, 797-872）
- `src/endpoints/groups.js`：群组 JSON 存储（1-150）

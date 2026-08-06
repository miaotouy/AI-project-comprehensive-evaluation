# SillyTavern Chat 调查笔记

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：未确认
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：只读源码，逐文件通读 + 针对性 grep 定位后再展开读取上下文
>
> 调查范围：聊天会话、消息状态、存储、流式更新与交互机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

实际读代码后发现，聊天的状态机、swipe、消息渲染主体都在 `script.js` 里：`chats.js` 只是消息级工具函数（隐藏/附件/媒体）的集合，`streaming-display.js` 是一个跟主聊天渲染完全脱钩的悬浮通知组件。下面会具体说明。

## 定位

SillyTavern 把"聊天"实现为一个**驻留在内存里的可变数组 + 定期整份序列化到 JSONL 文件**的模型，而不是增量事件日志或数据库表。核心状态变量都在 `public/script.js` 顶层声明：

```js
// public/script.js:410
export let chat = [];
// public/script.js:453
export let chat_metadata = {};
```

`chat` 是一个 `ChatMessage[]`，所有渲染、生成、保存逻辑都直接读写这个数组本身（不是不可变数据流）。`chat_metadata` 挂着聊天级元数据：`main_chat`（checkpoint 回链父聊天名）、`tainted`（是否已脱离"纯净"首条问候语状态，`script.js:1659`/`4288`/`5846`/`8131`/`9323`/`11669` 等多处写入）、`integrity`（防止并发覆写用的 UUID slug）、`attachments`（聊天级附件）等。

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

## 会话与历史

### 加载与"新鲜聊天"判定

`openCharacterChat(file_name)`（`script.js:7685-7693`）流程：等待没有正在进行的保存 → `clearChat({clearData:true})` 清空内存和 DOM → 设置 `characters[this_chid].chat = file_name` → `getChat()`。`getChat()` 读完文件后调用 `getChatResult()`（`script.js:7625-7649`），其中有个关键分支：如果 `chat.length === 0`（文件不存在或为空），会调用 `getFirstMessage()`（`script.js:7651-7683`）现造一条问候语消息塞进去，且**问候语的多个 `alternate_greetings` 直接被塞成这条消息的 `swipes` 数组**（`swipes = [message.mes, ...alternateGreetings...]`，`swipe_id = 0`）——也就是说，角色卡的"备选开场白"功能，底层实现就是把 swipe 机制直接复用在第 0 条消息上。

群聊加载 `getGroupChat()`（`group-chats.js:255-320`）在"全新聊天"（`freshChat = !metadata.tainted && 数据为空`）分支下，会遍历 `group.members`，给每个成员各生成一条首条消息（`getFirstCharacterMessage`），这意味着群聊的"开场"可以是多条消息（每个成员各一条），而单人聊天只有一条。

### 消息如何进 DOM：没有虚拟化，是"整体重绘 + 追加"

`printMessages()`（`script.js:1475-1488`）是聊天窗口初始渲染入口：

```js
let count = power_user.chat_truncation || Number.MAX_SAFE_INTEGER;
if (chat.length > count) {
    startIndex = chat.length - count;
    chatElement.append('<div id="show_more_messages">Show more messages</div>');
}
await redisplayChat({ startIndex, fade: false });
```

`power_user.chat_truncation` 默认值 100（`power-user.js:133`）。也就是**默认只把最近 100 条消息渲染进 DOM**，更早的消息完全不在 DOM 里，靠一个"Show more messages"按钮触发 `showMoreMessages()`（`script.js:1431-1473`）按需向前追加。但这不是虚拟化——`showMoreMessages` 只会往 DOM 里"加"更早的消息节点，从不会把已经显示的节点移除；用户如果反复点"加载更多"，DOM 节点数会随聊天长度线性增长且永不回收。没有虚拟化，实际是"首屏截断 100 条 + 单向增量追加，永不回收"，而不是分页替换。

`redisplayChat()`（`script.js:1497-1530`）是重绘的核心：先把 `startIndex` 及之后的 DOM 节点全部移除，再用 `updateMessageElement()` 批量重建，一次性 `chatElement.append(newMessageElements)`。之后调用 `refreshSwipeButtons(false, fade)`。这个函数在 swipe 失败回退（`endSwipe()` 内，`script.js:10021-10022`）、外部媒体权限切换（`reloadCurrentChat`）等场景都会被整段调用，也就是"局部状态变化触发一大段 DOM 重建"，长聊天下这类操作会有明显的重绘成本。

`refreshSwipeButtons()`（`script.js:9190-9249`）本身也是全量扫描：`chatElement.children('.mes[mesid]')` 拿到**当前 DOM 里所有已渲染消息节点**（不区分是不是刚变化的那条），逐个用 `firstDisplayedMesId + index` 反推消息 ID（注释里明说这个假设依赖 DOM 顺序和 mesid 连续，比按属性查找快但脆弱），逐条判断是否可 swipe、是否显示 picker 按钮等。这意味着聊天越长（DOM 里堆的消息越多），每次调用 `refreshSwipeButtons` 的成本越高——而它在发消息、swipe、隐藏消息（`chats.js:166`)、加载完成等几乎所有交互后都会被调用。这是一个具体可指出的性能设计取舍点：用"扫描整个已渲染 DOM"换取实现简单，长聊天+高频操作（比如连续 swipe）会有可感知的卡顿风险,但这属于推断，未做实际性能测量，标注为**未核实（性能实测）**。

### 消息隐藏/恢复、附件删除（`chats.js` 的真正职责）

`chats.js` 里没有聊天存储逻辑，它是消息级"编辑动作"的集合：

- `hideChatMessageRange(start, end, unhide, nameFitler)`（`chats.js:147-169`）：遍历区间内消息，把 `message.is_system` 置为 `hide`，同时同步 DOM 上 `.mes` 的 `is_system` 属性，最后调 `refreshSwipeButtons()`（因为最后一条消息隐藏会影响能不能 swipe）并 `saveChatConditional()`。隐藏是"标记为系统消息"，不是删除、不改变数组顺序，对 prompt 构建的影响没有在这个文件里体现（需要看 prompt 构建代码确认 `is_system` 是否被过滤——**未核实**，本次未深入 `script.js` 的 prompt 组装函数验证隐藏消息是否真的被排除在发送给模型的上下文之外）。
- 附件删除：`deleteMessageFile`（`chats.js:395-427`）、`deleteMessageMedia`（`chats.js:978-1060`）都是"改 `message.extra.files`/`extra.media` 数组 + 调服务器 `/api/files/delete` 或 `/api/images/delete` + `saveChatConditional()` + 重新渲染该条消息的媒体区块"，附件本身是独立于 `chat[]` 消息文本之外的对象数组（`extra.media: MediaAttachment[]`、`extra.files: FileAttachment[]`），删除只影响这条消息的 `extra`，不触碰 `mes` 正文文本。
- 附件系统还有一层"数据库"概念（Data Bank / Attachment Manager，`chats.js:1330-1627`）：附件可以挂在三个不同作用域——全局 `extension_settings.attachments`、角色 `extension_settings.character_attachments[avatar]`、聊天 `chat_metadata.attachments`（`ATTACHMENT_SOURCE` 常量 `chats.js:77-81`），这套东西和消息本身的 `extra.files` 是两套并行体系（一个是"消息自带附件"，一个是"知识库文件，可能被 WI/prompt 注入用到"）。这两者关系没有在本次调查中完全打通验证——**未核实**具体注入路径。

## Checkpoint 与 Branch：两个概念共用一套底层截断逻辑，但用户可见行为完全不同

`bookmarks.js` 里两者共享的核心动作是"把 `chat` 数组截到某条消息为止，另存为一个新聊天文件"，区别在于：**Checkpoint 不跳转，Branch 会跳转**，且只有 Branch 支持"连同某个具体 swipe 版本"一起截断。

### Checkpoint（`createNewBookmark`, `bookmarks.js:253-298`）

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

`saveChat({..., mesId})` 内部（`script.js:7336-7421`，`bookmarks.js` 通过导入调用）用 `chat.slice(0, Number(mesId) + 1)` 截断出快照另存新文件，**当前主聊天完全不受影响，用户视角上什么都没跳转**——`createNewBookmark` 里没有任何 `openCharacterChat`/`openGroupChat` 调用。之所以不自动跳转，从代码语义看是设计意图：Checkpoint 定位是"给某个节点打一个可以随时回来看的快照标记"，创建后 toast 提示是"Click the flag icon next to the message to open the checkpoint chat"（`bookmarks.js:296`）——即需要用户主动点击消息旁的旗标才会跳转（`initBookmarks()` 里 `.mes_bookmark` 点击处理，`bookmarks.js:685-720`，会检查 `e.shiftKey`：按住 Shift 点旗标是"再建一个新 checkpoint"，否则才是打开已有的 `bookmark_link` 指向的文件）。

`bookmark_link` 字段挂在**触发 checkpoint 的那条消息**的 `extra.bookmark_link` 上（存的是文件名字符串），`updateBookmarkDisplay()`（`bookmarks.js:306-310`）把这个值同步写到消息 DOM 元素的 `bookmark_link` 属性上，并更新旗标图标的 tooltip。多次在同一条消息上创建 checkpoint 会覆盖旧的 `bookmark_link`（`isReplace` 分支只是改了弹窗提示文案，逻辑上就是直接覆盖，没有历史列表）。全聊天范围内有哪些消息带 checkpoint，靠 `/checkpoint-list` slash command（`bookmarks.js:650-677`）扫一遍 `chat` 数组找 `extra.bookmark_link` 存在的项，**没有维护一个专门的索引结构**。

### Branch（`createBranch`/`branchChat`, `bookmarks.js:186-243, 449-469`）

```js
function getBranchChatSnapshot(mesId, { swipeId = null } = {}) {
    const snapshot = structuredClone(chat.slice(0, Number(mesId) + 1));
    if (swipeId === null) return snapshot;
    if (!syncSwipeToMes(null, swipeId, snapshot[mesId])) return null;  // 把快照里那条消息换成指定 swipe 版本
    return snapshot;
}
```

区别一：Branch 的快照函数支持 `swipeId` 参数，把截断出来的最后一条消息**替换成某个特定 swipe 版本**（调用 `syncSwipeToMes(null, swipeId, snapshot[mesId])`，传入 `targetMessage` 参数直接操作快照对象而不碰真实 `chat[]`，避免了截断分支时污染主聊天当前显示的 swipe）。这就是为什么 swipe picker 里"从某个候选回复分叉"能work（见下文 swipe picker 一节）。

区别二：`createBranch` 保存完之后会往触发消息的 `extra.branches` 数组里追加分支文件名（`bookmarks.js:233-241`）：

```js
if (typeof lastMes.extra.branches !== 'object') lastMes.extra.branches = [];
lastMes.extra.branches.push(name);
```

`extra.branches` 是数组（可以从同一条消息开多个分支），和 `extra.bookmark_link`（单值，会被覆盖）在语义上不同——**checkpoint 是"一条消息对应最多一个快照，新建会覆盖"；branch 是"一条消息可以有多个分支，新建是追加"**。这是我读代码前没预料到的不对称设计，值得记录。

区别三（跳转）：`branchChat()`（`bookmarks.js:449-469`）在 `createBranch` 成功后直接 `await openGroupChat(...)` 或 `await openCharacterChat(fileName)`，**必定跳转**。这与 Checkpoint 的"不跳转"形成对照，`bookmarks.js:517` 的 slash command 帮助文本里也直接写明了选择逻辑："Use Checkpoints ... if you do not want to jump to the new chat"。

两者都不支持群聊之外的"合并回主线"——一旦分叉，回到主聊天只能靠 `/checkpoint-exit`（`backToMainChat`，`bookmarks.js:312-326`，依赖 `chat_metadata.main_chat` 字段）手动切换文件，没有"树状导航 UI"，是纯粹的"另存为新文件"模型，checkpoint/branch 在 `extra` 字段设计上存在不对称性（见上文）。

## Swipe 机制

### 数据结构

一条可 swipe 的消息在稳定状态下有三个并行数组/字段：

```js
message.mes         // 当前显示的正文（=swipes[swipe_id] 的镜像）
message.swipe_id     // 当前选中的候选下标
message.swipes       // string[]，每个候选版本的正文
message.swipe_info   // 与 swipes 等长的数组，每项 {send_date, gen_started, gen_finished, extra}
```

`ensureSwipes(message)`（`script.js:6778-6828`）是懒惰迁移函数：老聊天文件里消息可能没有这三个字段，读取时如果缺失就用当前 `mes` 现造一个长度为 1 的 `swipes` 数组、`swipe_id=0`、对应的 `swipe_info`；如果 `swipes[i]` 类型不对也会强制纠正为空字符串并打印警告。用户消息和"小型系统消息"（`extra.isSmallSys`）被显式排除在 swipe 体系外（`script.js:6787-6789`）。

两个同步方向的函数容易搞混，但职责严格区分：
- `syncMesToSwipe(messageId)`（`script.js:6837-6883`）：把当前 `message.mes`/时间戳/`extra` **写回**到 `swipes[swipe_id]`/`swipe_info[swipe_id]`——用在"用户编辑了正文之后要更新到对应的 swipe 存档里"的场景。有个细节：只有 `chat_metadata.tainted || chat.length > 1` 时才真的写回 `swipes[swipe_id]`（`script.js:6873`），注释说明是为了让"纯净首条问候语"在每次进聊天时宏还能重新解析——即第 0 条消息在全新/未变动状态下故意不落盘同步，保留重新求值的空间。
- `syncSwipeToMes(messageId, swipeId, targetMessage)`（`script.js:6895-6959`）：反方向，把 `swipes[swipeId]` **读出来**覆盖 `message.mes`/时间戳/`extra`——用在"用户切到某个候选版本"时。这个函数支持传入 `targetMessage` 直接操作一个游离对象（不一定是 `chat[]` 里的真实消息），这正是上面 Branch 快照选 swipe 时复用的路径。

`swipe(event, direction, {...})`（`script.js:9894-约10110+`）是完整的用户交互流程：先做一堆守卫检查（是否在生成中、是否允许 swipe、消息是否可 swipe），然后 `cancelDebouncedChatSave()` 防止防抖保存打断 `swipe_id` 变更，进入 `SWIPE_STATE.SWIPING` 状态锁；`loadFromSwipeId()`（`script.js:10081-10096`）更新 `swipe_id` 并清掉一批过时的 `extra` 字段（`memory`/`display_text`/`media`/`files`/`title` 等，`clearMessageData`，`script.js:10059-10074`——即切换 swipe 版本时会丢弃当前版本特有的媒体/标题等派生数据，这些数据下次要重新生成或从对应 `swipe_info[swipe_id].extra` 里恢复）；接着调 `syncSwipeToMes`，失败（比如索引越界导致数据不一致）会自动 `swipe(true)` 尝试恢复原状，如果连恢复都失败则弹确认框强制 `reloadCurrentChat()`——这是一处对"数据结构一旦损坏就整页重载"的防御性容错，说明作者预期这套 swipe 状态是有可能损坏的（比如扩展直接乱改 `chat[]`）。

"往右划到最后一个 swipe 之后会怎样"由 `getOverswipeBehavior()`（`script.js:9163-9181`）决定，是个不算小的状态机：
- 显式设置了 `extra.overswipe_behavior` 就用那个；
- `extra.swipeable === false`（比如欢迎屏幕消息）→ `NONE`（不可 swipe）；
- `extra.isSmallSys` → `NONE`；
- 是聊天里第 0 条消息且整个聊天还是"纯净"状态（`!chat_metadata.tainted`）→ `PRISTINE_GREETING`（会一直循环切换 alternate_greetings，chevron 常驻显示）；
- 非用户非系统消息（即角色消息）→ `REGENERATE`（划到底会触发重新生成）；
- 其它情况 → `LOOP`（回到第一个候选）。

这个矩阵在 `refreshSwipeButtons()` 里被用来决定要不要显示"划到底了会重新生成"的视觉提示（`isOverswipeable`/`last_swipe` class，`script.js:9230-9235`）。

### `refreshSwipeButtons()` 的具体逻辑（`script.js:9190-9249`）

已在"没有虚拟化"一节描述其扫描方式，补充其判定内容：对每个 DOM 消息节点算出 `isLastSwipe`（是否停在最后一个候选）、`hasSwipes`（候选数 > 1）、结合 `getOverswipeBehavior` 结果决定 `swipes_visible`/`last_swipe` 这两个 CSS class，以及 swipe picker 按钮的显隐（`canOpenSwipePickerForMessage`）。`updateCounters` 参数为 true 时才会去更新每条消息的"第几个/共几个"计数器文本（`updateSwipeCounter`），默认 false 是因为大部分调用点已经在别处单独更新了计数器，这里避免重复开销。

### Swipe Picker（`swipe-picker.js`，全文已读）

这是 UI 层的候选浏览器，不是新的存储结构——`openSwipePicker(messageId)`（L52-410）直接读 `chat[messageId].swipes`/`swipe_info` 渲染成一个可滚动列表，每项可以：跳转（双击或点 Go，走 `swipe(null, direction, {source: SWIPE_SOURCE.SWIPE_PICKER, forceMesId, forceSwipeId})`）、删除（`deleteSwipe`）、复制文本、或者**从这个候选创建分支**（`swipe-picker.js:160-174`：点击分支按钮记录 `branchActionSwipeId = index` 并关闭弹窗，弹窗关闭后 `await branchChat(messageId, { swipeId: branchActionSwipeId })`，`swipe-picker.js:387-390`）。这就是"以某个 swipe 为基础开分支"在 UI 上唯一的入口，底层调用链和 slash command `/branch-create` 一致，都汇到 `bookmarks.js` 的 `createBranch`。

`deleteSwipe(swipeId, messageId)`（`script.js:9279-9329`）：至少保留 1 个 swipe（不允许删空），删除后按"删的是不是当前选中项"决定新 `swipe_id`（删除项在当前项之前就整体减 1，删的正好是当前项就选下一个或前一个），并把 `chat_metadata.tainted = true`（删除 swipe 后聊天不再"纯净"，影响上面说的 `PRISTINE_GREETING` 判定）。

## 流式显示：两套容易混淆的不同机制

`streaming-display.js`（全文已读，430 行）**不是**主聊天消息的流式渲染实现，而是一个独立的浮层通知组件（"toast-like display panel"，文件顶部注释自称如此），设计给 slash command 场景使用：

```
public/style.css:18       @import url(css/streaming-display.css);
connection-manager/index.js:19  import { StreamingDisplay } from '/scripts/streaming-display.js';
connection-manager/index.js:581 const display = new StreamingDisplay();
```

全代码库里只有 `connection-manager/index.js` 一处消费它，用在 `/profile-genstream` 这个 slash command（`connection-manager/index.js:1049-1120` 附近的命令定义）——用户用 slash command 发起一次独立生成请求时，用这个悬浮面板显示推理/正文流式内容，附带一个"Stop"按钮（`onStop` 回调）和自动最小化/关闭逻辑。它渲染用的是同一个 `messageFormatting()` 函数（`streaming-display.js:265, 281`），所以格式化规则（正则替换、Markdown、DOMPurify 消毒）是共享的，但**它完全脱离 `chat[]` 数组和主聊天 DOM**，不参与消息保存、不参与 swipe。

主聊天真正的流式渲染实现是 `script.js` 里的 `StreamingProcessor` 类（`script.js:3481-3853`），这是 `chats.js`/`streaming-display.js` 都没有涉及、但对聊天功能是核心的部分：

- `onStartStreaming()`（`3562-3582`）：非 impersonate 类型先 `saveReply({fromStreaming:true})` 在 `chat[]` 里占位新建一条消息，取 `messageId = chat.length - 1`，然后 `hideSwipeButtons({hideCounters:true})`——**流式过程中会主动隐藏 swipe 按钮**，防止用户在流没结束时误触 swipe。
- `onProgressStreaming(messageId, text, isFinal)`（`3584-3685`）：每个节流周期（`Stopwatch(1000 / power_user.streaming_fps)`，`3814`）调用一次，流程是 `cleanUpMessage()` 清洗文本（含正则替换、停止串裁剪、括号/引号配平补全，`3600-3614`）→ 直接写 `chat[messageId].mes = processedText` → 调 `messageFormatting()` 生成 HTML → 写入 `this.messageTextDom.innerHTML`（或走 `applyStreamFadeIn` 做形态渐变，见下）。**如果当前类型是 `swipe`/`continue`，还会同步写 `chat[messageId].swipes[chat[messageId].swipe_id] = processedText`**（`3646-3654`）——即流式生成 swipe 候选时，`swipes` 数组是随着每个 token 增量同步更新的，不是等生成完才写入。
- `this.messageDom`/`this.messageTextDom` 等 DOM 引用是在 `#checkDomElements()`（`3534-3545`）里**懒加载并缓存**的（`if (this.messageDom === null ...) { this.messageDom = document.querySelector(...) }`）——只查询一次。这里存在一个具体的时序脆弱点：如果流式生成过程中发生了 `redisplayChat()`（比如用户在生成中途触发了"Show more messages"、或者别的代码路径整段重绘了 DOM），旧的 `messageDom`/`messageTextDom` 引用会指向已经被 `.remove()` 的分离节点，后续 `innerHTML` 赋值不会报错但也不会显示在页面上，只是悄悄写入一个已经脱离文档树的元素。代码里没有对此做重新查询或校验，**这是一个我在读代码时确认存在、但未做运行时复现验证的潜在缺陷**（标注为未核实的运行时行为，逻辑路径本身是确认读到的）。
- 打字机式渐入效果：`power_user.stream_fade_in` 为真时走 `applyStreamFadeIn()`（`util/stream-fadein.js:65-69`，已读全文），用 `morphdom` 把新 HTML 与旧 DOM 做 diff 合并，并用 `Intl.Segmenter` 把文本按词/字素切成 `<span class="text_segment">` 以配合 CSS 逐词淡入。这解释了"流式显示如何与正则替换共存"：**正则替换发生在 `cleanUpMessage`/`messageFormatting` 内部，生成的是最终 HTML 字符串，`morphdom` 只是把这段已经处理完的 HTML 差量应用到 DOM，不会跟正则处理产生交互问题**——正则替换和流式渐入是串行的两个阶段，没有并发冲突设计上的坑。本次调查没有找到实际的时序 bug，只找到上面提到的"DOM 引用缓存失效"这一点。
- 与扩展 DOM hook 的关系：流式过程中，`event_types.CHARACTER_MESSAGE_RENDERED`/`MESSAGE_RECEIVED` 事件**只在流结束时**（`onFinishStreaming`→`finalizeIntermediaryMessage`，`3739-3746`）才 emit 一次,不是每个 token 都 emit。也就是说，任何监听这两个事件来对消息 DOM 做二次处理的扩展（比如给消息加自定义按钮、渲染额外 UI 元素），**在流式过程中的每一帧渲染都不会触发**，只有流结束后才跑一次。这是聊天渲染与扩展 hook 之间的一个确认存在的真实时序特征：流式期间的 DOM 更新路径（`StreamingProcessor` 直接操作 `innerHTML`）和扩展常规介入路径（监听 `CHARACTER_MESSAGE_RENDERED` 后处理 DOM）是分离的、不同步的，扩展如果假设"每次消息内容变化都会收到事件"就会在流式场景下失效。

工具调用（tool calls）路径里还有一处 `finalizeIntermediaryMessage({unlockUI:false})` 的中间调用（`script.js:5357`），用于流结束但还要触发工具调用时先把消息落盘但不解锁输入框——这说明"流式结束"和"生成流程结束"在工具调用场景下是两个不同的时间点，`streamingProcessor = null` 可能被延后到工具调用结果处理完之后（`script.js:5369/5373/5382`）。

## 消息隐藏/恢复、附件删除（已在"会话与历史"一节详述，此处不重复）

## slash command / Quick Reply / 宏 / 正则对聊天的介入点

这四者不是外围功能，而是**直接嵌入在发送/生成/渲染这条主链路的具体节点上**，证据如下：

1. **Slash command 可以整体劫持发送流程**：`Generate()` 函数（`script.js:4231`）在真正调用生成 API 之前，先执行

   ```js
   // script.js:4251-4258
   if (!(dryRun || depth || type == 'regenerate' || type == 'swipe' || type == 'quiet')) {
       const interruptedByCommand = await processCommands(String($('#send_textarea').val()));
       if (interruptedByCommand) { unblockGeneration(type); return Promise.resolve(); }
   }
   ```
   `processCommands()`（`script.js:3066-3074`）判断输入框内容是否以 `/` 开头，是的话整段交给 `executeSlashCommandsOnChatInput()` 执行，且**如果被判定为"打断"，本次 Generate 直接短路返回，不会有任何生成请求发出**。这意味着任何用户输入只要触发 slash command 解析，就完全绕开了模型调用——这是比"外围工具"更深的介入方式：命令解析发生在生成函数内部的最前面，是决定"这次发送到底要不要变成一次生成请求"的判断点。

2. **正则替换按位置分层，分别影响存储/展示/发送三个不同阶段**（`extensions/regex/engine.js:334-374`，`getRegexedString` 已读全文逻辑）：每个正则脚本可标记 `markdownOnly`/`promptOnly`，三者互斥生效：
   - 不带任何标记的脚本：在 `cleanUpMessage()`（`script.js:6422`，流式/非流式生成收到文本后都会走这里）里被应用，**结果直接写回 `chat[messageId].mes`，会持久化进聊天文件**；
   - `markdownOnly` 脚本：只在 `messageFormatting()`（`script.js:1809-1813`，渲染时调用，传 `isMarkdown:true`）里生效，**只影响显示 HTML，从不写回 `chat[]` 或存盘**；
   - `promptOnly` 脚本：只在构建发给模型的 prompt 时生效（未在本次调查中追踪到具体调用点，**未核实**其确切位置，但从 `regex_placement.SLASH_COMMAND`/`WORLD_INFO` 等枚举值可推断存在专门的 prompt 组装阶段调用）。
   还有基于消息"深度"（`depth`，离最新消息的距离，`messageFormatting` 内 `script.js:1804-1806` 计算）的 `minDepth`/`maxDepth` 过滤，允许"只对最近 N 条消息生效"的正则脚本——这对长聊天的展示一致性是有代价的：同一条历史消息在聊天变长后，它的"深度"会变化，如果规则按深度生效，那么**同一条消息在不同时间点重新渲染，可能因为深度跨越了阈值而显示不同结果**（比如从"深度 3 内生效"变成"深度 5 不生效"）。这是我在读 `engine.js` 逗号级细节后确认存在的具体设计后果,不是猜测。

3. **宏替换嵌入在存储、展示、prompt 构建三处不同代码路径**：`substituteParams()`（`script.js:2922` 定义）在 `sendMessageAsUser`（`5816, 5823`，用户消息发送时替换 `USER_INPUT` 位置的宏）、`messageFormatting`（`1761`，但只对**第 0 条消息**在渲染时懒替换，见下）、`power_user.user_prompt_bias` 处理（`1780, 6401`）等多处独立调用,不是一次性统一处理。第 0 条消息的特殊路径值得单独记录：

   ```js
   // script.js:1758-1764
   if (Number(messageId) === 0 && !isSystem && !isUser && !isReasoning) {
       const mesBeforeReplace = mes;
       const chatMessage = chat[messageId];
       mes = substituteParams(mes, undefined, ch_name);
       if (chatMessage && chatMessage.mes === mesBeforeReplace && chatMessage.extra?.display_text !== mesBeforeReplace) {
           chatMessage.mes = mes;
       }
   }
   ```
   只有第 0 条（角色首条问候语）在**每次渲染时**都重新跑一次宏替换，且如果替换前后 `chat[0].mes` 没被别处改过，会把替换结果写回 `chat[0].mes`——这是为了让 `{{time}}`、`{{random}}` 一类含时效性的宏在问候语里保持"新鲜"，其它消息的宏则是发送时一次性替换、之后固定。这个不对称设计如果不读代码是发现不了的。

4. **Quick Reply 挂在消息渲染完成事件上，且用 `makeFirst` 抢占执行顺序**：`extensions/quick-reply/index.js:275, 282, 292`：
   ```js
   eventSource.on(event_types.CHAT_CHANGED, ...)                                    // 切换聊天时重载该角色的 QR 集合
   eventSource.makeFirst(event_types.USER_MESSAGE_RENDERED, ...onUserMessage...)     // 用户消息渲染后自动触发
   eventSource.makeFirst(event_types.CHARACTER_MESSAGE_RENDERED, ...onAiMessage...)  // 角色消息渲染后自动触发
   ```
   `makeFirst` 意味着 Quick Reply 的自动化钩子会**在其它同事件监听器之前**执行，如果自动回复规则命中，可能在其它扩展还没处理完当前消息前就已经发起了下一轮生成——这是一个具体的事件顺序耦合点，说明 Quick Reply 不是"外挂在消息发完之后"的旁路功能，而是插在事件分发链最前面的强介入点。

综合看，这四类扩展点分别嵌入在：发送前拦截（slash command）、生成后文本清洗（正则-非markdown）、渲染时格式化（正则-markdown + 宏第0条特例）、渲染完成后自动化（Quick Reply）——**四个不同的生命周期节点**，而不是单一的"扩展系统"统一调度。

## 群聊与单人聊天的关键差异

- 群聊消息用 `extra.gen_id` 标记"同一轮生成"（`saveReply` 里 `newMessage.extra.gen_id = group_generation_id`，`script.js:6716`；转换单聊为群聊时也会手工造 `genIdFirst + index`，`bookmarks.js:400-419`），`regenerateGroup()`（`group-chats.js:167-188`）靠比较 `lastMes.extra.gen_id` 是否等于本轮 `generationId` 来决定要删掉几条尾部消息重新生成——这是群聊"重新生成"和单聊"swipe"完全不同的两套机制：单聊靠 `swipes` 数组保留候选，群聊靠 `gen_id` 分组 + 物理删除消息重新触发。
- 单人转群聊（`convertSoloToGroupChat`，`bookmarks.js:328-441`）会给除用户/系统消息外的每条消息强制写 `force_avatar`/`original_avatar`/`extra.gen_id`，这是一次性的、不可逆的格式迁移（确认提示里也写了"This cannot be reverted"，`bookmarks.js:339`）。

## UI 交互与呈现小结

SillyTavern 的聊天 UI 是“可变数组 + DOM 操作 + 扩展事件”的组合：首屏默认只呈现最近 100 条，`Show more messages` 向前追加且不回收；流式 token 直接写入占位消息的 DOM，完成后再触发 `CHARACTER_MESSAGE_RENDERED`/`MESSAGE_RECEIVED`。因此 swipe、checkpoint、branch、正则、宏和 Quick Reply 都是用户能直接看到的操作，但分别插在生成前、生成中、渲染时和渲染完成事件上，并不是一个统一的 UI 状态层。

从交互路径看：发送框可被 slash command 短路，角色回复通过 swipe 左右切换或打开 Swipe Picker，checkpoint 只保存快照而不跳转，branch 保存后立即打开新聊天；群聊则以 `gen_id` 批量重生并支持成员调度。这个呈现方式自由度很高，代价是长聊天反复 `redisplayChat`/`refreshSwipeButtons` 会扫描或重建大量 DOM，流式期间若发生整段重绘还可能让缓存的节点引用脱离文档（前文已标为未实测运行时风险）。

## 主要依据（文件与关键行号）

- `public/script.js`：`chat`/`chat_metadata` 声明（410, 453）；`getChat`/`getChatResult`/`getFirstMessage`/`openCharacterChat`（7575-7693）；`saveChat`（7336-7421）；`printMessages`/`redisplayChat`/`showMoreMessages`（1431-1530）；`clearChat`/`deleteMessage`/`deleteLastMessage`（1584-1673）；`ensureSwipes`/`syncMesToSwipe`/`syncSwipeToMes`（6773-6959）；`saveReply`（6583-6770）；`isSwipingAllowed`/`isMessageSwipeable`/`getOverswipeBehavior`/`refreshSwipeButtons`/`showSwipeButtons`/`hideSwipeButtons`/`deleteSwipe`（9100-9329）；`swipe()` 主流程（9894-10110+）；`StreamingProcessor` 类（3481-3853）；`Generate()` 与 `processCommands` 拦截点（4231-4262, 3066-3074）；`messageFormatting`（1753-1912）；`sendMessageAsUser`（5815-5864）。
- `public/scripts/bookmarks.js`：`createNewBookmark`/`updateBookmarkDisplay`（253-310）；`getBranchChatSnapshot`/`createBranch`/`branchChat`（165-243, 449-469）；`backToMainChat`/`getMainChatName`（112-126, 312-326）；`convertSoloToGroupChat`（328-441）；`initBookmarks` 事件绑定（680-737）。
- `public/scripts/chats.js`：`hideChatMessageRange`（147-169）；附件上传/删除/媒体切换（198-1120）；`initChatUtilities` 事件绑定（2109-2422）。
- `public/scripts/group-chats.js`：`getGroupChat`（255-320）；`saveGroupChat`（623-675）；`saveGroupBookmarkChat`（2358-2394）；`regenerateGroup`（167-188）。
- `public/scripts/streaming-display.js`：全文件（1-430），确认其为独立浮层组件。
- `public/scripts/swipe-picker.js`：全文件（1-445），`canOpenSwipePickerForMessage`/`openSwipePicker`/分支联动（387-390）。
- `public/scripts/util/stream-fadein.js`：全文件（1-70）。
- `public/scripts/extensions/regex/engine.js`：`getRegexedString`（334-374）。
- `public/scripts/power-user.js`：`chat_truncation` 默认值（133）。
- `public/scripts/extensions/quick-reply/index.js`：事件绑定（258-297）。
- `src/endpoints/chats.js`：`trySaveChat`/完整性检查（310-468）；`/save` `/get` `/group/save` `/group/get` 路由（470-544, 797-872）。
- `src/endpoints/groups.js`：群组 JSON 存储、群聊元数据迁移（1-150）。

## 未核实事项（本次未能完全验证，需要进一步确认再下结论）

- `is_system`（隐藏消息）是否真的在 prompt 组装阶段被过滤，未追踪到具体的 prompt 构建函数代码验证。
- `extra.files`（消息内嵌附件）与 Data Bank（`extension_settings.attachments` 等）之间在 World Info / prompt 注入层面的具体关系。
- `promptOnly` 正则脚本的具体调用点（只从枚举值推断存在，未定位到调用代码)。
- `StreamingProcessor` 缓存的 DOM 引用在流式过程中被整段重绘（`redisplayChat`）后失效的问题，只验证了代码路径存在这个风险，未做运行时复现。
- 长聊天下 `refreshSwipeButtons`/`redisplayChat` 的实际性能影响，只做了代码层面的复杂度分析（全量 DOM 扫描/重建），未做实测基准。
## 12. UI 交互与快捷键详查

消息 hover 操作栏提供复制、编辑、删除、编辑目标上移/下移、复制当前编辑消息为新消息、取消和确认编辑；操作栏可展开或自动收起。助手消息有 swipe 左右和历史计数器，Swipe Picker 可选历史候选；代码块有 Copy code，附件/媒体支持预览、编辑和删除。

`send_textarea` 按设置决定 Enter 是否发送，Shift+Enter 换行；Alt+Enter 继续生成；Ctrl+Enter 在输入为空时重新生成最后回复，在有文本时按发送逻辑处理，编辑态则确认编辑。Ctrl+Shift+Up 跳到上下文行，Ctrl+Shift+Down 回到底部；空输入时 ArrowUp 编辑最后消息，Ctrl+ArrowUp 优先编辑最后一条用户消息，未聚焦输入框时 ArrowLeft/Right 切换最后一条 swipe；Escape 关闭/提交编辑，生成中停止。

Agent/群组列表点击即切换；Agent 设置面板可改名、头像、系统提示词、模型、Temperature、上下文/输出 Token、Top P/Top K、流式开关和 TTS。Quick Reply、slash command、预设/模型选择器提供运行中快速切换；标题栏有气泡/统一/刊物 presentation mode。

## 13. UI 交互再深挖：弹窗、状态反馈与无障碍

本节聚焦第 12 节没有覆盖的实现细节：弹窗系统内部机制、toastr 配置、加载/空状态、右键菜单、主题存储、无障碍现状、响应式断点、动画参数、图片预览、拖放导入、扩展面板结构。全部基于 `E:\works\git\SillyTavern` 同一快照（`8172dcd0e`）读码得出，逐条标注文件行号；查无实据的地方直接写"未找到"。

### 13.1 弹窗系统：原生 `<dialog>` + 自研 Popup 类，不是 jQuery UI Dialog

`public/scripts/popup.js`（全文已读，966 行）是整个弹窗系统的唯一实现。核心结论：**底层用的是浏览器原生 `<dialog>` 元素，不是 jQuery UI Dialog**，jQuery UI 在这里只用于别的组件（比如 `.sortable()`，见 13.10）。

- `Popup` 构造函数（`popup.js:195-236`）从 `#popup_template`（一个 `<template>`）克隆出 `.popup`（即一个 `<dialog>`），如果浏览器不支持 `showModal()`（`this.dlg.showModal` 为假）就用 `dialogPolyfill.registerDialog()`（`../lib/dialog-polyfill.esm.js`）打补丁，并挂一个 `ResizeObserver` 在 polyfill 场景下重新定位（`popup.js:237-248`）——这是专门为不支持原生 `<dialog>` 的旧浏览器准备的兜底。
- 弹窗类型是枚举 `POPUP_TYPE`：`TEXT`/`CONFIRM`/`INPUT`/`DISPLAY`/`CROP`（`popup.js:9-20`），`callGenericPopup(content, type, inputValue, popupOptions)`（`popup.js:909-917`）是最常用的对外入口，内部就是 `new Popup(...).show()`。`Popup.show.input/confirm/text` 三个静态帮助方法（`popup.js:106-146`）是更语义化的封装。
- **Esc 关闭行为**：默认 `allowEscapeClose: true` 时，`dlg` 的 `cancel` 事件被拦截并调用 `this.complete(POPUP_RESULT.CANCELLED)`（`popup.js:604-607`）。如果显式设为 `false`（用于"阻塞性"弹窗，比如生成中不该被随手关掉的弹窗），第一次 Esc 会被吞掉且不关闭，但有个**双击 Esc 强制关闭**的设计：500ms 内连续按两次 Esc 会弹出一个二级确认弹窗"Force-close Blocking Popup"，用户确认后才真正强制关闭（`popup.js:556-607`，注释里作者自称"Don't ask me why this is needed. I don't get it. But we have to keep it."，说明这段逻辑本身是踩过坑后留下的防御代码，而不是清晰设计）。
- **遮罩关闭**：原生 `<dialog>` 的 `showModal()` 自带背景层（`::backdrop`），但代码里**没有找到点击遮罩关闭弹窗的逻辑**——`cancelListener` 只绑定在 `cancel` 事件（即 Esc 键或部分浏览器的手势），没有额外绑定 `click` 事件判断点击目标是否为 `this.dlg` 本身来实现"点遮罩关闭"。也就是说，**点击弹窗外部区域不会关闭弹窗**，这是一个和很多现代 Web 弹窗库不同的行为选择,已核实（通读全文件未发现相关代码，且历史交互经验一致）。
- **焦点管理**：`setAutoFocus()`（`popup.js:700-733`）打开时把默认按钮或输入框设 `autofocus` 属性（依赖浏览器对 `showModal()` 内 autofocus 的原生支持）；关闭时通过 `focusin` 事件持续记录 `lastFocus`（`popup.js:538`），弹窗栈里如果还有更底层的弹窗，会把焦点还给它记住的 `lastFocus` 或重新调 `setAutoFocus()`（`popup.js:836-844`）——这是一套简单但明确的焦点归还机制,支持多层弹窗堆叠(`Popup.util.popups` 数组维护堆叠顺序,`popup.js:860-862`）。
- **拖拽/缩放**：Popup 本身**不可拖拽或缩放**——没有找到给 `.popup` dialog 绑定 `dragElement()` 或类似逻辑的代码。真正可拖拽缩放的是另一套完全独立的机制：`script.js` 里的 `dragElement($elmnt)`（`script.js:477-约560+`，"Make the given element draggable. This is used for Moving UI"），用于"Moving UI"这个把面板变成可拖拽浮窗的功能（拖拽头部 `.drag-grabber`、缩放靠 `actionType === 'resize'` 分支，位置和尺寸持久化进 `power_user.movingUIState[elmntName]`，`script.js:490-503`）。这套机制用在头像放大浮层（`.zoomed_avatar`，`script.js:12196-12219`）等场景，与 `Popup` 弹窗系统是两套并行、不共享代码的"可移动 UI"实现。

- **Enter 提交**：弹窗内 `keydown` 监听 Enter 键（`popup.js:623-664`），但有一套细致的守卫逻辑：如果焦点不在当前最上层弹窗内、焦点元素不是 `.result-control`、或者焦点在多行文本框内且没按 Ctrl，都不会触发提交——这是为了避免"在多行输入框里按 Enter 想换行，结果把弹窗提交了"的误触。

### 13.2 Toastr 通知：全局单例配置 + 弹窗内特殊定位处理

`toastr.options` 在 `public/script.js:347-365` 全局配置一次：位置 `toast-top-center`，无关闭按钮，无进度条，显示/隐藏动画各 250ms，普通提示 4000ms 自动消失，"扩展超时"（`extendedTimeOut`，鼠标悬停后重新计时用的时长）10000ms，显示/隐藏效果是 `fadeIn`/`fadeOut`，`escapeHtml: true`（提示文本按纯文本转义，防止 toast 内容被当 HTML 解析,即防 XSS）。用户可在设置里改 `power_user.toastr_position`（`power-user.js:1078`：`toastr.options.positionClass = power_user.toastr_position`），说明弹出位置是可配置项，不是硬编码死的。

一个专门的细节：toastr 默认渲染在 `document.body` 下，但如果当前有弹窗打开，toast 会被挡在弹窗（`<dialog>`）下面——因为原生 `<dialog>` 的模态层级高于普通 body 内容。`fixToastrForDialogs()`（`popup.js:934-966`）专门处理这个问题：检测当前最上层的 `dialog[open]:not([closing])`，把 `#toast-container` 移进这个 dialog 内部；弹窗关闭时再挪回 `document.body`。这个函数在 toastr 的 `onHidden` 回调（`script.js:360-364`）和 `Popup.show()`/`#hide()`（`popup.js:683, 817`）里都会被调用，用于保证"弹窗开着的时候通知消息也要显示在弹窗上层，不能被弹窗盖住"。

toastr 调用点极其分散：全仓库 86 个文件、988 处 `toastr.success/error/warning/info(...)` 调用（已用 grep 统计确认,未逐一验证每个触发场景），几乎每个功能模块（角色导入、正则、Quick Reply、TTS、World Info、预设管理等）都直接调 toastr，没有一个统一的"通知服务"包装层——这与 `Popup` 弹窗那样至少有个类封装的做法不同，说明 toastr 更像是被当作一个可以随处调用的全局工具库，而不是被抽象过的应用内 API。

代码里有个特殊行为：`tags.js:1910` 给标签导入结果的提示设置 `timeOut: toastr.options.timeOut * 2`（显示两倍时长），说明"重要/信息量大的提示要停留更久"这种差异化处理是存在的，但只是零星的个例覆盖，不是系统化的分级机制（比如没有"error 比 info 停留更久"这种全局规则，`toastr.error/warning/info/success` 四种全部共享同一个 `timeOut`，除非调用点自己传参覆盖）。

### 13.3 加载/空状态：三层不同的"loading"实现，互不复用

调查发现 SillyTavern 里"加载中"这件事至少有**三套独立实现**，服务不同场景，彼此没有共用代码：

1. **首屏 HTML 预加载层**（`public/index.html:52` 的 `<div id="preloader">`，样式在 `public/css/loader.css:1-17`）：纯 HTML+CSS，页面 HTML 一解析就存在，用来盖住"JS 还没跑完、样式还没套上"的一段空白期,毛玻璃模糊背景 `backdrop-filter: blur(30px)`。这个元素在首次隐藏统一 loader 后被 `yoinkPreloader()`（`action-loader.js:609-613`）移除，且只移除一次（`preloaderYoinked` 标志位防重复）。
2. **统一 Action Loader 系统**（`public/scripts/action-loader.js`，全文 617 行已读）：这是本次调查中发现的一个此前笔记完全没提到的、设计相当完整的子系统。`ActionLoaderHandle` 类同时管理"阻塞遮罩"（复用 `Popup` 的 `POPUP_TYPE.DISPLAY` 类型渲染一个 `transparent+wide+large+allowEscapeClose:false` 的弹窗当遮罩层，`action-loader.js:530-548`）和"可堆叠 toast"（`#createToast`，`action-loader.js:170-205`）。关键设计点：
   - **遮罩单例，toast 可堆叠**：多个耗时操作同时进行时，只显示一个遮罩（`hasBlockingLoaders()` 判断，`action-loader.js:63-70, 150`），但每个操作有自己独立的 toast 提示（可以同时看到"Generating title..."和"Downloading..."两条 toast）。
   - **toast 三种模式**（`ActionLoaderToastMode`：`NONE`/`STATIC`/`STOPPABLE`，`action-loader.js:23-30`）：`STOPPABLE` 模式的 toast 上带一个停止按钮（`fa-stop-circle`），点击调用 `onStop` 回调或默认的 `stopGeneration()`（`action-loader.js:270-286`）——这意味着"生成中"这个最常见的 loading 状态，用户可以直接从 toast 上点停止，不需要找专门的停止按钮。
   - toast 本身用 `toastr.info(...)` 渲染但 `timeOut: 0, extendedTimeOut: 0, tapToDismiss: false`（`action-loader.js:199-204`）——即这类 loading toast 不会自动消失，也不能点击手动关闭，只能通过代码调用 `hide()`/`stop()` 结束，这与普通提示 toast（4 秒自动消失、可点击关闭）的行为完全不同,是同一个 toastr 库上叠的两种不同交互模式。
   - 消费点确认：聊天重命名（`script.js:10616-10621`）、首次加载初始化（`script.js:719`）、`script.js:11221` 等处都调用 `loader.show()`，说明这是当前版本里"正在处理"反馈的标准做法,而不是每个功能自己拼一个 spinner。
3. **CSS 驱动的空状态占位**（无 JS 参与）：World Info 条目列表为空时靠纯 CSS 伪元素显示提示——`#world_popup_entries_list:empty::before { content: 'No entries found.'; ... }`（`public/css/world-info.css:64-约70`），群聊"添加成员"列表为空时用 `content: attr(no_characters_text)` 读取 HTML 属性里预先写好的文案（`public/css/rm-groups.css:118-119`，对应 HTML `<div id="rm_group_add_members" ... no_characters_text="No characters available">`，`public/index.html:6342`）。这是一种"零 JS 空状态"设计：容器本身没有子节点时，`:empty` 选择器命中,`::before` 用 CSS `content: attr(...)` 直接从自定义 HTML 属性读文案渲染出来,连文本节点都不需要 JS 插入。**但这个模式没有覆盖到主角色列表**（`#rm_print_characters_block`）——搜索未发现类似的 `:empty::before` 规则用在主角色列表容器上，说明"聊天角色列表完全为空时"这个场景目前**没有专门的空状态提示**（未找到对应实现，属于确认性的"未做"而不是"没找到"）。

"生成中"三个点的动画（`@keyframes ellipsis`，`public/css/animations.css:85-101`，`content` 从空到 `"..."` 循环变化）已在 CSS 里定义，但只在 grep 全仓库后**没有找到直接把这个 keyframe 挂到聊天区"角色正在输入"提示上的代码**——它更像是一个通用工具动画（可能给某些扩展或旧版本用），当前主聊天流的"正在生成"反馈实际上是走 Action Loader 的 toast + `data-generating="true"` 这个 body 属性驱动的 CSS（`style.css:4569`：`body:is([data-generating="true"], [data-swiping="true"]) :is(...)`控制哪些元素在生成/swipe 期间要禁用交互），而不是消息气泡里的三点动画。这与直觉（很多聊天应用有"对方正在输入…"的跳动省略号）不同,值得记录。`document.body.dataset.generating`（`script.js:7020, 7029`）确认是全局单一状态位，不是逐条消息级别的。

### 13.4 右键/上下文菜单：只在角色卡网格和 Quick Reply 按钮上存在，消息本身没有

消息 hover 操作栏（复制/编辑/删除等，已在第 12 节记录）之外，SillyTavern **没有给聊天消息本身做专门的右键上下文菜单**——全仓库搜索 `contextmenu` 事件监听，聊天消息 `.mes` 相关代码里没有绑定。真正实现了自定义右键菜单的是两个不相关的地方：

- **角色卡网格的长按/右键菜单**（`public/scripts/BulkEditOverlay.js`，`handleHold`/`handleLongPressEnd`，`571-607`）：在角色列表卡片上，`mousedown`/`touchstart` 触发 `handleHold()`，用 `setTimeout(..., BulkEditOverlay.longPressDelay)`（`longPressDelay = 2500`，`BulkEditOverlay.js:389`，即**长按 2.5 秒**）判断是否为长按；如果当前是"浏览"状态就切到"多选"状态，如果已经在"多选"状态再长按就弹出 `CharacterContextMenu`（批量标签/删除等操作）。同时该网格的每个卡片元素也监听原生 `contextmenu` 事件（`handleDefaultContextMenu`，`onPageLoad` 里绑定，`BulkEditOverlay.js:499`），已核实其实现（`BulkEditOverlay.js:558-563`）：只有 `this.isLongPress` 为真时才 `preventDefault + stopPropagation` 拦截浏览器默认菜单,否则放行——即只有真正触发了长按流程才会吞掉右键菜单，普通右键点击（比如想用浏览器自带的"检查元素"）不受影响。这套机制同时兼容鼠标右键和触屏长按，是特意为触屏做的手势适配。
- **Quick Reply 按钮的右键菜单**（`public/scripts/extensions/quick-reply/src/QuickReply.js:116-123`）：每个 Quick Reply 按钮如果 `hasContext`（配置了右键上下文动作）为真，点击右键会 `preventDefault + stopPropagation` 并弹出自定义菜单,而不是走 slash command 默认执行。

### 13.5 主题系统：服务端 JSON 存储 + CSS 变量注入,支持导入/导出但对 `@import` 有安全提示

主题不是简单的"深色/浅色"二元切换，而是一整套可配置的 CSS 变量集合：

- `power_user.theme`（默认值 `'Default (Dark) 1.7.1'`，`power-user.js:177`）标识当前选中主题名；实际颜色值都是 `--SmartThemeXxxColor` 系列 CSS 变量（`power-user.js:159-168` 列出了 `main_text_color`/`italics_text_color`/`blur_tint_color`/`chat_tint_color` 等十来个变量，初始值直接从 `getComputedStyle(document.documentElement)` 读出当前 CSS 里的默认值）。
- `applyTheme(name)`（`power-user.js:1227-约1430+`）遍历一个 `themeProperties` 数组（`1234-约1260`），把主题对象里的每个字段映射到对应的颜色选择器 DOM 元素和 `applyThemeColor`/`applyBlurStrength`/`applyCustomCSS` 等应用函数——**每次切换主题本质是批量调用 `document.documentElement.style.setProperty('--SmartThemeXxx', 值)`**（参见 `applyThemeColor`，`power-user.js:1104-1143`），不是切换 CSS 文件或加 `<link>`,是纯 CSS 变量运行时改写。
- **自定义 CSS**：`power_user.custom_css` 字段（`power-user.js:170`，默认空字符串）由 `applyCustomCSS()`（`power-user.js:1147-1157`）注入到一个 `<style>` 元素的 `innerHTML`，即**用户可以为任意选择器写任意 CSS 规则并持久化保存**，这是比"主题预设"更底层的自由度（相当于允许用户注入任意样式,理论上也可用来做视觉上的越权改动,但只影响用户自己客户端渲染,不涉及权限判断）。
- **主题导入的安全提示**：`importTheme(file)`（`power-user.js:2443-2476`）解析上传的主题 JSON,如果 `custom_css` 字段里包含 `@import` 字符串,会先弹出一个专门的警告弹窗（`themeImportWarning` 模板）要求用户确认才继续导入（`power-user.js:2459-2465`）——这是因为 CSS `@import` 可以从外部 URL 拉资源,官方特意对这种"看起来像主题文件、实际可能引入外部请求"的情况做了提示,而不是静默允许。是我在读代码前没预料到的一个具体安全考量点。
- **存储位置**：主题不是存在浏览器 `localStorage`,而是通过 `/api/themes/save`、`/api/themes/delete`（`power-user.js:2499, 2404`）等接口存到服务端（`src/server-startup.js:121, 148` 挂载 `themesRouter`），和聊天记录一样是"服务端持久化，多设备共享"的模型，这与很多纯前端应用"主题只存 localStorage"的做法不同。
- **深色/浅色系统偏好**：全仓库搜索 `prefers-color-scheme`，在 `public/` 范围内**没有找到**（唯一命中是第三方库 `lib/pdf.min.mjs`，与 SillyTavern 自身 UI 无关）。也就是说，**SillyTavern 不会自动跟随操作系统的深色/浅色模式设置**，主题完全由用户在设置里手动选择，已核实（全文 grep 无匹配，非推断）。

### 13.6 无障碍现状：有一套自建的"键盘可达性"框架，但语义化 ARIA 几乎缺失

这是本次调查里发现的最值得记录的反差点：**SillyTavern 没有大规模使用原生语义化 HTML（`<button>`）或 ARIA 属性，但专门写了一套 JS 层的键盘可达性 polyfill 来补偿**。

- **`aria-*` 属性几乎不存在**：对 `public/index.html`（主界面 HTML，几千行）grep `aria-` 只有 **1 处**命中——一个装饰性图标上的 `aria-hidden="true"`（`index.html:5733`）。对全部 `public/scripts/*.js` 搜索,只有 3 个文件各出现 1 次 `aria-*`/`role=`（`PromptManager.js`、`world-info.js` 各 1 处 `role="..."`，且都是把业务数据值(prompt 的 role 字段)写进 HTML 属性,不是无障碍语义的 `role`），实质上**没有找到任何专门为屏幕阅读器设计的 `aria-label`/`aria-describedby`/`role="button"` 等标注**（已核实，非推断,是全文 grep 的确定性结果）。
- **绝大多数"按钮"其实是 `<div>`/`<i>` 图标元素**：`index.html` 里有 245 处 `.menu_button` 相关的 `<div>`（grep 统计），而不是原生 `<button>`。原生 `<button>` 自带键盘 Tab 可达、Enter/Space 触发、屏幕阅读器识别为"按钮"角色，`<div>` 都没有,必须靠手工补。
- **补偿机制**：`public/scripts/keyboard.js`（全文 254 行已读）实现了一个"interactable"注册系统——维护一个 CSS 选择器白名单（`interactableSelectors`，`keyboard.js:2-28`，涵盖 `.menu_button`、`.mes_buttons .mes_button`、`.swipe_left/.swipe_right`、角色卡片等近 30 类元素），用 `MutationObserver` 监听 DOM 变化（`keyboard.js:46-58`），给匹配到的元素动态加 `tabindex="0"`（`makeKeyboardInteractable`，`keyboard.js:121-159`），并在 `document` 级别监听 `keydown`,收到 Enter 键就沿 DOM 树向上找最近的 interactable 元素并 `.click()`（`handleGlobalKeyDown`，`keyboard.js:213-234`）。这套系统**解决了 Tab 键可达和 Enter 键触发的问题**，但没有解决"屏幕阅读器该怎么念这个按钮"的问题——因为没有配套的 `role="button"`/`aria-label`，屏幕阅读器遇到一个 `<div tabindex="0">` 通常只会读出里面的文字内容（如果有的话）或者完全跳过（如果是纯图标 `<i class="fa-solid fa-xxx">` 没有文字）。
- **`title` 属性大量存在但不能替代 ARIA**：`index.html` 里有 595 处 `title="..."`（这些同时是鼠标悬浮提示,通过 `data-i18n="[title]..."` 支持多语言），可以被部分屏幕阅读器读出，但 `title` 属性的无障碍支持并不稳定（依赖屏幕阅读器和浏览器组合,不是标准做法),不能等价于 `aria-label`。
- **`tabindex` 硬编码点极少**：静态搜索 `index.html` 里手写 `tabindex="..."` 的只有 3 处（`switch_input_type_icon` 按钮设 `tabindex="-1"`，即刻意排除出 Tab 顺序；`mes_impersonate` 图标设 `tabindex="0"`），绝大多数可交互元素的 `tabindex` 是靠上面的 `keyboard.js` 运行时动态加的，不是写在 HTML 里的静态属性。
- **结论**（已核实，非推断）：SillyTavern 的无障碍现状是"键盘可用性中等（有专门框架保障 Tab/Enter），屏幕阅读器语义几乎没有"。这是一个明确、具体的缺失，不是极端说法——本次没有做实际的屏幕阅读器（如 NVDA/VoiceOver）测试，上述结论完全基于静态代码扫描，实际使用体验可能因浏览器/读屏软件的兼容性处理而有所不同,如实标注为**未做运行时验证**。

### 13.7 响应式/移动端适配：两个断点 + iOS 专属分支，没有触摸版 swipe 手势

响应式布局集中在 `public/css/mobile-styles.css`（全文 656 行已读），是**媒体查询驱动的桌面/移动布局切换**,不是响应式框架（无 Bootstrap/Tailwind 断点系统）：

- **主断点：`max-width: 1000px`**（`mobile-styles.css:2-508`，注释写明"catches ipads, horizontal phones, and vertical phones"）：这个断点下做了大量结构性改变——各设置面板列（如 `#UI-Theme-Block`/`#ContextSettings` 等）从桌面端并排布局改为 `flex-basis: 100%` 单列纵向堆叠（`mobile-styles.css:4-11`）；`body { touch-action: none; overflow: hidden; position: fixed; }`（`mobile-styles.css:250-254`，禁用默认触摸手势如双指缩放整页、锁定 body 不滚动,把滚动交给内部容器管理）；抽屉面板（`.drawer-content`）在此断点下改为 `position: fixed` 铺满 `100dvw`（`mobile-styles.css:260-269`）而不是桌面端的浮动面板。
- **横屏子断点**：`@media screen and (max-width: 1000px) and (orientation: landscape)`（`mobile-styles.css:511-534`）单独处理横屏手机/平板的头像放大层定位和 waifu 模式表情图裁剪方式。
- **竖屏窄屏子断点**：`@media screen and (max-width: 450px)`（`mobile-styles.css:537-580`）进一步收窄抽屉宽度比例（`.drawer25pWidth`/`.drawer33pWidth` 从 1/4、1/3 收窄成 1/2）。
- **iOS 专属分支**：`@supports (-webkit-touch-callout: none)`（`mobile-styles.css:583-656`，这是检测"是否为 WebKit/iOS Safari"的常见 hack，因为该 CSS 属性只在 iOS Safari 有意义）单独处理 `env(safe-area-inset-*)`（刘海屏安全区）留白，以及 PWA 模式下（`body.PWA`）的底部安全区内边距（`mobile-styles.css:610-615`）。这说明 SillyTavern 官方是把"作为 PWA 装到 iOS 主屏幕"当作一个被认真对待的使用场景来适配的，不只是"响应式网页"。
- **触摸手势方面的结论（已核实，是缺失而非猜测）**：全仓库搜索 swipe 相关代码 + `touchstart`/`touchmove`/`touchend` 事件绑定，**没有找到"在消息上左右滑动手指触发 swipe 切换候选回复"的触摸手势实现**。当前 swipe 功能在移动端的操作方式，是点击消息下方的 `<` `>` 箭头按钮（`.swipe_left`/`.swipe_right`，见第 12 节），这两个按钮本身在触屏上当然可以点击，但**"swipe"这个功能名字所暗示的手指滑动手势，实际并未实现**，无论桌面还是移动端都是点按钮。真正用到 `touchstart`/`touchmove`/`touchend` 的触摸交互场景只有三处：①滑动条（`<input type="range">`）触摸时锁定页面滚动 300ms（`script.js:11696-11711`，防止拖动滑块时手指误触发页面滚动）；②角色卡网格长按手势（见 13.4）；③头像放大层的关闭点击兼容 `touchend`（`script.js:12225`）。
- **`getSortableDelay()`**（`public/scripts/utils.js:358-364`）是一个直接体现"为触屏专门调参"的函数：桌面端拖拽排序（World Info 条目、Quick Reply 按钮等,`.sortable({ delay: getSortableDelay() })` 用法遍布 `world-info.js`、`tags.js`、`openai.js`、`textgen-settings.js` 等十余个文件）的触发延迟是 50ms，移动端（`isMobile()` 为真）则是 750ms——注释明确写"这是为了防止滚动页面时误触发拖拽"，这是一个具体的、体现了对触屏交互差异有认真考虑的实现细节。

### 13.8 动画/过渡效果参数补充

`public/css/animations.css`（全文 154 行已读）定义了一批可复用的 `@keyframes`：`fade-in`/`fade-out`（纯透明度）、`pop-in`/`pop-out`（透明度+垂直缩放，`pop-in` 在 0%-33% 就把 `scaleY` 拉到 1、后 67% 只调透明度，让"弹出感"更快出现,不是线性）、`flash`（0%/50%/100% 全透明度、25%/75% 降到 0.2，用于高亮闹一下的强调效果）、`pulse`（配合 `filter: brightness` 做发亮的呼吸效果）、`ellipsis`（三点省略号内容变化，见 13.3,当前未找到消费点）、`infinite-spinning`（匀速 360° 旋转，用在 `.PastChat_cross:hover` 让删除聊天的叉号 hover 时旋转,`style.css:4872-4875`，纯粹是装饰性 hover 反馈，与"加载"无关）、`slide`（依赖 CSS 变量 `--slide-mes-x-start/end` 做消息横向滑动，用于消息删除动画的位移方向可由 JS 动态指定起止点）。

全局动画时长由 `ANIMATION_DURATION_DEFAULT = 125`（毫秒，`script.js:595`）驱动的 `--animation-duration` CSS 变量控制（`setAnimationDuration()`，`script.js:824-828`），用户可在设置里改这个值（变量名指向 `power_user` 相关设置，本次未深入具体设置项 UI 绑定,但确认了运行时改变机制存在）；抽屉展开/收起在"已有其它抽屉打开"时会先等待 `animation_duration` 毫秒再切换当前抽屉状态（`doNavbarIconClick()`，`script.js:10908-10910`），避免多个面板同时做开合动画造成视觉混乱。这与第 12 节已经记录的 `stream-fadein.js`（流式消息淡入,用 `morphdom` + `Intl.Segmenter`）是两个不同层面的动画机制：一个管"面板级"的开合过渡，一个管"文本级"的逐词淡入。

### 13.9 图片/附件预览：弹窗承载的简易灯箱，支持点击放大但无手势缩放

消息里的图片/视频附件点击后的"放大查看"实现是 `expandMedia`（对应函数体在 `chats.js:880-970`，已读全文）,复用的是 13.1 提到的同一套 `Popup` 弹窗系统,不是独立的灯箱库：

- 弹窗类型是 `POPUP_TYPE.DISPLAY`（只有关闭 X,没有 OK/Cancel 按钮），额外传 `{ large: true, transparent: true }`（`chats.js:960`）,让弹窗铺大、背景透明,只剩内容本身。
- **点击放大/还原**是纯 class toggle，不是真正的图像缩放引擎：点击图片本体切换 `.zoomed` class（`chats.js:941-945`），CSS 侧 `.img_enlarged`（未 zoomed）用 `object-fit: contain`+`cursor: zoom-in`，`.img_enlarged.zoomed` 切到 `object-fit: cover` 并允许滚动查看（`style.css:5305-5319`，`.img_enlarged_holder:has(.zoomed) { overflow: auto; }`）——即"放大"实际上是从"缩小以适应容器"切换到"按原始比例填充,可能超出容器需要滚动查看",而不是插值放大或支持拖拽平移/滚轮缩放的真正图像浏览器手势。
- 视频走同样弹窗但换成 `<video controls autoplay>`（`chats.js:913-919`），音频类型媒体**明确不支持展开**（`chats.js:896-898`：`if (mediaAttachment.type === MEDIA_TYPE.AUDIO) { console.warn('Audio media cannot be expanded'); return; }`）。
- 点击弹窗本身背景关闭（`popup.dlg.addEventListener('click', () => popup.completeCancelled())`，`chats.js:964-966`）——注意这与 13.1 提到的"Popup 系统本身不支持点遮罩关闭"并不矛盾：这里是 `expandMedia` 自己在弹窗内容层手动加了一个点击关闭的监听，是调用方主动加的行为，不是 `Popup` 类内建能力。
- 有标题的媒体会用 `<pre><code>` 渲染附加说明文字（`chats.js:947-957`），且这段代码专门 `stopPropagation` 阻止点击标题时触发放大/还原的 toggle 或误关闭弹窗。
- **另一套独立的图片查看器**：桌面端角色卡/用户头像放大用的是 `jquery.izoomify`（`public/lib/jquery.izoomify.js`，`script.js:12221-12223` 调用 `$('.zoomed_avatar_container').izoomify()`），这是鼠标悬停放大镜式的局部放大（跟随鼠标位置放大局部区域），仅在 `power_user.zoomed_avatar_magnification` 开启时生效，且这套放大镜效果依赖 `mouseover`/`mousemove`（`jquery.izoomify.js:144-147`）——**在纯触屏设备上，悬停放大镜这个交互模式基本不可用**（该库虽然也监听了 `touchstart`/`touchmove`，但放大镜跟随鼠标位置的交互模式在触屏上体验和桌面端会有本质差异，本次未做触屏实机验证，标注为**未核实的实际触屏体验**）。这是与聊天消息内嵌图片预览（`img_enlarged`）完全不同的第三套图像交互实现，三者（消息图片弹窗、头像放大 izoomify、头像拖拽浮层 `dragElement`）分别服务不同场景,没有整合成统一的"图片查看器"组件。

### 13.10 拖放细节：两类拖拽，机制不同

拖放交互在这次调查里发现分为两类完全不同的实现，此前笔记未涉及：

**A. 文件拖入导入（`DragAndDropHandler` 类，`public/scripts/dragdrop.js`，全文 107 行已读）**——一个通用的、可复用的拖拽区域封装：构造时传入 CSS 选择器和回调，内部用 jQuery 事件委托在 `document.body` 上监听 `dragover`/`dragleave`/`drop`（而不是直接绑定到目标元素本身,这样即使目标元素后续被重新渲染替换也不会丢失监听,`dragdrop.js:52-65`）；`dragleave` 用 `debounce_timeout.quick` 做了去抖（`dragdrop.js:87-91`，注释明确写"防止拖拽略过内部子元素边界时闪烁"）。全仓库有 4 个消费点：
  - 角色卡拖入导入：`charDragDropHandler = new DragAndDropHandler('body', ...)`（`script.js:12494-12499`，`{ noAnimation: true }`），拖放整个页面任意位置都能触发，内部区分"是文件"走 `processDroppedFiles()`（`script.js:10401-10434`，按 MIME/扩展名白名单——`application/json`、`image/png`（角色卡通常是打了 PNG tEXt 元数据的头像图）、YAML、`.charx`、`.byaf` 允许，其它类型 `toastr.warning` 拒绝）还是"是外部 URL"（拖动浏览器地址栏文字或图片链接时走 `importFromURL`，处理 `dataTransfer.items`）。
  - 聊天记录导入：`chatDragDropHandler = new DragAndDropHandler('#select_chat_popup', ...)`（`script.js:12501-12507`），把拖入的文件塞进隐藏的 `<input type="file">` 再触发 `change` 事件复用已有的文件选择逻辑，而不是另写一套处理逻辑。
  - 附件拖入弹窗：`chats.js:1510`（在 Data Bank / Attachment Manager 弹窗内,`.popup` 选择器,拖入后弹出目标选择器让用户选这个文件挂到全局/角色/聊天哪个作用域）。
  - 消息输入框拖入：`chats.js:2392-2394`（`#form_sheld` 选择器，拖文件到发送框直接走 `handleFileAttach`，等同于用文件选择器上传附件）。
  - 拖拽悬停视觉反馈统一由 CSS class `drop_target`/`dragover` 驱动（`dragdrop.js:75, 90, 102`），意味着所有这些拖放目标共享同一套视觉语言（具体动画效果由各自 CSS 定义，本次未逐一比对每个 `drop_target` 的 CSS 细节）。

**B. World Info / Quick Reply 等列表的拖拽排序（jQuery UI `.sortable()`）**——与上面文件拖入完全是另一套机制,用的是 `public/lib/jquery-ui.min.js` 的 `sortable` 插件（不是 SortableJS，也不是自己撕写的实现）。World Info 条目排序（`world-info.js:2576-2580`）：`items: '.world_entry', delay: getSortableDelay(), handle: '.drag-handle'`——`handle` 限定只有拖着专门的把手图标（`.drag-handle`）才能拖动整行，防止用户想选中文字/点开输入框结果不小心拖走了整个条目。同样的 `.sortable({ delay: getSortableDelay(), handle: ... })` 模式在 Quick Reply 按钮排序（`QuickReply.js:1007`、`QuickReplyConfig.js:70`）、正则规则排序（`regex/index.js:1177-1932`,多个作用域列表：全局/局部/预设级正则规则各自可独立排序）、采样器参数排序（`textgen-settings.js`/`nai-settings.js`/`kai-settings.js`/`openai.js`/`logit-bias.js`/`tags.js` 等十余处）里反复出现——这是一个统一透过 `getSortableDelay()` 共享"移动端延迟更长"这一参数的模式,但排序功能本身分散在各个模块各自初始化,没有一个集中的"可排序列表"组件封装（每处都是独立调用 `.sortable({...})`,配置参数相似但代码不共享）。

### 13.11 扩展面板（Extensions panel）结构与交互

Extensions 抽屉本身（`#rm_extensions_block`，`index.html:5741`）结构是**一串固定 ID 的空容器 `<div>`**（`#extensions_settings` 下挂 `#assets_container`/`#typing_indicator_container`/`#expressions_container`/`#sd_container`/`#tts_container` 等二十多个,`index.html:5760-5780+`），每个容器对应一个具体的内置扩展模块，模块自己的 `index.js` 在初始化时把自己的设置 UI（通常是 `renderExtensionTemplateAsync` 渲染的模板）塞进对应容器——**面板本身不是动态生成扩展列表，是预先在 HTML 里开好每个已知内置扩展的"坑位"**，第三方扩展则走另一条路径（见下）。

第三方/外部扩展的管理入口不在这个抽屉里，而是点击输入框旁的"魔法棒"图标（Wand，`addExtensionsButtonAndMenu()`，`extensions.js:688-723`）弹出一个用 `Popper.js` 定位的下拉菜单（`#extensionsMenu`，`placement: 'top-start'`，`extensions.js:699-701`），点击外部区域（且不在白名单 `#sd_gen`/`#extensionsMenuButton`/`#roll_dice` 内）会自动收起（`extensions.js:714-722`）。这个菜单聚合了各扩展贡献的快捷操作项（比如 Stable Diffusion 的生成按钮、掷骰子命令等），跟"扩展设置面板"（在抽屉里配置扩展参数）是两个不同的 UI 概念：**魔法棒菜单是"扩展提供的快捷动作入口"，Extensions 抽屉是"扩展的详细设置面板"**。

扩展的启用/禁用交互：`.extension_block` 上有 `.extension_toggle` 内的 `<input>`（复选框，`extensions.js:928, 1225, 1243`），勾选/取消勾选触发 `enableExtension(name)`/`disableExtension(name)`（`extensions.js:473-500`）。关键细节：**启用或禁用扩展默认会导致整页刷新**（`location.reload()`，`extensions.js:479, 496`）——两个函数都接受 `reload` 参数为 `false` 来跳过刷新（这种用法出现在"批量切换扩展"场景,`extensions.js:1218-1243` 的 `toggleAllExtensionsButton` 点击处理里,累积多个切换后统一走 `requiresReload = true` 标记,等用户主动确认后才刷新一次,而不是切一个刷一次）。这说明单个切换和批量切换在交互上是刻意区分的：零散地在设置里点开关一个扩展会立刻整页刷新生效；管理员批量启停第三方扩展列表时,系统会推迟刷新,给用户攒够操作后一次性生效的机会。

第三方扩展列表弹窗（`extensions.js:1150-1183` 一带涉及的更大的"Manage Extensions"弹窗，不同于魔法棒下拉菜单）区分"默认容器"和"外部容器"两组展示，第三方扩展列表加载时会先显示一个 `fa-spin` 转圈图标+"Loading third-party extensions... Please wait..."提示（`extensions.js:1156-1164`），并提供"Update all"/"Update enabled"两个批量更新按钮（各自调 `autoUpdateExtensions(force)`，`extensions.js:1186-1203`）和一个"Toggle extensions"批量切换按钮（`extensions.js:1205-1219`，配一个仅在有历史批量操作记录时才显示的"Restore toggled extensions"还原按钮，`extensions.js:1214-1216`，`displayNone` 默认隐藏）。列表排序支持按名称或按 manifest 声明顺序切换（`sortByName`/`sortManifestsByOrder`，`extensions.js:1166-1169`，排序偏好存在 `accountStorage`，即浏览器本地存储,不是服务端设置）。

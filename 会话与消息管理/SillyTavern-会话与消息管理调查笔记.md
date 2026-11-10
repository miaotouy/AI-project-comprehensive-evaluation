# SillyTavern 会话与消息管理调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`06bde939fb1e9c4c8d8641d810f0a916b5bce127`（分支：`release`）
>
> 调查方式：直接阅读源码（前端 JS 脚本、服务端端点 `src/endpoints/chats.js`/`groups.js`/`characters.js`、IndexedDB/localStorage 客户端存储），针对全部必查问题逐一核对当前 HEAD 的可执行路径
>
> 调查范围：聊天/群聊/checkpoint/branch/swipe 的数据模型与 JSONL 持久化、加载与保存链、消息操作数据语义、聊天列表与搜索、一致性机制、导入导出与格式转换、附件与外部对象绑定；请求执行与界面工作流分别进入对话请求与上下文、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的"聊天"是**内存可变数组 + 定期整份序列化到 JSONL 文件**的模型，不是增量事件日志或数据库表：

- 运行时的事实源是内存中的消息数组与聊天元数据对象，渲染、生成与保存逻辑都直接读写它们；消息没有持久化的全局 ID，界面上的消息序号只是数组下标，对应的 DOM 属性由视图刷新函数维护（`public/script.js:410,453,9407`）。
- 单人聊天与群聊存放在两个位置，JSONL 文件格式一致：首行是头对象，含 `chat_metadata` 与固定的占位用户、角色名，之后每行一条消息。加载时整份读入内存并渲染到界面，没有分页读取或流式解析；单聊入口是 `getChat`（`public/script.js:7575-7623`），群聊入口是 `getGroupChat`（`public/scripts/group-chats.js:255-320`）。
- 服务端保存前做完整性检查，由配置项 `backups.chat.checkIntegrity` 控制，默认开启（`src/endpoints/chats.js:29`）。标识不一致时服务端抛出 `IntegrityMismatchError` 并返回 integrity 错误，前端弹窗要求手输 `OVERWRITE` 才强制覆盖，否则整页刷新（`public/script.js:7400-7416`）。
- **checkpoint 与 branch 共用"截断另存为新文件"逻辑**（`public/scripts/bookmarks.js`），区别：checkpoint 不跳转、`extra.bookmark_link` 单值且新建覆盖；branch 必定跳转、`extra.branches` 数组追加、支持连同指定 swipe 版本截断。
- swipe 是消息级的候选版本机制：当前正文、当前候选下标、候选文本数组与候选附加信息四个字段并行保存，老文件由 `ensureSwipes` 惰性补齐（`public/script.js:6778-6828`）。
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

| 字段 | 含义 |
|---|---|
| `name`、`is_user`、`is_system`、`send_date` | 角色名、user/assistant 角色、是否系统消息（隐藏消息即 `is_system=true`）、时间戳 |
| `mes`、`title` | 正文、工具提示 |
| `gen_started`、`gen_finished` | 生成起止时间 |
| `extra` | 自由形态对象，按用途分组，见下表 |

`extra` 的用途分组：

| 用途 | 字段 |
|---|---|
| 生成来源快照 | `api`、`model` |
| 内容扩展 | `reasoning`（思考链）、`token_count`、`bias` |
| 附件与工具 | `media`、`files`（附件）、`tool_invocations`（工具调用） |
| 群聊与系统消息 | `gen_id`（群聊生成批次）、`isSmallSys`（小型系统消息）、`type`（narrator 等系统消息类型） |
| swipe 行为覆盖 | `overswipe_behavior`、`swipeable` |

swipe 相关的四个字段：

| 字段 | 含义 |
|---|---|
| `mes` | 当前显示正文，是 `swipes[swipe_id]` 的镜像 |
| `swipe_id` | 当前候选下标 |
| `swipes` | 字符串数组，保存候选版本 |
| `swipe_info` | 与 `swipes` 等长的数组，每项含 `send_date`、`gen_started`、`gen_finished`、`extra` |

`ensureSwipes(message)`（`public/script.js:6778-6828`）负责老文件字段的惰性补齐：

- 消息缺失字段时用当前 `mes` 现造长度为 1 的数组；
- `swipes[i]` 类型不对时强制纠正为空串；
- 用户消息与 `extra.isSmallSys` 消息显式排除在 swipe 体系外（6787-6789）。

### 1.3 Swipe 同步方向

两个方向职责严格分离：

- 一个方向是把消息正文写回候选版本：`syncMesToSwipe` 把当前正文、时间戳与附加信息写入当前候选槽位（`public/script.js:6837-6883`）。写回只在会话被标记或消息不止一条时发生，注释说明这是为了让"纯净首条问候语"在每次进入聊天时仍能重新解析宏，第 0 条消息在全新状态下故意不落盘。
- 另一个方向是 `syncSwipeToMes`（`public/script.js:6895-6959`）：读出指定候选的正文、时间戳与附加信息，覆盖当前消息。它接受一个可选的目标消息对象，可以改写游离副本而不触碰真实数组，branch 快照挑选 swipe 时复用的正是这条路径。

`deleteSwipe(swipeId, messageId)`（`public/script.js:9279-9345`）：至少保留 1 个 swipe；删除后按"删的是否当前选中项"重算 `swipe_id`；删除后置 `chat_metadata.tainted = true`（9323）。

## 2. 事实源、索引与持久化

### 2.1 三种存储的权威关系

- **JSONL 文件（服务端）**：持久化权威。服务端只做整文件读写（`getChatData` 逐行 parse，`src/endpoints/chats.js:502-515`）与首行 integrity 比对，不解析消息结构。
- **内存 `chat[]`**：运行时事实源。服务端文件在加载时整份灌入（`chat.splice(0, chat.length, ...data)`，`public/script.js:7599`），此后所有修改直接作用于数组。
- **IndexedDB（localforage 实例 `SillyTavern_Prompts`）**：存 itemized prompt（每条消息的 raw prompt 与 token 分项）与 token 计数缓存，key 为聊天名（`public/scripts/itemized-prompts.js:15, 46-57`；`saveTokenCache` `public/scripts/tokenizers.js:181`）。聊天删除时同步清除（`itemized-prompts.js:352-357`）。这是可重建的派生数据，不是消息事实源。

### 2.2 加载与保存链

- 保存：`saveChatConditional()` 用 `isChatSaving` 互斥等待上一次保存结束，再按群聊/单聊分发到两个保存函数，结束后写 IndexedDB 缓存（`saveGroupChat`、`saveChat`，`public/script.js:9352-9379`）。
- 防抖：`saveChatDebounced()` 以 1000ms 防抖调用保存，并在超时回调里校验 `this_chid`/`selected_group` 未变，防止切换后误写旧聊天（7302-7323）。
- 服务端 `trySaveChat()`（`src/endpoints/chats.js:457-468`）分四步：
  1. 序列化整数组；
  2. `checkChatIntegrity`（337-365，读文件首行比对 slug，文件不存在、空文件或无 integrity 字段视为通过；非空但首行无法解析为头对象则不通过）；
  3. 原子写文件（`write-file-atomic`）；
  4. 节流备份（`backupChat`，按"用户 + 聊天名"分别节流 10s；非 ASCII 聊天名会附加原始名的短哈希，避免 CJK 名折叠成同一备份键共享配额，`_` 前缀 + 时间戳，受 `backups.chat.*` 配置控制，`src/endpoints/chats.js:42-61,93-101`）。
- 加载：`/api/chats/get` 与 `/group/get` 分别返回单聊与群聊的整文件数组（服务端 517-544、797-806）。
- 首次落盘：前端 `getChatResult()` 在会话为空（`chat.length === 0`）时调 `getFirstMessage()` 造问候语并 `saveChatConditional()` 让文件首次落盘，随后发 `CHAT_CHANGED`，全新聊天再发 `CHAT_CREATED`（7625-7649、7641-7642）。
- 群聊加载（`getGroupChat`，`group-chats.js:255-320`）：先 `validateGroup`（剔除不存在的成员、去重 chat id，218-247），`freshChat = !metadata.tainted && 无数据` 时遍历 `group.members` 为每个成员各造一条首条消息并立即 `saveGroupChat`（283-304）。

### 2.3 无索引结构

聊天消息没有任何索引表：checkpoint 定位靠 `Object.entries(chat)` 全数组扫描（`/checkpoint-list`，`bookmarks.js:654-658`）；消息 ID 靠数组下标连续反推 DOM 顺序（渲染侧假设，见消息渲染器笔记）。token/上下文统计的"索引"即 IndexedDB 中的 itemized prompts，也是按消息下标关联的派生缓存。

## 3. 创建、切换、归档、删除与恢复

- **新建**：`doNewChat` 先弹出确认框，可选同时删除当前聊天，再按会话类型分两路（`public/script.js:10558-10587,11554-11561`）。单聊把当前角色的聊天指针改成新文件名，交给 `getChat()` 走首次落盘；群聊由 `createNewGroupChat` 把新聊天加入群组的聊天列表并落盘群组 JSON（`public/scripts/group-chats.js:2139-2154`）。
- **惰性创建**：进入新角色的聊天时，空文件分支由 `getChatResult()` 现造问候语（见 2.2）；单聊与群聊的打开入口都先清空内存和界面再加载（`public/script.js:7685-7693`、`public/scripts/group-chats.js:2194-2209`）。
- **切换**：角色与群聊各有入口。角色列表点击走 `selectCharacterById`，保存中或生成中会拒绝切换（`public/script.js:873-907`）；群聊切换走 `openGroupById` 与 `select_group_chats`（`public/scripts/group-chats.js:1802,2017`）。切换本身不触发保存，数据由切换前的各次保存调用落盘。
- **重命名**：服务端用"复制成新文件再删旧文件"实现（`src/endpoints/chats.js:546-577`）；前端改名后同步更新群组的聊天列表或角色的聊天指针，并刷新置顶条目（`public/script.js:10598`、`public/scripts/welcome-screen.js:947`）。
- **删除**：单聊与群聊分别处理。单聊入口 `delChat` 调用删除接口（`public/script.js:1336`、`src/endpoints/chats.js:579-602`）；群聊由 `deleteGroupChatByName` 删文件并从群组的聊天列表移除，若删的是当前聊天就切到列表最后一个，列表为空则按时间戳造一个新名字（`public/scripts/group-chats.js:2241-2268`）。删除后派发对应的删除事件，IndexedDB 中的 itemized prompt 缓存一并清除（`public/scripts/itemized-prompts.js:352-357`）。
- **归档**：本次未找到聊天文件层面的归档对象。欢迎屏的置顶只是最近聊天列表的排序偏好，由 `PinnedChatsManager` 存在 accountStorage 里，不写进消息文件（`public/scripts/welcome-screen.js:83-202`）。
- **恢复**：聊天文件损坏时服务端只丢弃解析失败的行，空文件按新聊天处理；崩溃恢复没有专门机制（见未验证事项）。"无角色临时聊天"在切换时用 sessionStorage 保存与恢复，只跨导航，不跨会话（`public/scripts/chats.js:1857-1879`，调用点 `public/script.js:1684,1693`）。

## 4. 编辑、重试、续写、回退与分支语义

| 操作 | 数据语义 |
|---|---|
| 编辑消息 | 原地修改：`updateMessage` 写回 `mes.mes` 并同步 `mes.swipes[swipe_id]`（`public/script.js:8080-8124`），`messageEditDone` 后 `saveChatConditional`（8373）；不产生新版本 |
| 删除消息 | `deleteMessage` 从 `chat` splice + 同步 DOM + `deleteItemizedPromptForMessage` + `saveChatDebounced`（1614-1700）；默认连带删除紧邻其前、仅承载 `extra.tool_invocations` 的系统消息（`getMessageDeletionStartId` 向前回溯，`/cut`、`/del` 可用 `toolcalls` 参数关闭）；编辑态删除可选"只删当前 swipe" |
| 复制消息 | `mes_edit_copy` 用 `structuredClone` 复制消息插入编辑位之后（11895-11920），新建 `send_date`，保留 swipe 结构 |
| 重新生成 | 单聊 `Generate('regenerate')` 在 `Generate` 内 `removeLastMessage` 删掉旧回复再生成（4344-4353）；群聊 `regenerateGroup` 按 `extra.gen_id` 分组删尾部（见 6） |
| 续写 | `Generate('continue')` 不删消息，`saveReply` 的 append/appendFinal 分支在 `mes` 后追加（6638-6681），swipes 同步到当前候选 |
| 回退/分支/checkpoint | 见下节；"回退到旧消息"没有独立对象，只能通过 swipe 候选（消息内）或 checkpoint/branch（聊天文件）表达 |

### 4.1 Checkpoint（`createNewBookmark`，`bookmarks.js:253-298`）

`saveChat({chatName: name, withMetadata: newMetadata, mesId})` 内部用 `chat.slice(0, Number(mesId)+1)` 截断另存新文件（`public/script.js:7362-7366`），当前主聊天不受影响。其余语义分三点：

- **回链**：checkpoint 创建时在触发消息上写入回链字段，指向新文件，随后由一次条件保存把它写回主聊天（`public/scripts/bookmarks.js:290`）。
- **覆盖**：同一条消息重复创建 checkpoint 会直接覆盖旧回链，只留最后一次，没有历史列表可查；文件里的替换标记只影响弹窗文案。
- **父聊天记录**：新文件的头元数据里记录父聊天名；老文件缺少该字段时，由 `getMainChatName` 从 "xxx - Checkpoint #N" 形式的文件名推断并回填（`public/scripts/bookmarks.js:119-122`）。

### 4.2 Branch（`createBranch`/`branchChat`，`bookmarks.js:186-243, 449-469`）

快照函数 `getBranchChatSnapshot(mesId, {swipeId})`（171-183）`structuredClone(chat.slice(0, mesId+1))`，若指定 `swipeId` 则用 `syncSwipeToMes(null, swipeId, snapshot[mesId])` 把快照最后一条替换成该候选版本——操作游离对象，不碰真实 `chat[]`。与 checkpoint 的三点差异：

1. 支持连同具体 swipe 版本截断（swipeId 参数）；
2. 保存后向触发消息 `extra.branches` **数组**追加分支文件名（233-241），可一条消息开多个分支；
3. `branchChat` 保存成功后**必定跳转**（`openGroupChat`/`openCharacterChat`，462-466），与 checkpoint 不跳转形成对照。

新建分支与 checkpoint 都会在新文件的头元数据里生成新的 `integrity` slug（`public/scripts/bookmarks.js:201,284`），使子文件与父聊天有独立文件身份；这不提供子文件每次保存的版本递增或同文件并发冲突检测。

两者都没有把分支合并回主线的操作：要回到主聊天，只能用 `/checkpoint-exit` 命令按头元数据里的父聊天名手动切换文件，没有树状导航（`public/scripts/bookmarks.js:312-326`）。创建入口包括旗标、Swipe Picker 以及 `/branch-create`、`/checkpoint-create` 等 slash command，最终都汇到 `createBranch` 与 `createNewBookmark`。

## 5. 列表、分页、搜索与定位

- **最近聊天列表**：接口扫描角色聊天目录、群聊文件和根目录三处，按修改时间排序并让置顶项优先，再逐个文件读出文件大小、消息数、最后消息和预览（`src/endpoints/chats.js:393-505,979-1077`）。读取由 `getChatInfo` 用 readline 流式完成，只看首行元数据与最后一条消息，不整读文件；末行无法解析或缺字段时返回降级预览，消息数按已读条数估算、预览置空，该聊天仍保留在列表里，扫描中途文件被删除则跳过。欢迎屏消费这个列表，并用 `collapsedDisplayed` 控制初始折叠条数（`public/scripts/welcome-screen.js:763-817`）。
- **单个角色的聊天列表**：`/api/characters/chats`（`src/endpoints/characters.js:1497-1533`），`simple` 模式只回文件名数组。
- **搜索**：搜索接口只在单个角色的聊天目录或单个群组的聊天列表范围内按查询词过滤（`src/endpoints/chats.js:874-977`）。实现上由 `getChatInfo` 逐行把消息正文累积成一个缓冲，交给 `hasTextMatch` 判断，查询词全部出现在同一缓冲内才算命中；结果附带最后 400 字符的预览。本次未找到跨角色或全局的聊天内容搜索入口。
- **分页**：消息的读取与保存都不分页，界面上"首屏 100 条 + Show more"只是显示层截断，阈值由 `power_user.chat_truncation` 控制，默认 100（`public/scripts/power-user.js:133`）。渲染细节在消息渲染器笔记。
- **定位**：搜索命中后跳转目标聊天靠 `displayPastChats` 的 `highlightNames` 参数滚动定位（`public/script.js:8560-8564`）。

## 6. 缓存、一致性、多窗口与并发写入

- **防抖与串行**：保存入口用互斥标记串行化，上一次保存未结束就等待；防抖保存延迟 1000ms 执行，触发时校验当前角色与群组有没有变化；切换 swipe 之前会先取消已排队的防抖保存，避免过期写入覆盖候选下标（`public/script.js:7308-7317,9354-9363,9932-9933`）。
- **跨窗口/多端**：本次检查聊天保存与加载入口，未发现实时同步机制。服务端把文件头里的完整性标识与请求中的值比对，不匹配就进入手输 `OVERWRITE` 的覆盖流程，并拒绝非空但无法解析头对象的文件。标识缺失时生成一个，普通保存继续沿用，只有 branch/checkpoint 才另发新标识。两个标签页加载同一个正常文件会拿到相同标识，之后的正常保存不会因为内容变化而冲突；该标识承担文件身份与完整性检查，不提供逐次版本号，也不承担同文件并发写入的互斥。见 [服务端比对](../../SillyTavern/src/endpoints/chats.js#L337-L369)、[写入条件](../../SillyTavern/src/endpoints/chats.js#L532-L542)、[前端保存与覆盖入口](../../SillyTavern/public/script.js#L7395-L7475)。
- **加载期间的写保护**：打开角色聊天的入口要等到保存结束才清空当前会话，角色切换入口在保存中直接拒绝切换（`public/script.js:878-881,7686`）。
- **流式临时状态**：流式生成把文本逐 token 写进内存中的消息正文，只有流结束才触发保存；中途停止或出错时，半截消息不会落盘。页面卸载时只停止流式生成，不做保存（`public/script.js:3624,3756,12401-12407`）。
- **IndexedDB 一致性**：清空会话时先把 itemized prompt 存好再清缓存；删除消息时由缓存模块负责把后续条目的下标前移，调用点与消息删除保持一致（`public/script.js:1599-1600`、`public/scripts/itemized-prompts.js:389-398`）。

## 7. 格式转换、导入导出与保留策略

- **旧格式字段惰性补齐（客户端）**：读取和使用路径上有几处补齐逻辑，swipe 字段由 `ensureSwipes` 处理（见 1.2），消息附件由 `ensureMessageMediaIsArray` 处理，候选附加信息由 `syncSwipeToMes` 回填；这些补齐只改内存，文件要到下次保存才更新（`public/script.js:1991,6931-6939`）。
- **服务端格式升级**：启动时会执行群组元数据格式升级，把群组 JSON 中废弃的 `chat_metadata` 与 `past_metadata` 逐聊天转移到各自 JSONL 首行头对象，转换前备份到 `backups/_group_metadata_update/`（`src/endpoints/groups.js:34-90`，调用点 `server-main.js:302`）。
- **导入**：导入接口同时接受 JSONL 与 JSON。JSONL 分支会处理 Chub 格式的正文与候选版本扁平化；JSON 分支按结构识别 Ooba、Agnai、CAI Tools、Kobold Lite、RisuAI 五种格式；两部分最终都输出头对象加消息行的 JSONL（`src/endpoints/chats.js:110-308,696-795`）。
- **导出**：导出接口支持 JSONL 原样导出；文本模式跳过系统消息行，优先取展示文本，没有展示文本时用正文（`src/endpoints/chats.js:604-674`）。
- **单聊转群聊**：转换函数 `convertSoloToGroupChat` 执行一次性不可逆转换，确认文案写明 "This cannot be reverted"，转换时给非用户、非系统消息写入头像字段与群聊生成批次（`public/scripts/bookmarks.js:328-441`）。
- **备份**：每次保存都由 `backupChat` 按节流规则备份到用户目录下的 backups 目录，总数上限由 `maxTotalBackups` 控制，取负值表示不限制。恢复入口是聊天历史弹窗里的 Chat Backups 浏览器，它调用备份读取与删除接口（`src/endpoints/chats.js:41-61`、`public/scripts/chat-backups.js:326`）。

## 8. 外部对象绑定与附件

- **角色**：角色 JSON 持有当前聊天文件名与最后聊天时间两个字段，属于会话级绑定，保存的是文件引用；角色级附件另存在 `extension_settings.character_attachments[avatar]`（`src/endpoints/characters.js:375,423`，见下文）。
- **群组**：群组 JSON 同时持有成员头像列表、当前聊天 id 与全部历史聊天 id 列表，读写都在群聊加载路径上（`public/scripts/group-chats.js:255-320`）。
- **消息级绑定**：转群聊或群聊生成时，消息会被写入头像字段与群聊生成批次号（`public/script.js:6714-6716`）。
- **模型/渠道**：消息里保存的是生成当时的模型与接口字段快照，渠道引用不落盘，后续请求也不读取这些字段回放，它们只用于界面展示和 reasoning 签名校验（`public/script.js:6690-6691`、`public/scripts/openai.js:615-621`）。
- **消息附件**：图片与文件保存附件引用，组装请求时分路处理。文件附件由 `appendFileContent` 读取文本并前置到消息正文（`public/scripts/chats.js:508-527`）；图片走媒体附件路径，例如 OpenAI 请求在支持图片内联时调用媒体转换，将图片 URL 加入多模态消息（`public/scripts/openai.js:966-992`）。
- **Data Bank（知识库）**：附件管理器分全局、角色、聊天三个作用域，分别挂在扩展设置、角色附件表和聊天元数据上（`public/scripts/chats.js:77-81,1488-1804`）。
  - **注入路径已核实**：Data Bank 文件由 vectors 扩展的 `ingestDataBankAttachments` 摄取进向量索引，生成时按查询检索，注入为一个独立的扩展 prompt 块，同时记录进 itemized prompt（`extensions/vectors/index.js:53,582-586,644-669`；`public/script.js:5291`）。
  - 它与消息级文件附件是两套并行体系：消息附件随消息文本注入，Data Bank 附件经向量检索注入。

## 9. 设计取舍与已确认边界

- **整份读写、无分页、无索引**：文件一次性读入内存和界面，长聊天的读写与渲染成本随消息数线性增长；checkpoint 定位靠全数组扫描；消息 ID 就是数组下标，删除后要重新刷新全局消息编号才能保持 DOM 一致。
- **完整性标识与覆盖确认**：标识不一致或文件头损坏时，服务端要求显式确认覆盖；同一个标识下，旧窗口的保存仍可能盖掉新内容，本轮未实测多标签页竞争。
- **checkpoint 与 branch 的差异**：回链取单值覆盖还是数组追加，是有意的数据设计差异（4.1/4.2）。
- **群聊与单聊的"重新生成"是两套机制**：
  - 单聊把旧回复留在候选数组里，靠切换候选回看；
  - 群聊由 `regenerateGroup` 按群聊生成批次号分组，先物理删除尾部消息再重新生成，批次号取当时的时间戳（`public/scripts/group-chats.js:167-188`，批次号在 988 行生成）。
- **"纯净问候语"特例**：已修改标记在多处写入，控制首条问候语的宏重解析与 overswipe 循环行为（`public/script.js:1659,4288,5846,8131,9323,11669`）。
- **类目边界**：本笔记只回答数据语义；`Generate()` 的请求构建在对话请求与上下文；swipe、Swipe Picker 与 checkpoint 旗标的用户工作流在 Chat UI；DOM 渲染与流式更新在消息渲染器笔记。

## 10. 未验证事项

- 崩溃恢复（保存中断、文件损坏、浏览器强杀）行为未实测；静态代码显示流式中途的消息不落盘、`getChatData` 静默丢弃解析失败的行。
- 多标签页同时写入的竞争窗口未实测（integrity 检查与写入之间仍有 TOCTOU 窗口）。
- 大文件下 `/api/chats/search` 逐文件流式扫描的性能未实测。
- 导入格式转换（Ooba/Agnai/CAI/Kobold Lite/Risu/Chub）只核实了转换函数存在与调用入口，未逐格式用样本文件验证。

## 11. 关键源码索引

- `public/script.js`：
  - 会话状态与保存链：`chat`/`chat_metadata`（410, 453）；`saveChat`（7336-7421）、`saveChatDebounced`（7302-7323）、`saveChatConditional`（9352-9379）
  - 加载与打开：`getChat`/`getChatResult`/`getFirstMessage`/`openCharacterChat`（7575-7693）
  - swipe 与消息操作：`ensureSwipes`/`syncMesToSwipe`/`syncSwipeToMes`（6778-6959）；`saveReply`（6583-6771）、`deleteSwipe`（9279-9345）、`deleteMessage`（1614-1700）
  - 新建、重命名与编辑：`doNewChat`/`renameGroupOrCharacterChat`（10558-10679）；`updateMessage`（8080-8124）
- `public/scripts/bookmarks.js`：`getBranchChatSnapshot`/`createBranch`（171-243）；`createNewBookmark`/`backToMainChat`（253-326）；`branchChat`（449-469）；`convertSoloToGroupChat`（328-441）；slash commands 与 `initBookmarks`（471-737）
- `public/scripts/group-chats.js`：`getGroupChat`（255-320）；`saveGroupChat`（623-675）；`regenerateGroup`（167-188）；`generateGroupWrapper`（945-1092）；聊天 CRUD（2139-2268）
- `public/scripts/chats.js`：`hideChatMessageRange`（147-169）；附件上传/删除/媒体（198-1120）；Data Bank（1334-1804）
- `public/scripts/itemized-prompts.js`：IndexedDB 存储（15-57, 83-107）
- `src/endpoints/chats.js`：`trySaveChat`/`checkChatIntegrity`/`getChatData`/`getChatInfo`（316-515）；`/save` `/get` `/rename` `/delete` `/import` `/export`（470-795）；`/group/*`（797-872）；`/search` `/recent`（874-1077）
- `src/endpoints/groups.js`：群组 CRUD（113-203）；元数据格式升级（34-90）
- `src/endpoints/characters.js`：`/chats`（1497-1533）

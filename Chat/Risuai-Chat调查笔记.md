# Risuai Chat 概览调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`39f1ac1472d0ef6907ee933c4cf25182ee2aec9f`（分支：`main`）
>
> 调查方式：只读源码；通读 `src/ts/process/index.svelte.ts` 主链、存储与保存机制，grep 定位各专项入口后展开读取上下文，未运行应用
>
> 调查范围：Chat 概览：产品表面、核心对象与事实源、端到端主链、专项归属、关键能力边界；未展开请求协议细节、消息渲染器、角色卡格式与插件系统的完整实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 是 Svelte 5 + Tauri 2.5 的角色扮演聊天应用，聊天状态全部驻留前端内存：`DBState.db` 是唯一权威对象（`src/ts/stores.svelte.ts:105-107`），角色、会话、消息与全部设置都挂在同一个 `Database` 上，由常驻保存循环按角色分块增量编码到单一二进制存档 `database/database.bin`（`src/ts/globalApi.svelte.ts:292` 的 saveDb）。

聊天主链由单个巨型编排函数 `sendChat()` 承担（`src/ts/process/index.svelte.ts:99`）。界面层先把用户消息直接推入消息数组，该函数随后依次完成上下文拼装、记忆处理、请求组装、渠道调用与流式回写，全过程直接读写内存中的存档对象，并以 reloadKeys 计数变化驱动重渲染。渲染入口是 `Chats.svelte` 的哈希差量挂载与 `ChatBody.svelte` 的 Markdown 管线。

会话不是独立集合：会话数组与当前页索引挂在每个角色对象上；"分支"表达为整份会话副本（Copy/Branch 命名）而非消息树。重roll候选按 generationId 只存内存（`src/ts/process/prereroll.ts:1-29`），不随消息持久化，与 SillyTavern 的持久 swipe 字段形成对照。

## 产品表面与系统边界

- 产品表面：同一套前端代码以四种载体交付，包括桌面 GUI（Tauri 2.5）、Web 静态站（service worker + IndexedDB）、移动 Web 布局（`MobileGUI` 分支）与 Node 服务器内嵌模式。`src/App.svelte:196-237` 的条件渲染按状态在加载页、设置页、移动端与主界面之间切换，没有路由层。
- 数据拥有：全部数据由前端内存持有并写回本地。桌面端启动时由 loadData 读入 AppData 中的存档（`src/ts/bootstrap.ts:55`），Web 端经 `AutoStorage` 适配层落到 LocalForage、Node、OPFS 或账号存储（`src/ts/storage/autoStorage.ts:12`）。此外还有 remotes/ 下的角色级分块存档、coldstorage/ 冷存档以及最多 20 份滚动备份。
- 外部系统拥有：模型推理交给外部 Provider，涵盖 OpenAI、Anthropic、Gemini、Ollama、Ooba、AI Horde、Kobold、WebLLM 以及插件渠道，应用只负责拼装请求并消费流式返回；角色卡分享走 RisuHub，账号同步与 Drive 备份是可选的外部服务。
- 不拥有：无服务端会话状态；Node 服务器只提供托管与存储适配。

## 端到端聊天主链

```text
Composer（DefaultChatScreen.svelte:137-216）→ 直接 push 用户 Message 到 DBState.db…chats[chatPage].message
→ sendChat(-1,{signal})（process/index.svelte.ts:99）：doingChat 全局锁 → 群聊按活跃度顺序递归 sendChat(角色索引)
→ 阶段1 上下文：unformated 分桶 + promptTemplate 拼装 + 分块令牌计数（risuChatParser/processScriptFull/ChatTokenizer）
→ 阶段2 记忆：SupaMemory/HypaV2/V3/Hanurai 或按 maxContext 从头部截断
→ 阶段3 组装 formated[] + Lua editRequest 触发器 + 令牌复核 → requestChatData（request/request.ts:205）
→ requestChatDataMain 按 LLMFormat 分发渠道（request.ts:435-534）
→ 流式：读 ReadableStream，把 editoutput 脚本处理后的文本写回 message[msgIndex].data，reloadKeys 触发重渲染
→ 后处理：reroll 候选、output 触发器、表情/图片屏、自动续写、通知、多端同步
→ 持久化：saveDb() 的 $effect 跟踪 DBState 变更，500ms 防抖后增量编码写 database.bin
→ 渲染：Chats.svelte 哈希差量挂载 Chat → ChatBody ParseMarkdown → @html 输出
```

## 核心对象与状态权威

- 存档对象 `DBState.db`（类型 `Database`）是全部数据的事实源，角色、会话、消息、设置、提示词与渠道密钥都挂在这个对象上；上层经 getDatabase/setDatabase 与 getCurrentCharacter/getCurrentChat 两组包装读写它（`src/ts/storage/database.svelte.ts:802,732-780`）。
- 角色对象 `character` 持有角色卡数据、会话数组与当前会话索引 chatPage；群聊对象 groupChat 在此基础上用成员 ID 数组、characterTalks 与 characterActive 记录各成员的参与度（`src/ts/storage/database.svelte.ts:1343,1510`）。
- 会话对象 `Chat` 承载消息数组、会话级 note 与 localLore、记忆数据、流式标记、书签与问候语索引（`src/ts/storage/database.svelte.ts:1817`）；新建会话时 `ChatList.svelte:71-90` 直接向角色上的会话数组头部插入一条。
- 消息对象 `Message` 的 role 只取 user 与 char 两种值，正文写在 data 字段，saying 记录本条的说话角色 ID；disabled 控制该消息是否进入提示词，取值为 allBefore 时排除该消息及更早历史，保留之后的消息；chatId 与生成元数据随消息一同保存（`src/ts/storage/database.svelte.ts:1848`）。
- 生成元数据分两层：MessageGenerationInfo 记录所用模型、generationId、输入输出 token 与四阶段计时，MessagePresetInfo 记录本次请求的提示词名、开关与正文，供消息详情弹窗展示（`src/ts/storage/database.svelte.ts:1862,1876`）。
- 界面状态：选中角色 ID、渲染键与生成阶段都放在 Svelte store 里（`ReloadChatPointer`、`doingChat` 等），只服务于展示与流程控制，消息事实以存档对象为准。

## 专项导航

- 会话管理：会话挂在角色对象上，角色上的 chatPage 指向当前页；导航、新建与删除集中在 `ChatList.svelte`，切换会话与折叠跳转由 `globalApi.svelte.ts:2390-2429` 的 changeChatTo 与 foldChatToMessage 处理，旧会话的冷存档交给 process/coldstorage.svelte.ts 中的 makeColdData 与 preLoadChat。尚未拆分调查。
- 请求上下文：分桶、promptTemplate 拼接、lorebook 注入、记忆处理、token 预算与结果回写都由 `process/index.svelte.ts` 的 sendChat 承担；lorebook、记忆与脚本执行另有辅助模块（process/lorebook.svelte.ts、process/memory、process/scripts.ts）。尚未拆分调查。
- 聊天界面：`ChatScreen.svelte` 负责主题布局，按 classic、waifu 与 waifuMobile 三套外观切换；`DefaultChatScreen.svelte` 承载输入框、建议、重roll、自动模式与聊天菜单；消息列表的挂载点在 `Chats.svelte`。尚未拆分调查。
- 消息渲染：`Chat.svelte` 是消息壳与操作栏，渲染体 `ChatBody.svelte` 调用 `parser.svelte.ts:736` 的 ParseMarkdown，由后者完成变量替换、显示脚本、inlay 资产、语法高亮与 DOMPurify 净化；局部编辑由 PartialEditController.svelte 提供。尚未拆分调查。
- 角色：数据模型由 character 与 groupChat 两个对象定义，导入导出在 `characterCards.ts` 中处理 .risum、.risup 与 .charx 三种格式，日常增删改由 characters.ts 负责。尚未拆分调查。
- 渠道：`process/request/request.ts:435-534` 按模型格式把请求分发到 OpenAI、Anthropic、Google 等各家的实现文件，`model/modellist.ts` 提供模型信息与能力标志，其中包含插件自定义渠道。尚未拆分调查。
- 生成式输出：消息级的生成详情由 generationInfo 弹窗展示，入口是 alertRequestData；表情屏与图片屏由 viewScreen 的 emotion 与 imggen 两种模式驱动；另有 TTS、稳定扩散、inlay 屏幕与记忆摘要。尚未拆分调查。
- 本轮未建立任何 Risuai 专项笔记，以上职责均属"尚未拆分调查"，概览不展开其完整实现。

## 关键能力与已确认边界

- **全局生成锁**：一次生成进行中，`doingChat` 会把新的顶层发送挡在门外；群聊走递归调用绕开该锁，在同一轮内按活跃度顺序生成多个角色的回复（`src/ts/process/index.svelte.ts:212-218,295-336`）。未找到跨会话并行生成机制。
- **停止生成**：用户在界面上停止时，abortChat 触发 AbortController，流读取循环收到 abortSignal 后调用 reader.cancel() 协作退出（`src/ts/process/index.svelte.ts:1682-1686,1755-1757`）。
- **重roll**：候选回复按 generationId 只留在内存里，由 `prereroll.ts:1-29` 的 addRerolls 与 Prereroll 管理，切换角色时清空（DefaultChatScreen.svelte:149-152）；这些候选不随消息落盘，与 SillyTavern 把 swipe 字段写进消息的做法形成对照。
- **分支与复制**：复制产生整份会话副本，命名时缀上 (Copy)/(Branch)（`globalApi.svelte:2431` 的 createChatCopyName）；分支用一条 `{{specialcomment::branchedfrom::…}}` 注释消息标记，点击后跳到源会话并折叠到对应源消息，没有消息树导航。
- **消息隐藏与截断**：提示词组装会跳过 disabled 的消息，取值为 allBefore 时排除该消息及更早历史，保留之后的消息（`src/ts/process/index.svelte.ts:849-864`）；隐藏只影响组装结果，消息本身仍保留在会话里。
- **自动续写**：回复过短或没有以标点收尾时，应用会以 continue 模式再发一次请求，把续文拼接到上一条消息末尾（`src/ts/process/index.svelte.ts:1885-1904`）。
- **窗口化渲染**：消息列表按配置挂载最近一批消息，滚到顶部时再向前追加；初始数量默认 30 条、追加数量默认 15 条，两者均可配置（`src/ts/chatLoadPages.ts:1-23`）；消息 DOM 按哈希差量增删，没有做虚拟化（`Chats.svelte:65-167`）。
- **搜索**：本次未找到消息级搜索，只在角色列表（MobileSearch）与模型列表上见到过滤搜索。
- **冷存档**：启动时把久未使用的角色与聊天搬到 coldstorage/ 下的键，需要时由 preLoadChat 取回（`process/coldstorage.svelte.ts:575,627`），构成会话管理的归档边界。

## 未验证事项

- 未运行应用；滚动、流式显示、表情屏、快捷键等 UI 行为均为静态代码结论。
- `sync/multiuser.ts`（peerSync/peerSafeCheck）与账号同步、Drive 备份的机制与边界未展开。
- 插件 replacer 与 trigger 在请求链中的实际注册集合未枚举。
- 冷存档的迁移触发条件与恢复流程未运行验证。
- 长会话下哈希差量挂载与 `reloadKeys` 重渲染的性能未实测。

## 关键源码索引

- `src/ts/process/index.svelte.ts`：sendChat 全链（99）；群聊递归（295-336）；disabled 处理（849-864）；流式回写（1591-1753）；自动续写（1885-1904）
- `src/ts/process/request/request.ts`：requestChatData（205）；requestChatDataMain 渠道分发（435-534）
- `src/ts/storage/database.svelte.ts`：Database（802）；character（1343）；groupChat（1510）；Chat（1817）；Message（1848）；MessageGenerationInfo（1862）
- `src/ts/stores.svelte.ts`：DBState（105-107）；渲染与流程 store（18-67）
- `src/ts/globalApi.svelte.ts`：saveDb（292-486）；foldChatToMessage/changeChatTo/createChatCopyName（2390-2439）
- `src/ts/bootstrap.ts`：loadData（55）；checkNewFormat（335）
- `src/ts/storage/risuSave.ts`：encodeRisuSaveLegacy（52）；RisuSaveEncoder 分块编码（124）
- `src/lib/ChatScreens/`：DefaultChatScreen.svelte 发送与 Composer（137-335, 597-675）；Chats.svelte 差量挂载（65-167）；Chat.svelte 消息壳（180-206, 425-465）；ChatBody.svelte 渲染管线（66-170, 261-269）
- `src/ts/parser/parser.svelte.ts`：ParseMarkdown（736-777）；trimMarkdown（779）
- `src/lib/Others/ChatList.svelte`：会话导航与新建（28-103）
- `src/ts/process/prereroll.ts`：重roll内存候选（1-29）

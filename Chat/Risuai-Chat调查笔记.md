# Risuai Chat 概览调查笔记

> 调查对象：`E:\works\GitStudyNotes\Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：只读源码；通读 `src/ts/process/index.svelte.ts` 主链、存储与保存机制，grep 定位各专项入口后展开读取上下文，未运行应用
>
> 调查范围：Chat 概览：产品表面、核心对象与事实源、端到端主链、专项归属、关键能力边界；未展开请求协议细节、消息渲染器、角色卡格式与插件系统的完整实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 是 Svelte 5 + Tauri 2.5 的角色扮演聊天应用，聊天状态全部驻留前端内存：`DBState.db` 是唯一权威对象（`src/ts/stores.svelte.ts:105-107`），角色、会话、消息与全部设置都挂在同一个 `Database` 上，由常驻保存循环按角色分块增量编码到单一二进制存档 `database/database.bin`（`src/ts/globalApi.svelte.ts:292` 的 saveDb）。

主链集中在巨型编排函数 `sendChat()`（`src/ts/process/index.svelte.ts:99`）：UI 层直接向消息数组 push 用户消息，sendChat 依次完成上下文拼装、记忆、组装、渠道请求与流式回写，全程直接读写 `DBState.db`，用 `reloadKeys` 计数驱动渲染。渲染入口是 `Chats.svelte` 的哈希差量挂载与 `ChatBody.svelte` 的 Markdown 管线。

会话不是独立集合：会话数组与当前页索引挂在每个角色对象上；"分支"表达为整份会话副本（Copy/Branch 命名）而非消息树。重roll候选按 generationId 只存内存（`src/ts/process/prereroll.ts:1-29`），不随消息持久化，这是与 SillyTavern 持久 swipe 字段最明显的差异。

## 产品表面与系统边界

- 产品表面：桌面 GUI（Tauri 2.5）、Web 静态站（service worker + IndexedDB）、移动 Web 布局（`MobileGUI` 分支）与 Node 服务器内嵌模式四种载体；`src/App.svelte:196-237` 用条件渲染切换加载、设置、移动端与主界面，无路由。
- 数据拥有：全部数据由前端内存持有并写回本地。Tauri 将存档写到 AppData（`src/ts/bootstrap.ts:55` 的 loadData 启动读取），Web 走 `AutoStorage` 存储适配（LocalForage/Node/OPFS/账号，`src/ts/storage/autoStorage.ts:12`）；另有 `remotes/` 角色级分块存档、`coldstorage/` 冷存档与最多 20 份滚动备份。
- 外部系统拥有：模型推理由外部 Provider 承担（OpenAI、Anthropic、Gemini、Ollama、Ooba、AI Horde、Kobold、WebLLM 与插件渠道等），应用只拼装请求并消费流式返回；角色卡分享走 RisuHub，账号同步与 Drive 备份为可选外部服务。
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

- `DBState.db`（`Database`）是事实源：角色、会话、消息、设置、提示词与渠道密钥全部在内；`getDatabase/setDatabase`、`getCurrentCharacter/getCurrentChat` 是存取包装（`src/ts/storage/database.svelte.ts:802,732-780`）。
- `character`（database.svelte.ts:1343）：角色卡数据 + `chats: Chat[]` + 当前会话索引 `chatPage`；群聊 `groupChat`（:1510）用成员 ID 数组、`characterTalks` 与 `characterActive` 描述参与度。
- `Chat`（:1817）：消息数组、会话级 note 与 localLore、记忆数据、流式标记、书签与问候语索引；新建会话在 `ChatList.svelte:71-90` 直接向数组 unshift。
- `Message`（:1848）：`role` 只有 `'user'|'char'` 两种，正文在 `data`，`saying` 记录说话角色 ID；`disabled` 表达隐藏或 `'allBefore'` 截断；`chatId` 与生成元数据随消息保存。
- 生成元数据：`MessageGenerationInfo`（:1862）记录模型、generationId、输入/输出 token 与四阶段计时；`MessagePresetInfo`（:1876）记录本次请求的提示词名、开关与正文，供消息详情弹窗展示。
- 可见 UI 状态：`selectedCharID`、`ReloadGUIPointer`/`ReloadChatPointer`（渲染键）、`chatProcessStage`/`doingChat`（生成阶段）等 store 只是展示与流程状态，不是消息事实源。

## 专项导航

- 会话管理：会话对象是角色持有的 `Chat`（消息数组 + 会话级 note/localLore + 记忆数据 + 书签），当前页由角色上的 `chatPage` 索引；导航、新建与删除在 `ChatList.svelte`，切换与折叠跳转入口 `changeChatTo`/`foldChatToMessage` 位于 globalApi.svelte.ts:2390-2429，旧会话冷存档由 `process/coldstorage.svelte.ts`（makeColdData/preLoadChat）承担。尚未拆分调查。
- 请求上下文：`process/index.svelte.ts` 的 sendChat 单文件承担全部拼装（分桶、promptTemplate、lorebook、记忆、token 预算与回写），辅助模块为 `process/lorebook.svelte.ts`、`process/memory/*` 与 `process/scripts.ts`。尚未拆分调查。
- Chat UI：`ChatScreen.svelte` 负责主题布局（classic/waifu/waifuMobile），`DefaultChatScreen.svelte` 承载 Composer、建议、重roll、自动模式与聊天菜单，`Chats.svelte` 是消息列表挂载点。尚未拆分调查。
- 消息渲染：`Chat.svelte`（消息壳与操作）与 `ChatBody.svelte`（渲染体）调用 `parser.svelte.ts:736` 的 ParseMarkdown（变量、显示脚本、inlay 资产、高亮、DOMPurify）；`PartialEditController.svelte` 提供局部编辑。尚未拆分调查。
- 角色：数据模型见 `character`/`groupChat`，导入导出在 `characterCards.ts`（.risum/.risup/.charx），日常管理在 `characters.ts`。尚未拆分调查。
- 渠道：`process/request/request.ts:435-534` 按模型格式分发到 `request/openAI`、`anthropic.ts`、`google.ts`、`models/` 等实现；`model/modellist.ts` 提供模型信息与能力标志（含插件自定义渠道）。尚未拆分调查。
- 生成式输出：消息级 `generationInfo` 详情弹窗（`alertRequestData`）、表情屏与图片屏（viewScreen 的 emotion/imggen）、TTS、稳定扩散、inlay 屏幕与记忆摘要。尚未拆分调查。
- 本轮未建立任何 Risuai 专项笔记，以上职责均属"尚未拆分调查"，概览不展开其完整实现。

## 关键能力与已确认边界

- **全局生成锁**：生成期间 `doingChat` 阻止新的顶层发送；群聊递归调用绕过该锁，形成单轮内顺序多角色生成（index.svelte.ts:212-218, 295-336）。未找到跨会话并行生成机制。
- **停止生成**：UI 的 abortChat 触发 AbortController，`abortSignal` 使流循环调用 `reader.cancel()` 协作退出（index.svelte.ts:1682-1686, 1755-1757）。
- **重roll**：候选按 generationId 存于内存 `prereroll.ts:1-29`（addRerolls/Prereroll），切换角色时清空（DefaultChatScreen.svelte:149-152）；候选不随消息落盘，与 SillyTavern 的持久 swipe 字段形成对照。
- **分支/复制**：复制是整份会话副本并命名 (Copy)/(Branch)（`createChatCopyName`，globalApi.svelte:2431）；分支消息以 `{{specialcomment::branchedfrom::…}}` 注释消息表达，点击后跳转到源会话并用 `foldChatToMessage` 折叠到源消息，没有消息树导航。
- **消息隐藏与截断**：`disabled` 字段在 prompt 组装时被跳过，`'allBefore'` 从该消息处截断全部历史（index.svelte.ts:849-864）；会话内隐藏不删除数据。
- **自动续写**：结果过短或未以标点结尾时递归以 continue 模式把续文拼接到上一条消息（index.svelte.ts:1885-1904）。
- **窗口化渲染**：默认只挂载最近 30 条消息，滚动到顶追加 15 条（`src/ts/chatLoadPages.ts`）；消息 DOM 用哈希差量增删，不做虚拟化（`Chats.svelte:65-167`）。
- **搜索**：本次未找到消息级搜索；仅见角色列表（`MobileSearch`）与模型列表的过滤搜索。
- **冷存档**：启动时把久未使用的角色与聊天搬到 `coldstorage/` 键，按需 `preLoadChat` 取回（`process/coldstorage.svelte.ts:529,576`），作为会话管理的归档边界。

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

# Risuai 独特功能调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`e565563a288ebe4c65b6099a1645ba477d1c84b4`（分支：`main`）
>
> 调查方式：只读盘点根 README、AGENTS.md 与 `src/ts`/`src/lib` 目录注册表；对 Emotion Images、插件系统、记忆、翻译、Multisend、多用户同步、Risu Hub 等候选逐项走“入口 → 状态/对象 → 执行 → 用户结果 → 持久化”主链；核对现有 Risuai 六份类目笔记的去重边界；全部为静态证据，未运行应用
>
> 调查范围：README 与任务候选清单中超出现有类目的独特能力——Emotion Images、Visual Novel 模式、插件系统整体、记忆系统产品面、翻译系统、Multisend、Risu Hub、WebRTC 多用户同步；明确排除主题/UI/基础 Provider 配置（指南规定不进入本类目）与被现有笔记完整覆盖的机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 与 SillyTavern 同属角色扮演聊天品类，但产品辨识度不在角色卡或世界书（那些是通用类目基线），而在**把“模型输出”与“角色媒体表现”接成闭环的指令标签链**和**本地优先的完整工具链**。本次确认六项独特能力主链（全部静态证据），另有一项 README 外候选（Visual Novel 模式）在本快照未找到实现：

| 候选 | 证据状态 | 一句话结论 |
|---|---|---|
| Emotion Images（情绪图） | `主链确认`（静态） | 模型回复后按情绪切换角色立绘：inlay 模式让模型直接输出 `<Emotion="...">` 指令标签，普通模式走独立分类请求（LLM 或嵌入相似度）；群聊多角色分屏 |
| 插件系统（API v2.1/v3.0） | `主链确认`（静态） | v3.0 插件在 CSP 隔离 iframe 内经 postMessage RPC 运行，含流桥、AbortSignal 转发、SafeDocument 包装；v2.1 走 AST 安全检查与符号改写；支持热重载、自定义 Provider、TTS/请求钩子 |
| 翻译系统 | `主链确认`（静态） | 渲染链内嵌“结构保留翻译”：DOM 遍历文本节点、超长分块拼接、LLM/DeepL/DeepLX/Bergamot/Google 多后端与预设、LLM 翻译缓存 |
| Multisend | `主链确认`（静态） | 按文件类型分派的批量发送：.po 逐条翻译流水线、pdf/txt/xml 本地嵌入检索后剪裁发送、媒体存 inlay 资产 |
| WebRTC 多用户同步 | `主链确认`（静态） | PeerJS 房间：共享当前角色与聊天、生成互斥检查、生成后广播；纯 P2P 无自建服务器，UI 标记 experimental |
| Risu Hub 生态接入 | 客户端`主链确认`，服务端外部依赖 | 角色市场浏览/下载/上传 + 资源服务器 + 账号体系；账号同步与 Drive 备份已归并已有笔记 |
| 记忆系统（Hypa/Supa/Hanurai） | `归并已有类目` | 四套可切换记忆压缩引擎的机制已在对话请求与上下文笔记 §3 完整覆盖，本笔记只补产品角度一句话 |

结论：Risuai 超出通用 Chat 底座的能力集中在**模型指令标签媒体链（情绪图/出图/资产标签）**、**双层安全模型的原生插件运行时**与**本地优先的文件/翻译/多用户工作流**三个方向。

## 介绍声明与候选盘点

README（65 行）的功能清单是候选的第一来源：Emotion Images、Group Chats、Plugins、Regex Script、Powerful Translators、Lorebook、Themes、Powerful Prompting、Customizable UI、TTS、Additional Assets、Long-term Memory。任务候选清单另有 Visual Novel 模式、Multisend、Stable Diffusion、MCP、多用户同步、Drive 云同步、冷存储归档与 Risu Hub，其中 Visual Novel 不在 README 中（详见“声明不符”节）。

与现有 Risuai 笔记去重后，候选分三组：

- **进入独特能力卡**（下节）：Emotion Images、插件系统、翻译系统、Multisend、多用户同步、Risu Hub。
- **归并已有类目**：记忆系统、Powerful Prompting（提示词模板）、Regex Script（触发脚本）、Lorebook、Group Chats、Additional Assets、MCP、TTS、Stable Diffusion、冷存储、Drive/账号同步、主题与基础 Provider。
- **声明不符**：Visual Novel 模式。

## 已确认的独特能力

### 能力一：Emotion Images（情绪图）（`主链确认`，静态证据）

**用户目标**：让角色立绘随剧情情绪自动切换——普通角色扮演应用只有静态头像，本能力把“情绪表达”做成模型驱动、可随角色卡分享的媒体工作流。

**入口与触发者**：角色配置面板的视图模式选择器（normal/emotion/imggen，`src/lib/SideBars/CharConfig.svelte:474-493`）与情绪图管理（`src/ts/characters.ts:162-187`，`emotionImages` 为“情绪名 + 图片路径”二元组数组）。触发者是模型输出本身：生成完成后自动触发，无需用户干预。

**完整主链**（双路径）：

1. **inlay 路径**：开启后生成时把情绪指令注入提示尾部（`src/ts/process/index.svelte.ts:567-572`，指令含可用情绪名清单 `{{slot}}`）；模型在回复末尾输出 `<Emotion="名称">` 标签，`runInlayScreen` 将其改写为 `{{emotion::名称}}` 解析标签（`src/ts/process/inlayScreen.ts:7-11`）；消息渲染器把标签替换为对应图片（`src/ts/parser/parser.svelte.ts:504-511`）。
2. **普通路径**：不启用 inlay 时，每次生成结束后发起独立的情绪分类请求——默认用当前主模型做少量示例分类（情绪名做 logit 偏置，`index.svelte.ts:2084-2160`），或当 `emotionProcesser` 设为 embedding 时改用嵌入相似度检索（`index.svelte.ts:2008-2051`）；分类结果写入 `CharEmotion` 运行时 store 并驱动立绘切换。

**事实对象与状态**：`CharEmotion` store 按角色保存“情绪名 + 图片路径 + 时间戳”记录（每角色保留最近 5 条，`index.svelte.ts:1974-1976`）；`getEmotion` 按时间戳取最新一条（`src/ts/util.ts:291-360`），`EmotionBox`/`ChatScreen` 消费。群聊按视图模式（multiple/single/emp）决定取单角色还是多角色并列显示（`util.ts:303-357`）。

**持续性**：情绪图随角色卡持久化并在卡导入导出中迁移（`src/ts/characterCards.ts:748-766` 的 hub 模式加载与 `:1553-1556` 导出块）；`CharEmotion` 是纯运行时状态，切换角色（`Sidebar.svelte:65` 清空）或重启后回落到 neutral 默认图。

**主动性与取消**：分类请求挂在主生成的 `abortSignal` 上（`index.svelte.ts:2108`），用户停止生成可取消。情绪选择无持久化审批环节。

**外部依赖与执行域**：全部本机浏览器执行，无外部服务；分类用当前配置的主模型或嵌入模型（嵌入来源见记忆系统）。

**安全与资源边界**：情绪图路径存储在应用资产目录，无外部网络写入。

**独特性判断**：这是“模型指令标签 → 媒体执行”的完整闭环（与 Additional Assets 的 `{{img::}}`/`{{bg::}}` 标签同一解析器，`parser.svelte.ts:408`），且带独立分类请求兜底；SillyTavern 的表达式系统只到 `入口确认` 且依赖 Extras API/classify 外部模块，Risuai 路径完全本地闭环。注意：`req.special.emotion` 字段（把分类结果回填立绘的第三条路径）在快照中未找到写方，属于遗留类型定义，实际不活跃。

**证据强度**：源码事实（入口、双路径、状态、解析器）；视觉效果与分类质量未运行验证。

### 能力二：插件系统（API v2.1/v3.0 iframe 沙箱）（`主链确认`，静态证据）

**用户目标**：为角色扮演场景提供可分享、可热更新、且不会污染主应用安全的第三方能力扩展——比“注入脚本”更进一步的产品化插件生态。

**入口与触发者**：设置页导入 `.js`/`.ts` 文件或代码文本（`src/ts/plugins/plugins.svelte.ts:129-428` 的 `importPlugin`），头部注释声明插件名、API 版本、参数、更新地址与版本号；新导入已拒绝 2.0 与 2.1，只接受 3.0。数据库内已有的 2.1 插件仍会在启动时走旧加载器，不因这一入口限制被自动移除。v3 插件随设置页开发模式支持文件监听热重载（`plugins.svelte.ts:343-361,421-429`、`src/ts/plugins/apiV3/developMode.ts`）。

**完整主链**：导入 → 头解析与校验 → 按 API 版本分流执行 → 插件对象持久化到 `db.plugins` → 应用启动/导入后经 `loadPlugins` 重载（`plugins.svelte.ts:432-443`）。两条执行路径：

- **v2.1**：TypeScript 代码先经 sucrase 转译（`src/ts/plugins/apiV3/transpiler.ts:1-10`），再经 acorn AST 静态检查与符号改写——命中黑名单（`eval`、`new Function`、`sessionStorage` 等，完整清单见 `src/ts/plugins/pluginSafety.ts:20-45`）即拒绝，其余全局标识符（`window`/`document`/`localStorage`/`indexedDB`）改写为安全代理（`:55-166`），随后在页面全局运行。
- **v3.0**：每个插件一个独立 iframe，sandbox 仅放行 `allow-scripts`/`allow-modals`/`allow-downloads`，CSP 带随机 nonce 且把 `connect-src` 设为 `'none'`，iframe 内无法发起任何网络请求（`src/ts/plugins/apiV3/factory.ts:438,769-788`）。
- **v3.0 通信面**：宿主侧 `SandboxHost` 经 postMessage RPC 处理方法分发、回调双向代理、AbortSignal 转发与 transferable 收集，`ReadableStream` 经 MessagePort 流桥跨域传输（`factory.ts:484-760`）；加载入口 `executePluginV3` 建 iframe 后执行 `host.run`（`v3.svelte.ts:1388-1406`）。

**API 面与钩子**：插件可注册自定义 AI Provider（`pluginV2.providers`）、消息编辑钩子（编辑输入/处理/显示/输出文本共四类，注册表见 `plugins.svelte.ts:468-480`）、请求前后替换、生成完成监听、TTS 前/后处理钩子（`src/ts/process/ttsHooks.ts`）与 MCP 模块注册（`v3.svelte.ts:15` 引用的 `registerMCPModule`）以及菜单/面板注入；DOM 访问经 SafeDocument/SafeElement 包装层（含标签白名单与 `freezed` 元素禁止访问，`src/ts/plugins/pluginSafeClass.ts`），插件存储分设备级与插件级，随存档持久化。

**安全与资源边界**：v3 iframe 内无网络、无顶层 DOM 直连；存量 v2.1 靠静态改写兜底（校验结果按代码哈希缓存于 localStorage，`pluginSafety.ts:58-71`）。v3 的输出监听器现在复用 replacer 授权，读取 inlay 资产另设 inlay 授权；两者都是按插件名和脚本哈希记录的同意，并对 periodic 权限按三天重新确认（`v3.svelte.ts:567-625,728-750`）。插件脚本本身是用户主动导入的可信代码，更新地址强制 https（`plugins.svelte.ts:280-293`）。

**独特性判断**：双层安全模型（AST 改写 + iframe 沙箱）在同一插件系统内并存，且 v3 的“结构化克隆 RPC + 流桥 + AbortSignal 转发”在样本中未见同等实现；SillyTavern 扩展（manifest + `import()` 动态加载、生成拦截器）无沙箱层，VCPChat 插件为本体注入而非隔离运行时。这既是产品生态能力，也构成独立的安全工程机制（统计时机制单列）。

**证据强度**：源码事实（导入、分流、沙箱、RPC、钩子注册）；真实插件运行与逃逸测试未验证。

### 能力三：翻译系统（`主链确认`，静态证据）

**用户目标**：让用户用自己熟悉的语言与任意语言模型角色扮演——输出自动翻译、输入反向翻译，且翻译保留消息原有的格式、媒体标签与结构。

**入口与触发者**：消息渲染链（`src/lib/ChatScreens/ChatBody.svelte:109-149`）在启用翻译时把解析后的消息交给 `translateHTML`；输入框提供正反向翻译按钮（`DefaultChatScreen.svelte:419-439`）；翻译开关与目标语言为全局设置（`translator`、`translatorInputLanguage`）。

**完整主链**：`translateHTML` 用 DOMParser 走 DOM 遍历，逐文本节点翻译并跳过 `script`/`style`/`translate="no"` 节点（`src/ts/translator/translator.ts:257-477`）；`combineTranslation` 开启时按句重组段落再逐句翻译（`:436-468`）；超长文本进入“超级分块”模式，用分隔符拼接后批量翻译、失败时逐条回退（`:321-363`）。后端经 `runTranslator` 分派（`:121-241`）：

- LLM：复用当前 Provider，按翻译预设请求（`presets.ts`，预设可导出为 `.risutl` 加密文件）；
- DeepL / DeepLX：官方 API 或本地 DeepLX 服务；
- Bergamot：本地 WASM 翻译器；
- Google：免费端点与实验性 HTML 抓取（仅 Tauri/自托管环境）。

结果统一过 `edittrans` 正则后处理（快照提交即修复预设正则未生效的问题）。

**持续性**：语言与后端配置在全局 Database；LLM 翻译结果缓存于 localforage `LLMTranslateCache`（`translator.ts:29-31`），内存中另有文本级双向缓存（`:22-25`）。

**外部依赖**：DeepL/DeepLX/Google 端点为外部服务；Bergamot 为本地 WASM；LLM 模式复用应用已配置的 Provider，无新增依赖。

**独特性判断**：把“翻译”做成渲染管线的一等公民——结构保留（媒体标签、Markdown 结构不破坏）+ 多后端可替换 + 预设与缓存闭环；Cherry Studio 的翻译已达到 `主链确认` 并进入特色统计，Risuai 的 DOM 结构保留翻译可作为同类比较样本。

**证据强度**：源码事实（入口、DOM 遍历、分块、后端分派、缓存）；实际翻译质量与性能未运行验证。

### 能力四：Multisend（`主链确认`，静态证据）

**用户目标**：把“文件”作为对话工作对象批量送入模型——不是简单贴附件，而是按文件类型定制处理流程（逐条翻译、语义剪裁、媒体入消息）。

**入口与触发者**：输入框文件按钮（`DefaultChatScreen.svelte:634,1003` 调 `postChatFile`），支持多选。

**完整主链**（`src/ts/process/files/multisend.ts:196-316` 按扩展名分派）：

- **.po 翻译流水线**：解析 gettext 文件，逐条 `msgid` 作为用户消息发送并触发生成，收集 `msgstr` 重建 `.po` 文件下载（`multisend.ts:16-109`，含 Speaker/Note 注释保留）。
- **pdf/txt/xml**：解析内容后经 `HypaProcesser` 本地嵌入，按附带查询取最相似的若干条（最多 6 条）剪裁为 `<File>...</File>` 块发送（`multisend.ts:111-178`）。
- **图片/音频/视频**：经 `postInlayAsset` 存入 localforage `inlay` 存储并在消息中渲染（`src/ts/process/files/inlays.ts:35-81`）。

**持续性**：inlay 媒体存 IndexedDB；.po 输出文件即时下载，不落库。

**独特性判断**：三种文件处理各有完整主链且共享同一入口；.po 逐条生成式翻译是样本中少见的“文件级翻译工作流”（与翻译系统的消息级翻译互补）。

**证据强度**：源码事实；.po 端到端往返与嵌入检索质量未验证。

### 能力五：WebRTC 多用户同步（`主链确认`，静态证据）

**用户目标**：多人共同体验/围观同一个角色的当前聊天——宿主把自己的角色与聊天实时共享给房间成员，成员间生成互斥，实现“轮流驱动同一角色扮演”。

**入口与触发者**：聊天列表创建房间（`src/lib/SideBars/SideChatList.svelte:298,410`，UI 带 experimental 标记），Playground 菜单输入房间号加入（`src/lib/Playground/PlaygroundMenu.svelte:128`）。触发者为成员的消息发送。

**完整主链**（`src/ts/sync/multiuser.ts`）：host 经 PeerJS 建房间（`:60-256`）→ 加入者连接后 host 发送当前角色（仅当前聊天）+ 缺失资产（`:81-125`）→ 加入者创建 `§temp` 临时角色（`:290-309`）→ 每次生成结束 `peerSync()` 向房间广播最新聊天（`:369-391`，调用点 `index.svelte.ts:1963`）→ 生成前 `peerSafeCheck()` 轮询全体成员空闲状态做互斥（`:393-429`），冲突时 `peerRevertChat` 回退到最近同步快照。

**持续性**：无持久化——状态只活在连接生命周期内，断开即失联；同步范围仅限“当前角色的当前聊天”，不是整库同步。

**安全与资源边界**：默认连公共 PeerServer，房间 ID 即口令，无鉴权；媒体按 id 逐个传输，无大小/配额限制（静态未发现限额逻辑）。

**独特性判断**：纯 WebRTC、无自建服务器的房间式共同角色扮演，与一般“多端同步”不同——它同步的是**进行中的对话现场**而非数据副本；样本中无同类实现，保留为稀有能力卡。

**证据强度**：源码事实（房间协议、互斥、广播）；公网 PeerServer 连通性与真实多人行为未验证。

### 能力六：Risu Hub 生态接入（客户端 `主链确认`，服务端外部依赖）

**用户目标**：角色卡的“市场—下载—分享—资源托管”闭环——应用内置浏览与分享界面，上传资源经应用自身站点托管（与 Chub 的第三方依赖形成对比）。

**入口与触发者**：Realm 浏览界面（`src/lib/UI/Realm/RealmMain.svelte:22` 调 `getRisuHub`）、主菜单与 Lite 界面的市场卡（`MainMenu.svelte:61`、`LiteMain.svelte:26`）、上传页（`RealmUpload.svelte:88`）。

**完整主链**：搜索/分页/nsfw/排序参数拼入 `hubURL/realm/` 查询（`src/ts/characterCards.ts:1775-1802`）→ 详情与下载（`downloadRisuHub`，含 TOS 确认，`:1804+`）→ 以 hub 模式导入，卡内资源（情绪图、附加资产、VITS）经 `getHubResources` 从资源服务器拉取（`:1876-1882`、`importCharacterCardSpec` 的 hub 分支）→ 分享时导出 PNG 卡并打开 `realm.risuai.net` 上传（`shareRisuHub2:1681-1750`，成功后写回 `realmId`）。

**持续性**：`realmId` 存角色对象，可续传更新；账号、Drive 备份与远端冷存储属同一 hub 站点体系，但机制已在 LLM 渠道管理笔记（账号同步与 backupDrive）与会话与消息管理笔记（冷存储）覆盖。

**独特性判断**：自有市场 + 资源服务器 + 账号同步的闭合生态接入；客户端主链完整，服务端本体在仓库外。

**证据强度**：客户端主链为源码事实；服务端行为、上传成功率与市场内容未验证（外部依赖）。

## 已归并到现有类目的能力

- **记忆系统**：四套可切换记忆压缩引擎（SupaMemory 滚动摘要、HypaMemoryV2/V3 分层与预算化摘要、HanuraiMemory 嵌入检索召回）的触发、预算、注入与聊天级持久化（状态存聊天的三个记忆字段）已由[对话请求与上下文调查笔记](../对话请求与上下文/Risuai-对话请求与上下文调查笔记.md) §3 完整覆盖（入口 `src/ts/process/index.svelte.ts:1068-1154`）。产品角度补充一句：README 把 Long-term Memory 列为旗舰，其辨识度在于**单一聊天上四选一的记忆引擎 + 嵌入向量本地缓存**（localforage `hypaVector`，`hypamemory.ts:38-230`），机制面不再重写。
- **Powerful Prompting**（模板、formatingOrder、条件变量、Impersonate）：提示词拼装顺序与模板消费已在对话请求与上下文笔记 §2 覆盖（`templates/templates.ts` 的 prebuiltPresets 只是数据）。
- **Regex Script / 触发脚本**：start/request/output/display 等触发点的编辑脚本（含 Lua/Pyodide 引擎，`scriptings.ts`）已在对话请求与上下文笔记（脚本触发点 888-898、900-1053、1763）覆盖，归并入“请求与上下文”类目。
- **Lorebook**：角色级/聊天级/模块三源合并激活已由 [Agent 角色配置调查笔记](../Agent角色/Risuai-Agent角色配置调查笔记.md) 与对话请求与上下文笔记（`loadLoreBookV3Prompt`）覆盖。
- **Group Chats**：群聊对象与上下文注入为角色扮演通用能力，已在 Chat 概览与对话请求与上下文笔记覆盖；情绪卡中的群聊多角色显示属于情绪能力扩展面。
- **Additional Assets**（聊天内嵌图片/音视频/背景/BGM）：解析器标签面（`{{img::}}`/`{{video::}}`/`{{bg::}}`/`{{bgm::}}` 等，`parser.svelte.ts:408-580`）为消息渲染/媒体嵌入面，Risuai 尚未建立消息渲染器专项笔记，本次仅确认到 `入口确认`，不展开为能力卡；其“模糊匹配 + 哈希随机多路径”细节待渲染器类目承接。
- **MCP**：工具注册与执行归 Agent 工具类目（Risuai 专项笔记未建立，Agent 角色笔记 §5 已记录 `RisuModule.mcp` 与插件层注册入口）；本快照另有 filesystem/google search/dice/graphmem/aiaccess/risuaccess 等内置 MCP 客户端（`src/ts/process/mcp/`）。
- **TTS**：通用能力，多 Provider（webspeech/elevenlab/VOICEVOX/novelai/openai/huggingface/vits/gptsovits/fishspeech）为普通配置面；插件 TTS 钩子（`ttsHooks.ts`）并入插件能力卡，不单独计数。
- **Stable Diffusion**：多 Provider 出图为通用扩展（`stableDiff.ts`，webui/novelai/dalle/stability/comfy/kei/fal/Imagen/openai-compat/wavespeed）；其 imggen inlay 模式（模型输出 `<ImgGen="...">` → 自动出图 → 消息内渲染，`inlayScreen.ts:12-45`）与情绪卡同一机制族，并入能力一叙述。
- **冷存储归档**：大聊天外置 gzip 独立文件与远端存储已由会话与消息管理笔记、Agent 角色笔记覆盖。
- **Drive 云备份与账号同步**：已由 LLM 渠道管理笔记持久化节覆盖（`backupDrive` 与 `/api/account/write`）。
- **Themes / Customizable UI / Multiple API Supports**：指南明确规定主题与基础 Provider 配置不进入本类目。

## 声明不符、外部依赖与暂缓项

- **Visual Novel 模式**：本快照未找到实现。检查范围：README 功能清单（无此条目）、AGENTS.md 声称的 `src/lib/VisualNovel/` 目录（不存在）、全仓检索 `VisualNovel|visualnovel|vn_`（`src` 下零命中，仅 `src/ts/iris.ts:86` 内建助手提示词中的 “visual novel style” 字样与越南国家码 “VN”）。结论：任务候选清单把它列为 README 宣传与实际不符；若指后续版本功能，需在新快照复查。
- **`req.special.emotion` 路径**：请求响应类型中保留的“分类结果回填立绘”字段在快照中未找到任何写方（检索 `request/` 全目录），判定为遗留类型定义。
- **Risu Hub / 多用户同步的外部依赖**：hub 服务器与 realm.risuai.net、PeerJS 公共信令服务器均为仓库外服务；客户端接入主链已确认，服务端行为不在本仓库。
- **暂缓项**：插件市场生态规模、Risu Hub 服务端策略与账号权益为外部事实，不入特色统计。

## 对特色贡献统计的影响

- **主贡献候选**：Emotion Images（情绪图，模型指令标签媒体链，标签：`创作工作站` 边界/角色表现）；插件 iframe 沙箱运行时按“工程与安全机制”单列，不混入产品特性分。
- **辅助贡献候选**：翻译系统（结构保留翻译，参照 Cherry Studio 先例）、Multisend（文件工作对象，含 .po 流水线）、WebRTC 多用户房间（稀有能力卡，样本唯一）、Risu Hub 客户端接入（外部依赖标注）。
- **不重复计数**：记忆系统（归并）、冷存储、Drive/账号同步、Additional Assets（待渲染器类目）。
- 待查清单需新增 Risuai 条目并维护状态；统计文件目前尚无 Risuai 行，建议按上述候选补充。

## 未验证事项

- 情绪分类请求的实际触发频率、分类质量与立绘切换视觉效果（含嵌入分类路径与群聊分屏）需运行验证。
- 插件 iframe 沙箱的逃逸面与 MessagePort 流桥在主流浏览器（尤其 Safari）的行为；v2.1 AST 改写在复杂语法下的漏网情况。
- 翻译的 DOM 遍历性能、超级分块在超长消息上的表现、LLM 缓存命中与失效语义。
- Multisend 的 .po 端到端往返、嵌入检索对 pdf/txt/xml 的剪裁质量。
- 多用户房间在公网信令下的连通性、生成互斥与回退的真实行为（UI 已标记 experimental）。
- Risu Hub 服务端搜索/上传行为与账号同步链路（外部服务，未运行）。
- Visual Novel 模式：本快照未找到；如需确认存在性需按新快照或官方渠道复查。

## 关键源码索引

- 情绪图：`src/ts/process/index.svelte.ts`（inlay 指令注入 567-572、`CharEmotion` 更新 1974-1983、分类请求 1991-2160）；`src/ts/process/inlayScreen.ts:7-97`；`src/ts/util.ts:279-360`（getEmotion）；`src/ts/parser/parser.svelte.ts:408,504-511`；`src/lib/SideBars/CharConfig.svelte:474-493`；`src/lib/ChatScreens/EmotionBox.svelte`。
- 插件系统：`src/ts/plugins/plugins.svelte.ts`（importPlugin 129-428、loadPlugins 432-443、钩子注册表 468-480）；`src/ts/plugins/apiV3/factory.ts`（CSP 438、SandboxHost.run 769-926、RPC 处理 790-888）；`src/ts/plugins/apiV3/v3.svelte.ts:1374-1424`（loadV3Plugins/executePluginV3）；`src/ts/plugins/pluginSafety.ts:55-166`；`src/ts/plugins/apiV3/transpiler.ts`；`src/ts/plugins/pluginSafeClass.ts`。
- 翻译：`src/ts/translator/translator.ts`（translate 39-55、runTranslator 57-119、translateMain 121-241、translateHTML 257-477）；`src/ts/translator/presets.ts`；`src/lib/ChatScreens/ChatBody.svelte:109-149`；`src/lib/ChatScreens/DefaultChatScreen.svelte:419-439`。
- Multisend：`src/ts/process/files/multisend.ts`（sendPofile 16-109、sendPDFFile 111-138、postChatFile 196-316）；`src/ts/process/files/inlays.ts:35-81`；入口 `DefaultChatScreen.svelte:634,1003`。
- 多用户同步：`src/ts/sync/multiuser.ts`（createMultiuserRoom 60-256、joinMultiuserRoom 262-366、peerSync 369-391、peerSafeCheck 393-429）；调用点 `index.svelte.ts:1963`；UI `SideChatList.svelte:298,410`、`PlaygroundMenu.svelte:128`。
- Risu Hub：`src/ts/characterCards.ts`（hubURL 26、shareRisuHub2 1681-1750、getRisuHub 1775-1802、getHubResources 1876-1882）；`src/lib/UI/Realm/RealmMain.svelte:22`、`RealmUpload.svelte:88`。
- 记忆（归并引用）：`src/ts/process/memory/`（hypamemory.ts HypaProcesser 38-230、supaMemory.ts、hypav2.ts:335、hypav3.ts:118、hanuraiMemory.ts:9）；选择与注入 `index.svelte.ts:1068-1154`。

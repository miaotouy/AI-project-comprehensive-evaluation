# Cherry Studio 独特功能调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`e2fd716e569c73c1baa4ac226b6b0607792cdb9d`（分支：`main`）
>
> 调查方式：只读源码梳理；结合根 README 功能声明与路由/组件盘点；未修改 cherry-studio 仓库
>
> 调查范围：Mini Program、全局搜索、消息级翻译、选中文本助手与 Agent 窗口、截图与系统 OCR、本地语音、Markdown Notes 的入口、执行链与产品表面；多模型同时对话、文档处理、Agent workspace 归并到已有类目；未运行应用
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

| 候选 | 状态 | 依据 |
|---|---|---|
| Mini Program（小程序） | 主链确认 | 预设/自定义网站与可安装 `.miniapp` 本地包、权限与更新治理、keep-alive 池，见能力卡 1 |
| 全局搜索 | 主链确认 | `app.search` 命令 + 联邦实体搜索 + FTS5 内容搜索（游标分页），见能力卡 2 |
| 多模型同时对话 | 归并已有类目 | LLM 渠道笔记 §6 与 Chat UI 笔记 §7 已主链确认（@模型多选 → 并行执行 → 兄弟组展示） |
| 翻译 | 主链确认 | 流式翻译 + `data-translation` part 持久化，见能力卡 3 |
| 选中文本助手 | 主链确认 | 系统选中 hook + 浮动工具栏 + 独立 Agent 窗口与胶囊，见能力卡 4 |
| 截图与系统 OCR | 主链确认 | 框选标注、系统 OCR 行框、复制或送入聊天草稿，见能力卡 5 |
| 本地语音 | 主链确认 | 本地 ASR/TTS 适配与系统语音原生扩展，听写与朗读共用一条执行链，见能力卡 6 |
| Markdown Notes | 主链确认 | 磁盘笔记目录 + 元数据表 + @ 引用与知识库快照，见能力卡 7 |
| 文档处理 | 归并已有类目 | 附件/OCR/知识库链在会话与消息管理、对话请求与上下文笔记覆盖 |
| Agent workspace | 归并已有类目 | Chat UI 笔记 §6.2（agent 适配器的工作区文件解析、artifact 面板）与 Agent 工具笔记覆盖 |

根 README 已按 Agents & Automation、Models & Conversations、Knowledge & Documents、Creative & Everyday Tools、Voice & Workspace 五组重写（`README.md:71-105`），Global Search、Mini Apps、翻译、多模型同时对话的声明仍与代码相符。原先把 Notes、OCR、TTS/ASR 归入愿景的判断已不成立：这三项在当前快照中都有可执行主链，见能力卡 5～7。

## 介绍声明与候选盘点

README 关键特色：300+ 预配置助手、多模型同时对话、文档与数据处理（Office/PDF、WebDAV 备份）、全局搜索、Topic 管理、AI 翻译、拖拽排序、Mini Apps、MCP、Skills、定时任务与消息渠道（Channels）、语音输入与朗读、选中文本工具。README 不列独立的 Roadmap 愿景清单，指向项目板与 Releases；Notes/Canvas/OCR/TTS 等能力以代码入口为准。

## 已确认的独特能力

### 能力卡 1：Mini Program（网站门户与本地应用包）

**用户目标**：在客户端内以独立标签页运行第三方网站与本地打包应用，与聊天工作区并列使用。网站型小程序提供 Web 门户；`.miniapp` 包则把 manifest、资源、权限和版本一起安装到受管运行环境。

**入口与触发者**：侧栏小程序分区（sidebarVariants.tsx 的 miniAppVariant + 收藏）、Launchpad（`MiniApp.tsx` 的 launchpad 变体）、设置页"小程序"面板。触发者始终是用户点击。

**事实对象**：MiniApp 行继续承载预设或自定义网站；安装型应用另有 installation 记录，保存版本、manifest、AI 模型绑定与包身份。`kind='app'` 的对象身份由包决定，普通编辑只能改状态与排序，不能把 URL 改出沙箱；见 `src/shared/data/types/miniApp.ts:68`、`src/main/data/services/MiniAppService.ts:56-57,87-138,275`。

**完整主链**（静态走通）：

```text
侧栏收藏 / Launchpad 点击
  -> openTab(`/app/mini-app/<id>`)（MiniApp.tsx）
  -> MiniAppPage.tsx：路由 /app/mini-app/$appId
      -> MiniAppPane 内的 WebviewContainer 加载 app.url（MinimalToolbar 提供地址与导航）
      -> openMiniAppKeepAlive 注册进全局 LRU keep-alive 池（MiniAppTabsPool）
      -> 后台标签页保持挂载（React 19 Activity keep-alive），仅活动页驱动 currentMiniAppId
  -> 关闭/隐藏：openedKeepAliveMiniApps 移除；status -> disabled（MiniApp.tsx）
  -> 持久化：MiniAppService 读写 DB
     （预设行 = 差量覆盖；网站 = 全量；安装应用 = 行 + installation/manifest）
  -> 区域过滤：supportedRegions 与偏好 miniApps.regionFilter（'auto'|'CN'|'Global'）
  -> 临时小程序：openSmartMiniApp 发布的 transient descriptor 走共享缓存
     （mini_app.transient_descriptor.<appId>，所有窗口可读，不进 DB）
  -> 本地包：文件拖入或 https manifest URL -> 安装预览 -> 用户勾选可选权限
     -> 独立 partition/origin + grants -> 运行 -> 更新审查 -> 替换或卸载
```

**持续性**：预设、自定义网站、安装记录、权限授予、启停和排序落 SQLite；包资源由安装器管理，keep-alive 池仍是窗口内内存态。安装 UI 接受单个 `.miniapp` 文件或 https manifest，先展示描述、网络主机和权限清单；更新增加权限时必须再次确认，权限撤销与活动记录可在详情面板查看。依据：`src/renderer/pages/miniApps/InstallMiniAppPanel.tsx`（InstallMiniAppPicker）、`components/MiniApp/InstallConsentDialog.tsx`、`MiniAppDetailPanel.tsx`、`UpdateReviewDialog.tsx`。

**安全与资源边界**：网站型 webview 与安装型应用的权限面已分开。安装包声明宿主权限与网络 allowlist，用户可拒绝可选权限；本地包使用自己的 partition、origin 和 grant 记录，更新时对身份与权限变化做审查。网站 URL 仍属于用户配置的外部页面，不因此获得安装包权限。沙箱、剪贴板、网络与 AI 桥的真实运行效果未做黑盒验证。

**独特性判断**：该能力同时包含 Web 门户与本地应用包。网站路径仍是标签化门户；安装包路径已经形成 manifest、能力授权、独立运行域和更新治理，不再能概括为“无协议桥的纯 Web 门户”。

**证据强度**：静态源码 + 大量组件测试（MiniApp.test.tsx、MiniAppTabsPool.test.tsx、MiniAppPage.test.tsx）；未运行 webview 实际加载。

### 能力卡 2：全局搜索（跨 Topic/Session 联邦搜索）

**用户目标**：一次性搜索全部会话实体与消息内容，替代逐会话翻找。与 Chat UI 笔记 §2.3 的"会话内 DOM 搜索"是两条不同链路：后者只搜已渲染窗口，前者是数据库级全量搜索。

**入口与触发者**：顶栏搜索按钮（`ShellTabBarActions.tsx:24`）+ `app.search` 命令（`AppShell.tsx:75-80`）→ GlobalSearchPopup。

**完整主链**（静态走通）：

```text
GlobalSearchPopup -> GlobalSearchPanel
  -> 实体搜索：GET /search/entities（EntitySearchService.ts:40-55，
     types=assistant/agent/topic/session/knowledge-base，all-or-nothing 联邦查询）
  -> 内容搜索：GET /search/contents（ContentSearchService.ts:133-151，
     sources=topic-message / session-message）
      -> messageService.search / agentSessionMessageService.search
      -> ftsSearch.ts：FTS5（trigram LIKE 索引回退）+ keyset cursor 分页
        （encode/decodeSearchCursor）、关键词正则高亮、snippet 构造
  -> 分组展示（GlobalSearchResults.tsx：recent/topic/session/message/assistant/agent/knowledge-base）
  -> 过滤：时间（any/today/week/month/quarter）、来源（topic/session）、类型
  -> 定位：点击消息结果 -> 打开对应 Topic/Session 并跳到消息（selection events 广播给目标 tab）
  -> 最近搜索项：recordGlobalSearchRecentEntry（缓存 ui.global_search.recent_items）
```

**持续性**：搜索本身无状态（实时查询）；最近搜索项走共享缓存；消息预览面板按需拉取。

**独特性判断**：联邦实体搜索（含 knowledge-base）+ 双消息源内容搜索 + 游标分页的组合在样本中较完整；与 DeepChat 的 FTS5 跨会话搜索（经 conversationSearchServer 暴露给模型工具与设置页）方向不同——Cherry 是用户产品入口优先。

**证据强度**：静态源码 + 组件测试（GlobalSearchPanel.test.tsx 等 5 个测试文件）；未运行真实查询。

### 能力卡 3：翻译（消息级流式翻译）

**用户目标**：不重发整条消息即可把某条助手回复翻译成目标语言，翻译结果作为消息的一部分持久化。

**完整主链**（静态走通）：

```text
消息操作栏"翻译"（messageMenuBarActions.tsx translateMessage，Home 适配器可写）
  -> IPC translate.open（main/ipc/handlers/translate.ts）
  -> translateService.open：解析翻译模型/语言，流式交给 AiStreamManager
     （WebContentsListener 按 translate:* streamId 推送 ai.stream.* 事件）
  -> 渲染层 translateText + createTranslationUpdater：
      先写入空 data-translation part 占位，随流增量编辑该 part
      （homeMessageListAdapter.tsx，走 chat write 的 editMessage）
      失败或取消时移除占位 part，保留原文
  -> 历史：translateHistory 表；内置+自定义语言：translateLanguage 表 + seeder
  -> 渲染：data-translation part 在消息内展示，可再次翻译覆盖
```

**边界**：译文 part 的写入已从主进程迁到渲染层适配器，主进程只负责流式生成；这意味着持久化时机与消息编辑共用同一条写路径。翻译语言目录、模型选择（走消息原 Provider 还是独立翻译模型）未展开核对；取消即丢弃（discard-on-cancel）。

**独特性判断**：把译文作为消息 part 持久化、可重译覆盖的产品形态比"另开窗口翻译"完整，但翻译本身是常见功能，保留为辅助贡献。

### 能力卡 4：选中文本助手与独立 Agent 窗口

**用户目标**：在任意应用里划词后直接翻译、解释或交给 Agent 处理，不必先切回主窗口。

**入口与触发者**：系统级选中监听由原生模块 `selection-hook` 提供，`SelectionService` 挂接后按偏好 `SelectionTriggerMode` 决定划词即弹还是按住修饰键弹出浮动工具栏；触发者在其它应用里，不在 Cherry 的 WebContents 内。

**事实对象**：一次选中会话（`SelectionActionSession`），包含选中文本、动作项、绑定的 Agent 与窗口布局状态。

**完整主链**（静态走通）：

```text
其它应用中划词
  -> SelectionService：hook 回调 -> 浮动工具栏窗口（TextSelectionToolbar / SelectionToolbarView）
  -> 预置动作：翻译、解释等（动作项由 selectionActionItems 表与升级 seeder 提供）
  -> Agent 动作：useSelectionAgents 解析绑定 Agent
     -> SelectionAgentWindowService 打开独立窗口
        （compose 栏 -> 会话视图，尺寸/边界由 selectionAgentWindowBounds 计算）
     -> 已打开的多个窗口可折叠成胶囊
        （selectionCapsuleLayout 排列，native/selection-panel 原生层跟随活动空间）
  -> 结果：回合写入该动作对应的 Agent 会话，窗口关闭即释放
```

**安全与资源边界**：macOS 上窗口层级与"跟随当前空间"由原生面板承担，普通 BrowserWindow 无法做到；Windows 下需要系统截图权限，相关例外记录在 `.agents/notes/proposed/bug-fix/2026-11-01-windows-selection-system-screenshot.md`。无障碍授权、全屏与多显示器行为未运行验证。

**独特性判断**：把 Agent 作为一种系统级选中菜单项，并且每次动作有独立窗口可折叠为胶囊，这是跨出主窗口的一等产品表面，不能由 Chat UI 的会话内选择或全局搜索解释。

**证据强度**：静态源码；`SelectionService`、`SelectionAgentWindowService` 与胶囊布局均有单元测试，未在真实桌面环境验证。

### 能力卡 5：截图标注与系统 OCR

**用户目标**：框选屏幕区域、加标注后复制或直接送入对话，并可对区域做文字识别。

**入口与触发者**：快捷键或聊天入口调用 `ScreenshotOverlayService.startCapture`，由用户完成框选；也接受调用方传入源窗口与结果消费者。

**完整主链**（静态走通）：

```text
startCapture(sourceWindowId?, consumer?)
  -> 隐藏源窗口并延迟等待合成器，随后冻结每个显示器
  -> 覆盖窗口：CaptureOverlay + Toolbar / PropertyPanel / TextInput / AnnotationCanvas
  -> 结果提交：
       commit = 复制到剪贴板并结束会话
       copy   = 只复制，不结束（可继续标注）
       submitResult = 交给传入的 consumer（例如写入聊天草稿的图文内容）
  -> OCR：recognizeText -> recognizeScreenshotText（主进程原生 OCR）
       行框回填 OcrTextOverlay，随区域变化作废过期请求
```

**安全与资源边界**：OCR 可用性取决于本机 Paddle OCR 模型是否就绪（`isScreenshotOcrAvailable`），会话结束统一回收覆盖窗口、临时媒体与自身隐藏的源窗口。多显示器 HiDPI 归一化同时尝试主屏与本屏缩放比。

**独特性判断**：框选标注、窗口/显示器捕获、系统 OCR 行框与"交给调用方"的消费者接口组合在一起，形成了可被聊天或 Agent 复用的截图管线。

**证据强度**：静态源码 + 组件与外壳测试；真实多显示器、HiDPI 与 OCR 质量未运行验证。

### 能力卡 6：本地语音（听写与朗读）

**用户目标**：用语音输入消息、把助手回复读出来，并允许离线运行本地模型。

**入口与触发者**：Composer 的听写入口与可配置快捷键、消息的朗读按钮、自动朗读设置；触发者是用户操作或回复到达事件。

**完整主链**（静态走通）：

```text
听写：DictationService（渲染层采集 PcmCapture）
  -> VoiceService/VoiceStream（主进程会话）
  -> localAdapters 分派执行器：
       systemSpeech（原生系统语音）、funasr、qwen3Asr
  -> 增量转写写回 Composer 文本（SpeechTextInput）
朗读：AutoRead / SpeechPlaybackService
  -> localAdapters 的 kokoroTts、qwen3Tts，或 provider 侧语音模型
  -> PcmPlayback 流式播放，播放状态在 playbackState 汇总
```

**持续性**：模型、音色与语言选择落偏好；本地模型文件与二进制由模型/二进制管理服务维护，原生系统语音由 `native/system-speech` 作为 workspace 包提供（macOS Swift helper，Windows C++ helper）。

**外部依赖与执行域**：本地适配器在本机进程或工具进程内执行，系统语音走平台原生能力，云端语音走 Provider。麦克风与语音识别权限、离线模型下载与跨平台音质未运行验证。

**独特性判断**：语音输入与朗读共用一条"会话 + 执行器 + 播放"链，且同时提供平台原生、本地模型与云端三类执行域，属于本仓库自带的语音子系统。

**证据强度**：静态源码；渲染层服务与主进程适配器均有测试，未做真机录音验证。

### 能力卡 7：Markdown Notes

**用户目标**：在客户端内维护 Markdown 笔记，并把这些笔记作为对话上下文或知识库来源。

**事实对象**：磁盘上的 Markdown 文件（笔记目录可配置）加上 `note` 表中的视图元数据（根路径、相对路径、收藏、展开状态）。

**完整主链**（静态走通）：

```text
设置中选择笔记目录（notesDirectory 校验：拒绝应用数据目录与系统根）
  -> NoteService 按 rootPath 列出/更新笔记记录（isStarred、isExpanded）
  -> useNotesQuery / useNote 在渲染层取数与缓存
  -> Composer 的 noteReference 工具：@ 引用笔记，插入为引用 token
  -> 知识库：pipeline 的 noteSnapshot 把笔记内容转成可索引来源
```

**安全与资源边界**：笔记正文由文件层读写（文件编辑会话负责落盘），数据库只保存视图状态，因此删除数据库记录不会删除笔记文件，反之亦然。笔记目录与文件库目录重叠时被显式拒绝。

**独特性判断**：Notes 与 Composer 引用、知识库快照打通，构成"个人文本资产 + 上下文注入"的组合；单独的 Markdown 编辑器不构成独特功能。

**证据强度**：静态源码；未运行验证引用插入、快照索引与外部编辑的并发表现。

## 当前候选补充

PDF 翻译已形成"选择文档 -> BabelDOC 保版式翻译 -> 写入翻译历史与文件管理器 -> 资源下载进度反馈"的专用主链，可作为创作工作站能力族下的 `主链确认` 候选；它与普通对话导出不同，产物是可管理的翻译文件。截图与 OCR 已升级为能力卡 5。

PDF 翻译的媒体处理细节归入媒体创作笔记，不重复计入普通 Agent 工具或消息渲染能力。依据：`src/main/services/PdfTranslationService.ts`、`src/renderer/pages/translate/pdf/PdfTranslationView.tsx`。

## 已归并到现有类目的能力

- **多模型同时对话**：归并已有类目。LLM 渠道笔记 §6（@模型解析与并行语义、siblings group、steer/临时聊天只取第一个）与 Chat UI 笔记 §7 已主链确认，本笔记不重写。
- **文档处理**：附件（图片/Office/PDF）、OCR、长文粘贴、知识库检索链分别由会话与消息管理、对话请求与上下文、Agent 工具笔记覆盖；README 的 WebDAV 属外部服务，未在本次范围。
- **Agent workspace**：归并[生成式输出与运行时笔记](../生成式输出与运行时/Cherry-Studio-生成式输出与运行时调查笔记.md)的文件标签、共享编辑草稿、冲突处理与文档/行评论引用回流；[Chat UI 笔记 §6.2](<../Chat UI/Cherry-Studio-ChatUI调查笔记.md>)另覆盖 Agent 消息编辑重发、分支导航和复制会话入口。
- **消息级会话内搜索**（DOM 高亮）：Chat UI 笔记 §2.3，与全局搜索区分。

## 声明不符、外部依赖与暂缓项

- Notes、OCR、TTS/ASR 已按代码入口确认为已实现能力（能力卡 5～7）。Canvas 与独立插件系统本轮未找到对应模块与主链（检索范围：`src/renderer`、`src/main`、`packages` 内 canvas/plugin 命名文件，只命中流程图画布、文件预览插件与编辑器插件）。
- 全局搜索的知识库命中依赖知识库索引（`src/main/features/knowledge/query/search.ts`），其索引新鲜度未验证。
- 小程序的实际 webview 加载、区域过滤可用性、keep-alive 内存占用未运行验证。
- 选中文本助手的系统级监听依赖 `selection-hook` 原生模块与操作系统无障碍/截图权限，授权失败时的降级行为未验证。

## 对特色贡献统计的影响

进入主贡献的候选：Mini Program（应用门户）、全局搜索、选中文本助手（跨应用 Agent 入口）、本地语音子系统。辅助贡献：翻译、截图与系统 OCR、Markdown Notes。归并不计数：多模型同时对话、文档处理、Agent workspace、会话内搜索。

## 未验证事项

- 未运行 Electron 应用：webview 加载、GlobalSearch 实际查询结果排序、翻译流式 UI 均为静态确认。
- 小程序 keep-alive 池在大量标签下的资源回收、多窗口间 transient descriptor 同步，以及安装包权限、网络 allowlist、升级和卸载后的运行效果未验证。
- FTS5 与 trigram 回退在中文分词上的实际效果未实测。
- 翻译的模型选择与语言目录完整读写链未展开。

## 关键源码索引

- 小程序预设：`src/shared/data/presets/miniApps.ts`（72 条预设）
- 小程序数据模型：`src/shared/data/types/miniApp.ts`
- 小程序页面与池：`src/renderer/pages/miniApps/MiniAppPage.tsx`、`src/renderer/components/MiniApp/MiniApp.tsx`、`MiniAppTabsPool.tsx`、`WebviewContainer.tsx`
- 小程序服务与 seed：`src/main/data/services/MiniAppService.ts`、`src/main/data/db/seeding/seeders/miniAppSeeder.ts`
- 小程序安装与权限：`src/renderer/pages/miniApps/InstallMiniAppPanel.tsx`、`src/renderer/components/MiniApp/{InstallConsentDialog,PermissionChecklist,MiniAppDetailPanel,UpdateReviewDialog}.tsx`
- 全局搜索入口：`src/renderer/components/layout/AppShell.tsx:82-106`、`ShellTabBarActions.tsx`
- 全局搜索面板：`src/renderer/components/GlobalSearch/GlobalSearchPanel.tsx`、`useGlobalSearchPanelData.ts`、`GlobalSearchResults.tsx`
- 实体/内容搜索服务：`src/main/data/services/EntitySearchService.ts`、`ContentSearchService.ts`
- FTS 与游标：`src/main/data/services/utils/ftsSearch.ts`、`keysetCursor.ts`
- 翻译：`src/main/services/translate/translateService.ts`、`src/main/ipc/handlers/translate.ts`、`src/renderer/utils/translate/translateText.ts`、`src/renderer/pages/home/messages/homeMessageListAdapter.tsx:519-578`
- 选中文本助手：`src/main/services/selection/SelectionService.ts`、`SelectionAgentWindowService.ts`、`selectionCapsuleLayout.ts`、`src/renderer/hooks/useSelectionAgents.ts`、`native/selection-panel/selectionPanel.mm`
- 截图与 OCR：`src/main/services/screenshot/ScreenshotOverlayService.ts`、`recognizeText.ts`、`src/renderer/windows/screenshot/CaptureOverlay.tsx`、`components/Toolbar.tsx`
- 本地语音：`src/main/ai/voice/VoiceSessionService.ts`、`localAdapters.ts`、`src/renderer/services/voice/{DictationService,VoiceService,SpeechPlaybackService}.ts`、`native/system-speech/src/SystemSpeechNativeClient.ts`
- Notes：`src/main/data/services/NoteService.ts`、`src/main/services/notesDirectory.ts`、`src/renderer/components/composer/tools/definitions/noteReference.ts`、`src/main/features/knowledge/pipeline/sources/noteSnapshot.ts`

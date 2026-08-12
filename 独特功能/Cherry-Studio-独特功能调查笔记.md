# Cherry Studio 独特功能调查笔记

> 调查对象：`E:\works\git\cherry-studio`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`cd82f996fb6c3a523b6d40de31314f2b86f56281`（分支：`main`）
>
> 调查方式：只读源码梳理；结合根 README 功能声明与路由/组件盘点；未修改 cherry-studio 仓库
>
> 调查范围：第三批 P2 补查——Mini Program 与全局搜索的入口、执行链和产品表面；多模型同时对话确认现有覆盖；翻译、文档处理、Agent workspace 的覆盖核对
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

| 候选 | 状态 | 依据 |
|---|---|---|
| Mini Program（小程序） | `主链确认` | 60+ 预设 + 自定义 webview 应用、keep-alive 池、launchpad/侧栏入口，见能力卡 1 |
| 全局搜索 | `主链确认` | `app.search` 命令 + 联邦实体搜索 + FTS5 内容搜索（游标分页），见能力卡 2 |
| 多模型同时对话 | `归并已有类目` | LLM 渠道笔记 §6 与 Chat UI 笔记 §7 已主链确认（`@模型` 多选 → 并行 execution → 兄弟组展示） |
| 翻译 | `主链确认`（独特性中等） | 流式翻译 + `data-translation` part 持久化，见能力卡 3 |
| 文档处理 | `归并已有类目` | 附件/OCR/知识库链在会话与消息管理、对话请求与上下文笔记覆盖 |
| Agent workspace | `归并已有类目` | Chat UI 笔记 §6.2（agent 适配器的工作区文件解析、artifact 面板）与 Agent 工具笔记覆盖 |

README（`README.md:80-116`）"Practical Tools Integration" 中的 Global Search、Mini Program、AI-powered Translation、Multi-model Simultaneous Conversations 全部与代码相符。本次补查重点是确认两个缺口项（Mini Program、全局搜索）的主链，均已走通（静态证据）。

## 介绍声明与候选盘点

README 关键特色：300+ 预配置助手、多模型同时对话、文档与数据处理（Office/PDF、WebDAV）、全局搜索、Topic 管理、AI 翻译、拖拽排序、Mini Program 支持、MCP。Roadmap 中的 Notes/Canvas/OCR/TTS/插件系统等仍在愿景清单（`README.md:118-153`），本次未在代码中做存在性断言。

## 已确认的独特能力

### 能力卡 1：Mini Program（小程序，嵌入 Web 应用门户）

**用户目标**：在客户端内以独立标签页运行第三方 Web 应用（ChatGPT、Gemini、Claude、Perplexity、NotebookLM、Coze、Dify、n8n 等），与聊天工作区并列使用——把"桌面客户端"扩展成"Web 应用聚合门户"。

**入口与触发者**：侧栏小程序分区（`sidebarVariants.tsx` 的 miniAppVariant + 收藏）、Launchpad（`MiniApp.tsx` variant='launchpad'）、设置页"小程序"面板。触发者始终是用户点击。

**事实对象**：`MiniApp` 行（`src/shared/data/types/miniApp.ts:32-57`）：`appId`、`presetMiniAppId`（镜像 userProvider.presetProviderId 的继承模式）、`status`（enabled/disabled/pinned）、`url`、logo、`supportedRegions`（CN/Global）、自定义应用含上传 logo 与完整数据。预设来源 `PRESETS_MINI_APPS`（`src/shared/data/presets/miniApps.ts:20-522`，60+ 项，单真源，main/renderer 共用）。

**完整主链**（静态走通）：

```text
侧栏收藏 / Launchpad 点击
  -> openTab(`/app/mini-app/<id>`)（MiniApp.tsx:62-65）
  -> MiniAppPage.tsx：路由 /app/mini-app/$appId
      -> Electron <webview> 加载 app.url（本地 WebviewSearch / MinimalToolbar 工具栏）
      -> openMiniAppKeepAlive 注册进全局 LRU keep-alive 池（MiniAppTabsPool）
      -> 后台标签页保持挂载（React 19 Activity keep-alive），仅活动页驱动 currentMiniAppId
  -> 关闭/隐藏：openedKeepAliveMiniApps 移除；status -> disabled（MiniApp.tsx:109-117）
  -> 持久化：MiniAppService（main/data/services/MiniAppService.ts:101）读写 DB
     （预设行 = 差量覆盖；自定义行 = 全量），seed 由 miniAppSeeder 保持
  -> 区域过滤：supportedRegions 与偏好 miniApps.regionFilter（'auto'|'CN'|'Global'）
  -> 临时小程序：openSmartMiniApp 发布的 transient descriptor 走共享缓存
     （mini_app.transient_descriptor.<appId>，所有窗口可读，不进 DB）
```

**持续性**：预设/自定义/启停/排序落 SQLite（`user_mini_app` 系列行）；keep-alive 池是窗口内内存态，重启后从 DB 重建可见列表；v2 迁移有 `MiniAppMigrator.ts`。行为细节：webview `dom-ready` 后关闭加载遮罩、启动已在侧栏存在的小程序时复用既有标签页而不重复开 tab（`94d34dd0be`、`1cab3af8e6`）。

**安全与资源边界**：webview 由 Electron 管理；小程序数量有缓存偏好（"小程序缓存数量"）；自定义应用 URL 由用户自担风险（本次未发现 URL 协议白名单校验，未验证）。

**独特性判断**：这是把第三方 Web 应用作为一等对象嵌入桌面客户端的门户形态，与 AIO Hub 的"自由窗口"、DeepChat 的 MCP App 沙箱不同：无协议桥、无模型上下文回流，纯 Web 门户 + 标签管理。当前样本中唯一形成完整主链的"应用门户"能力。

**证据强度**：静态源码 + 大量组件测试（MiniApp.test.tsx、MiniAppTabsPool.test.tsx、MiniAppPage.test.tsx）；未运行 webview 实际加载。

### 能力卡 2：全局搜索（跨 Topic/Session 联邦搜索）

**用户目标**：一次性搜索全部会话实体与消息内容，替代逐会话翻找。与 Chat UI 笔记 §2.3 的"会话内 DOM 搜索"是两条不同链路：后者只搜已渲染窗口，前者是数据库级全量搜索。

**入口与触发者**：顶栏搜索按钮（`ShellTabBarActions.tsx:24`）+ 命令 `app.search`（`AppShell.tsx:75-80`）→ `GlobalSearchPopup`。

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

**持续性**：搜索本身无状态（实时查询）；recent items 走共享缓存；消息预览面板按需拉取。

**独特性判断**：联邦实体搜索（含 knowledge-base）+ 双消息源内容搜索 + 游标分页的组合在样本中较完整；与 DeepChat 的 FTS5 跨会话搜索（经 conversationSearchServer 暴露给模型工具与设置页）方向不同——Cherry 是用户产品入口优先。

**证据强度**：静态源码 + 组件测试（GlobalSearchPanel.test.tsx 等 5 个测试文件）；未运行真实查询。

### 能力卡 3：翻译（消息级流式翻译）

**用户目标**：不重发整条消息即可把某条助手回复翻译成目标语言，翻译结果作为消息的一部分持久化。

**完整主链**（静态走通）：

```text
消息操作栏"翻译"（messageMenuBarActions.tsx translateMessage，Home 适配器可写）
  -> IPC ai.translate.open（main/ipc/handlers/translate.ts:12-16）
  -> TranslateService（main/services/translate/translateService.ts:91-183）流式翻译
  -> TranslationBackend（streamManager/persistence/backends/TranslationBackend.ts:25-50）：
     成功时剥离旧 data-translation part 并追加新 part（targetLanguage/sourceLanguage）
  -> 历史：translateHistory 表；内置+自定义语言：translateLanguage 表 + seeder
  -> 渲染：data-translation part 在消息内展示，可再次翻译覆盖
```

**边界**：翻译语言目录、模型选择（走消息原 Provider 还是独立翻译模型）未展开核对；取消即丢弃（"discard-on-cancel"）。

**独特性判断**：把译文作为消息 part 持久化、可重译覆盖的产品形态比"另开窗口翻译"完整，但翻译本身是常见功能，独特性中等——保留为辅助贡献。

## 已归并到现有类目的能力

- **多模型同时对话**：`归并已有类目`。LLM 渠道笔记 §6（`@模型` 解析与并行语义、siblings group、steer/临时聊天只取第一个）与 Chat UI 笔记 §7 已主链确认，本笔记不重写。
- **文档处理**：附件（图片/Office/PDF）、OCR、长文粘贴、知识库检索链分别由会话与消息管理、对话请求与上下文、Agent 工具笔记覆盖；README 的 WebDAV 属外部服务，未在本次范围。
- **Agent workspace**：Chat UI 笔记 §6.2 已确认 agent 消息适配器把相对路径解析到 agent workspace 目录、只读消息、artifact 文件打开与工具审批；Agent 工具笔记覆盖 Claude Code Agent 路径与 MCP 路径。
- **消息级会话内搜索**（DOM 高亮）：Chat UI 笔记 §2.3，与全局搜索区分。

## 声明不符、外部依赖与暂缓项

- README Roadmap 中的 Notes/Canvas/OCR/TTS/插件系统/ASR：属愿景清单，本次未做存在性断言（未检索到对应主链，`暂缓` 由主会话决定是否列入候查）。
- 全局搜索的知识库命中依赖知识库索引（`features/knowledge/query/search.ts`），其索引新鲜度未验证。
- 小程序的实际 webview 加载、区域过滤可用性、keep-alive 内存占用未运行验证。

## 对特色贡献统计的影响

建议进入主贡献：Mini Program（创作/门户面，标签可归"协同工作区"之外的"应用门户"）、全局搜索。辅助贡献：翻译。归并不计数：多模型同时对话、文档处理、Agent workspace、会话内搜索。

## 未验证事项

- 未运行 Electron 应用：webview 加载、GlobalSearch 实际查询结果排序、翻译流式 UI 均为静态确认。
- 小程序 keep-alive 池在大量标签下的资源回收、多窗口（分离窗口/QuickAssistant）间 transient descriptor 同步未验证。
- FTS5 与 trigram 回退在中文分词上的实际效果未实测。
- 翻译的模型选择与语言目录完整读写链未展开。

## 关键源码索引

- 小程序预设：`src/shared/data/presets/miniApps.ts:20-522`
- 小程序数据模型：`src/shared/data/types/miniApp.ts:32-57`
- 小程序页面与池：`src/renderer/pages/miniApps/MiniAppPage.tsx`、`src/renderer/components/MiniApp/MiniApp.tsx`、`MiniAppTabsPool.tsx`
- 小程序服务与 seed：`src/main/data/services/MiniAppService.ts:101-365`、`src/main/data/db/seeding/seeders/miniAppSeeder.ts`
- 全局搜索入口：`src/renderer/components/layout/AppShell.tsx:75-80`、`ShellTabBarActions.tsx:24`
- 全局搜索面板：`src/renderer/components/GlobalSearch/GlobalSearchPanel.tsx`、`useGlobalSearchPanelData.ts:169-415`
- 实体/内容搜索服务：`src/main/data/services/EntitySearchService.ts:40-55`、`ContentSearchService.ts:133-151`
- FTS 与游标：`src/main/data/services/utils/ftsSearch.ts:10-80`、`keysetCursor.ts`
- 翻译：`src/main/services/translate/translateService.ts:91-183`、`src/main/ai/streamManager/persistence/backends/TranslationBackend.ts:25-50`、`src/main/ipc/handlers/translate.ts`

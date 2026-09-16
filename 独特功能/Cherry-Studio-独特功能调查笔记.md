# Cherry Studio 独特功能调查笔记

> 调查对象：`https://github.com/CherryHQ/cherry-studio`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`6534fc9ecefec9c8f58c133de5539ea66bc7567f`（分支：`main`）
>
> 调查方式：只读源码梳理；结合根 README 功能声明与路由/组件盘点；未修改 cherry-studio 仓库
>
> 调查范围：第三批 P2 补查——Mini Program 与全局搜索的入口、执行链和产品表面；多模型同时对话确认现有覆盖；翻译、文档处理、Agent workspace 的覆盖核对
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

| 候选 | 状态 | 依据 |
|---|---|---|
| Mini Program（小程序） | 主链确认 | 预设/自定义网站与可安装 `.miniapp` 本地包、权限与更新治理、keep-alive 池，见能力卡 1 |
| 全局搜索 | 主链确认 | `app.search` 命令 + 联邦实体搜索 + FTS5 内容搜索（游标分页），见能力卡 2 |
| 多模型同时对话 | 归并已有类目 | LLM 渠道笔记 §6 与 Chat UI 笔记 §7 已主链确认（@模型多选 → 并行执行 → 兄弟组展示） |
| 翻译 | 主链确认 | 流式翻译 + `data-translation` part 持久化，见能力卡 3 |
| 文档处理 | 归并已有类目 | 附件/OCR/知识库链在会话与消息管理、对话请求与上下文笔记覆盖 |
| Agent workspace | 归并已有类目 | Chat UI 笔记 §6.2（agent 适配器的工作区文件解析、artifact 面板）与 Agent 工具笔记覆盖 |

README（`README.md:80-116`）"Practical Tools Integration" 中的 Global Search、Mini Program、AI-powered Translation、Multi-model Simultaneous Conversations 全部与代码相符。本次补查重点是确认两个缺口项（Mini Program、全局搜索）的主链，均已走通（静态证据）。

## 介绍声明与候选盘点

README 关键特色：300+ 预配置助手、多模型同时对话、文档与数据处理（Office/PDF、WebDAV）、全局搜索、Topic 管理、AI 翻译、拖拽排序、Mini Program 支持、MCP。Roadmap 中的 Notes/Canvas/OCR/TTS/插件系统等仍在愿景清单（`README.md:118-153`），本次未在代码中做存在性断言。

## 已确认的独特能力

### 能力卡 1：Mini Program（网站门户与本地应用包）

**用户目标**：在客户端内以独立标签页运行第三方网站与本地打包应用，与聊天工作区并列使用。网站型小程序提供 Web 门户；`.miniapp` 包则把 manifest、资源、权限和版本一起安装到受管运行环境。

**入口与触发者**：侧栏小程序分区（sidebarVariants.tsx 的 miniAppVariant + 收藏）、Launchpad（`MiniApp.tsx` 的 launchpad 变体）、设置页"小程序"面板。触发者始终是用户点击。

**事实对象**：MiniApp 行继续承载预设或自定义网站；安装型应用另有 installation 记录，保存版本、manifest、AI 模型绑定与包身份。`kind='app'` 的对象身份由包决定，普通编辑只能改状态与排序，不能把 URL 改出沙箱；见 `src/shared/data/types/miniApp.ts:68`、`src/main/data/services/MiniAppService.ts:56-57,87-138,275`。

**完整主链**（静态走通）：

```text
侧栏收藏 / Launchpad 点击
  -> openTab(`/app/mini-app/<id>`)（MiniApp.tsx:62-65）
  -> MiniAppPage.tsx：路由 /app/mini-app/$appId
      -> Electron <webview> 加载 app.url（本地 WebviewSearch / MinimalToolbar 工具栏）
      -> openMiniAppKeepAlive 注册进全局 LRU keep-alive 池（MiniAppTabsPool）
      -> 后台标签页保持挂载（React 19 Activity keep-alive），仅活动页驱动 currentMiniAppId
  -> 关闭/隐藏：openedKeepAliveMiniApps 移除；status -> disabled（MiniApp.tsx:109-117）
  -> 持久化：MiniAppService 读写 DB
     （预设行 = 差量覆盖；网站 = 全量；安装应用 = 行 + installation/manifest）
  -> 区域过滤：supportedRegions 与偏好 miniApps.regionFilter（'auto'|'CN'|'Global'）
  -> 临时小程序：openSmartMiniApp 发布的 transient descriptor 走共享缓存
     （mini_app.transient_descriptor.<appId>，所有窗口可读，不进 DB）
  -> 本地包：文件拖入或 https manifest URL -> 安装预览 -> 用户勾选可选权限
     -> 独立 partition/origin + grants -> 运行 -> 更新审查 -> 替换或卸载
```

**持续性**：预设、自定义网站、安装记录、权限授予、启停和排序落 SQLite；包资源由安装器管理，keep-alive 池仍是窗口内内存态。安装 UI 接受单个 `.miniapp` 文件或 https manifest，先展示描述、网络主机和权限清单；更新增加权限时必须再次确认，权限撤销与活动记录可在详情面板查看。依据：`src/renderer/pages/miniApps/InstallMiniAppPanel.tsx:36-84`、`components/MiniApp/InstallConsentDialog.tsx:149-172`、`MiniAppDetailPanel.tsx:381-418,549-560`。

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
  -> IPC ai.translate.open（main/ipc/handlers/translate.ts:12-16）
  -> TranslateService（main/services/translate/translateService.ts:91-183）流式翻译
  -> TranslationBackend（streamManager/persistence/backends/TranslationBackend.ts:25-50）：
     成功时剥离旧 data-translation part 并追加新 part（targetLanguage/sourceLanguage）
  -> 历史：translateHistory 表；内置+自定义语言：translateLanguage 表 + seeder
  -> 渲染：data-translation part 在消息内展示，可再次翻译覆盖
```

**边界**：翻译语言目录、模型选择（走消息原 Provider 还是独立翻译模型）未展开核对；取消即丢弃（discard-on-cancel）。

**独特性判断**：把译文作为消息 part 持久化、可重译覆盖的产品形态比"另开窗口翻译"完整，但翻译本身是常见功能，保留为辅助贡献。

## 当前候选补充

PDF 翻译已形成“选择文档 -> BabelDOC 保版式翻译 -> 写入翻译历史与文件管理器 -> 资源下载进度反馈”的专用主链，可作为创作工作站能力族下的 `主链确认` 候选；它与普通对话导出不同，产物是可管理的翻译文件。交互式截图带标注与 OCR 也已确认入口和输入回流，但本次尚未追到 OCR 结果在全部聊天/Agent 表面的持久化语义，维持 `入口确认`。

这两项的媒体处理细节归入媒体创作笔记，不重复计入普通 Agent 工具或消息渲染能力。依据：`src/main/services/PdfTranslationService.ts`、`src/renderer/pages/translate/pdf/PdfTranslationView.tsx`、`src/main/services/screenshot/ScreenshotOverlayService.ts`。

## 已归并到现有类目的能力

- **多模型同时对话**：归并已有类目。LLM 渠道笔记 §6（@模型解析与并行语义、siblings group、steer/临时聊天只取第一个）与 Chat UI 笔记 §7 已主链确认，本笔记不重写。
- **文档处理**：附件（图片/Office/PDF）、OCR、长文粘贴、知识库检索链分别由会话与消息管理、对话请求与上下文、Agent 工具笔记覆盖；README 的 WebDAV 属外部服务，未在本次范围。
- **Agent workspace**：Chat UI 笔记 §6.2 已确认 agent 消息适配器把相对路径解析到 agent workspace 目录、只读消息、artifact 文件打开与工具审批；Agent 工具笔记覆盖 Claude Code Agent 路径与 MCP 路径。
- **消息级会话内搜索**（DOM 高亮）：Chat UI 笔记 §2.3，与全局搜索区分。

## 声明不符、外部依赖与暂缓项

- README Roadmap 中的 Notes/Canvas/OCR/TTS/插件系统/ASR：属愿景清单，本次未做存在性断言（未检索到对应主链，暂缓由主会话决定是否列入候查）。
- 全局搜索的知识库命中依赖知识库索引（`features/knowledge/query/search.ts`），其索引新鲜度未验证。
- 小程序的实际 webview 加载、区域过滤可用性、keep-alive 内存占用未运行验证。

## 对特色贡献统计的影响

建议进入主贡献：Mini Program（创作/门户面，标签可归"协同工作区"之外的"应用门户"）、全局搜索。辅助贡献：翻译。归并不计数：多模型同时对话、文档处理、Agent workspace、会话内搜索。

## 未验证事项

- 未运行 Electron 应用：webview 加载、GlobalSearch 实际查询结果排序、翻译流式 UI 均为静态确认。
- 小程序 keep-alive 池在大量标签下的资源回收、多窗口间 transient descriptor 同步，以及安装包权限、网络 allowlist、升级和卸载后的运行效果未验证。
- FTS5 与 trigram 回退在中文分词上的实际效果未实测。
- 翻译的模型选择与语言目录完整读写链未展开。

## 关键源码索引

- 小程序预设：`src/shared/data/presets/miniApps.ts:20-522`
- 小程序数据模型：`src/shared/data/types/miniApp.ts:32-57`
- 小程序页面与池：`src/renderer/pages/miniApps/MiniAppPage.tsx`、`src/renderer/components/MiniApp/MiniApp.tsx`、`MiniAppTabsPool.tsx`
- 小程序服务与 seed：`src/main/data/services/MiniAppService.ts:101-365`、`src/main/data/db/seeding/seeders/miniAppSeeder.ts`
- 小程序安装与权限：`src/renderer/pages/miniApps/InstallMiniAppPanel.tsx`、`src/renderer/components/MiniApp/{InstallConsentDialog,PermissionChecklist,MiniAppDetailPanel,UpdateReviewDialog}.tsx`
- 全局搜索入口：`src/renderer/components/layout/AppShell.tsx:75-80`、`ShellTabBarActions.tsx:24`
- 全局搜索面板：`src/renderer/components/GlobalSearch/GlobalSearchPanel.tsx`、`useGlobalSearchPanelData.ts:169-415`
- 实体/内容搜索服务：`src/main/data/services/EntitySearchService.ts:40-55`、`ContentSearchService.ts:133-151`
- FTS 与游标：`src/main/data/services/utils/ftsSearch.ts:10-80`、`keysetCursor.ts`
- 翻译：`src/main/services/translate/translateService.ts:91-183`、`src/main/ai/streamManager/persistence/backends/TranslationBackend.ts:25-50`、`src/main/ipc/handlers/translate.ts`

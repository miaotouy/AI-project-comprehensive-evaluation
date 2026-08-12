# DeepChat 独特功能调查笔记

> 调查对象：`E:\works\git\deepchat`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`dc4177c2ac80905ebac985554a9f957aaca31ab8`（分支：`dev`）
>
> 调查方式：只读源码梳理；结合根 README 功能声明、CHANGELOG 近期条目与 `src/main/` 各子系统入口核对；未修改 DeepChat 仓库
>
> 调查范围：第三批 P2 补查——IM 远程控制、Ollama 管理、DeepLink 是否形成产品主链；Tape/Trace、Skill 跨工具迁移、ACP 作为模型、搜索助手的已有证据复核；明确排除普通 Chat 底座与已被现有十类笔记完整覆盖的机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的七个候选全部有实际实现，其中六项达到 `主链确认`（静态证据），一项归并已有类目：

| 候选 | 状态 | 依据 |
|---|---|---|
| IM 远程控制 | `主链确认` | `src/main/remote/` 完整子系统，5 个 IM 渠道 + 会话绑定 + 命令路由 + 投递服务，见能力卡 1 |
| Tape & Trace | `主链确认` | `src/main/tape/` 分层子系统 + TraceDialog 界面 + tape 工具，见能力卡 2 |
| Skill 跨工具迁移 | `主链确认` | `src/main/skill/sync/adapters/` 11+ 工具适配器 + 格式转换器，见能力卡 3 |
| 搜索助手（web 搜索） | `主链确认`（web 搜索链）/ `声明不符`（"自定义搜索助手模型"） | bocha/brave/deepResearch 内存 MCP + YoBrowser 浏览工具；README 声称的可配置自定义搜索引擎 UI 本次未找到消费方，见能力卡 4 |
| Ollama 管理 | `主链确认` | OllamaManager + 专用设置页（下载/刷新/运行模型），见能力卡 5 |
| DeepLink | `主链确认` | `deepchat://` 协议三命令（start / mcp / provider），见能力卡 6 |
| ACP 作为模型 | `归并已有类目` | 已在 Agent 角色笔记 §3 与 LLM 渠道笔记 §2 主链确认，见"已归并"节 |

结论：README 的 "Why Choose DeepChat" 清单与代码基本一致；"Remote-Ready Workflows"、"Tape.systems Philosophy"、"Skills That Travel"、"Integrated Ollama with comprehensive management"、"Rich DeepLink Support" 均有可走通的主链。README 中"配置一个搜索助手模型连接任意搜索源"的表述与当前可执行路径不符（见能力卡 4 边界）。

## 介绍声明与候选盘点

README 主要特色（`README.md:76-84`、`:91-128`）：Local-First Agent、Tape.systems 哲学、Skills That Travel（跨工具迁移）、Native ACP Integration、Strong MCP、Remote-Ready Workflows、统一多模型管理（含 Ollama 管理）、DeepLink、安全与隐私。CHANGELOG 近期条目密集出现 remote control（Telegram/Feishu/Weixin/Discord/QQBot/WeChat iLink）、`/agent` 远程命令、Tape view manifest/replay lineage、session tape memory、Feishu plugin 设置面，与代码目录吻合。

## 已确认的独特能力

### 能力卡 1：IM 远程控制（多表面连续性）

**用户目标**：离开桌面后通过聊天软件继续控制 DeepChat 会话——这是普通 Chat 客户端无法提供的"远程驾驶"面，且与 AstrBot 的"机器人入站"方向相反（DeepChat 是桌面客户端被 IM 遥控）。

**入口与触发者**：`Settings → Remote`（`src/renderer/settings/components/RemoteSettings.vue`），五个渠道分 tab：Telegram、Feishu/Lark、QQBot、Discord、WeChat iLink。触发者始终是 IM 平台的外部消息/回调事件。

**事实对象**：`RemoteEndpointBinding`（endpoint = 渠道私有聊天/群标识），绑定到一个 DeepChat session；PairCode 授权（TTL 10 分钟，失败上限 5，`src/main/remote/types.ts:33-37`）。

**完整主链**（静态走通）：

```text
IM 入站（telegramPoller / discordGatewaySession / feishuClient / qqbotGatewaySession / weixinIlinkClient）
  -> RemoteCommandRouter.handleMessage（conversation/commandRouter.ts:66）
      -> authGuard.ensureAuthorized（pair code / 白名单）
      -> /start /help /pair /new /sessions /use /stop /open /pending /model /status /agent
  -> RemoteConversationRunner（runner.ts:441-799）
      -> ensureBoundSession / sendInput -> 会话执行（复用桌面 session runtime）
      -> stop / open（桌面开窗）/ getPendingInteraction + respondToPendingInteraction（答复 question/权限）
  -> conversation/blockRenderer.ts 把 assistant blocks 渲染为文本（含 trace/draft/final 形态）
  -> RemoteDelivery（delivery/service.ts）按渠道出站（Telegram 轮询发送、Feishu 卡片等）
```

**持续性**：绑定关系持久化在 `remote/binding/store.ts`（settings store）；运行时（poller/gateway 会话）在 `runtime/manager.ts` 管理，启动重建。Feishu 渠道另有 `plugins/feishu/` 插件（隔离设置面、MCP 预设、流式卡片投递，CHANGELOG 与 `plugins/feishu/` 目录一致）。

**主动性**：远程侧可 `/stop` 中止生成；可 `/pending` 查看并答复挂起交互；`/open` 把会话带桌面。定时任务（CronJobs）支持"remote delivery"目标（`CronJobsSettings.vue` 的 remoteDelivery 配置），即计划任务结果可投递到已绑定 IM 端点——远端不是只读终端。

**外部依赖与执行域**：所有执行仍在本机 DeepChat 主进程；渠道凭证（bot token / app secret）存于本地 settings；Feishu/Weixin 需要各自的平台应用注册，属于外部服务依赖。

**独特性判断**：与 AstrBot 的"IM 机器人平台"不同，DeepChat 的远程控制是把现有桌面会话（含 pending interaction、权限审批、模型切换）投影到 IM，桌面与远端共享同一会话事实源；与 VCPChat 的 VCPDesktop 推送是"出站投影"，这里默认是"入站控制 + 出站投递"双工。属于"多表面连续性"标签的稀有能力。

**证据强度**：全部静态源码确认；未运行真实 IM 平台回调（未验证事项见文末）。

### 能力卡 2：Tape & Trace（研究轨迹）

**用户目标**：长任务可恢复、可审计、可回放的工作历史。README 称之为 Tape.systems 哲学（`README.md:139-141`）。

**事实对象**：Tape 是一个结构化记录系统，核心对象是 Tape entry（用户消息、工具调用、provider attempt 等事实）与 view manifest（一次请求的"视图快照"）。模块是完整 DDD 分层：`src/main/tape/domain/`（entry、facts、providerAttempt、replay、viewManifest、effectiveSemantics）、`application/`（sessionTape、factService、recallService、lineageService、viewReplayService、reconcilerService、forkService、generationLifecycle）、`infrastructure/sqlite/`（tapeEntryStore、tapeSearchProjectionStore、tapeLifecycleAdapter）。

**完整主链**（静态走通）：

```text
消息结算（transcript.ts 完成/错误路径，同步写 Tape facts）
  -> TapeFactService.appendToolFact / factPersistence.appendMessageRecordToTape
  -> SessionTape（入口，sessionTape.ts:81）
  -> 视图：view manifest（确定性 hash + lineage，viewReplayService.ts:188）
  -> 用户入口：消息菜单 -> TraceDialog.vue（request / view / entries / budget 四 tab，
     展示 requestSeq、provider/model、endpoint、headers/body、manifest 完整性、
     包含/排除条目、token 预算）
  -> 模型入口：tape_search / tape_context 工具（agentTapeTools.ts:21-110，
     支持 linked scopes = 已 finalize 的直接子 Agent tape）
  -> 跨会话召回：tapeSearchProjectionStore（FTS 投影）+ recallService
```

**持续性**：Tape entries 与 view manifests 落 SQLite；重启后可审计回放。subagent 有显式 tape lineage（lineageService.ts:313），README 与 CHANGELOG 的 "replay lineage" 描述一致。

**边界**：本次未验证 Tape 与 compaction（压缩后 entry 保留策略）的交互、FTS 投影的更新时序；Tape view 的确定性 hash 具体算法未逐行核对。

**独特性判断**：这是把"请求轨迹 + 会话事实 + 审计视图"做成持久化对象的机制，区别于 Open WebUI 的对话回放和 Hermes Agent 的研究轨迹（后两者未调查可比对象）。标签：`研究轨迹`。

### 能力卡 3：Skill 跨工具迁移（自进化 Skill 生态的传输面）

**用户目标**：把 Skill 在 Claude Code / Codex / Cursor / Windsurf / GitHub Copilot / OpenCode / Goose / Kilo Code / Kiro / Antigravity / Agents 等工具之间迁移，复用领域技能。

**完整主链**（静态走通）：

```text
设置入口 Settings -> Skills（README.md:151-155；renderer/settings）
  -> 安装：文件夹 / ZIP / URL / 拖放（SkillService，skill/index.ts）
  -> 导入/导出：sync/formatConverter.ts 做格式归一；adapters/ 下 11+ 个工具适配器
     （claudeCode / codex / cursor / windsurf / copilot / openCode / goose /
      kiloCode / kiro / antigravity / agents）
  -> sync/toolScanner.ts + security.ts（文件名/路径安全校验）
  -> 会话级激活：activeSkillNames 进入工具目录（Agent 工具笔记 §1）
  -> 执行：skill_run 工具（Agent 工具笔记 §6）
```

**边界**：适配器的双向性（导入 vs 导出）未逐一核对；格式转换的兼容面（如 Claude Code 的 SKILL.md frontmatter 变体）未运行验证。

**独特性判断**：跨工具 Skill 格式迁移是明确的独特产品面（"Skills That Travel"），与 Hermes Agent 的"从经验生成 Skill"（自进化）是同一生态的两个方向：前者是迁移，后者是生成。标签：`自进化 Skill` 的传输子面。

### 能力卡 4：搜索助手（web 搜索链 + 深度研究）

**用户目标**：让模型自主联网搜索，并高亮信息来源。README 声明三块：内置搜索 API（BoSearch/Brave）、模拟浏览器读搜索引擎、"配置搜索助手模型连接任意搜索源"（`README.md:115-118`）。

**完整主链**（静态走通，web 搜索部分）：

```text
内置内存 MCP 服务器（mcp/settings.ts:130-151，DEFAULT_ENABLED 由会话装配）
  -> bochaSearchServer（bocha_web_search）/ braveSearchServer（brave_web_search）
  -> deepResearchServer（start_deep_research -> execute_single_web_search ->
     request_research_data -> submit_reflection_results -> generate_final_answer，
     反思式增量迭代，基于 deep-research-mcp 改 Bocha 与内容提取）
  -> 浏览器面：YoBrowser 工具（tool 目录 server 名 "yobrowser"，
     desktop/browser/YoBrowserPresenter.ts），模拟真人浏览搜索引擎
  -> 结果投影：assistant block type: 'search'（dispatch.ts:461-476，
     含 engine/provider 归属与 favicon 页面），渲染层按来源高亮
  -> 自有会话搜索（conversationSearchServer，FTS5）：归并已有类目
     （会话与消息管理笔记 §2/§5.3，Chat UI 笔记 §2）
```

**声明不符项**：README"配置一个搜索助手模型连接各种搜索源（内网、无 API 引擎、垂直搜索引擎）"对应 i18n 键 `searchEngineName/searchEngineUrl`（`src/types/i18n.d.ts:2182-2186`），但全文检索（`src/` 内 .ts/.tsx/.vue）无任何消费方——本次判定为遗留声明/未接线配置，当前可执行路径以 Bocha/Brave/DeepResearch + YoBrowser 为准。

### 能力卡 5：Ollama 管理

**用户目标**：不离开 DeepChat 完成本地模型下载、部署、运行管理（README：`README.md:105-107`）。

**完整主链**（静态走通）：

```text
OllamaProviderSettingsDetail.vue（apiType==='ollama' 时嵌入 ModelProviderSettings）
  -> ollamaStore（pull / refresh / runningModels 状态）
  -> ProviderService 路由 -> OllamaManager（provider/managers/ollamaManager.ts:12-81）
      -> OllamaProvider（ollama SDK：listModels / listRunningModels / showModelInfo / pullModel）
  -> pull 进度经 providers.ollama.pull.progress 事件回渲染层（:68-79）
```

**边界**：下载进度事件、并发 pull、Ollama 服务未运行时的 UI 行为未运行验证；`pullOllamaModels` 返回 boolean 但进度另走事件通道。

### 能力卡 6：DeepLink

**用户目标**：通过 `deepchat://` 协议从外部应用发起会话、一键安装 MCP 服务、导入 Provider。

**完整主链**（静态走通）：

```text
app.setAsDefaultProtocolClient('deepchat')（deeplink/index.ts:66-83）
  -> DeeplinkService.handleDeepLink（:108-153）：deepchat://start | mcp/install | provider/install
  -> start：msg（净化）/ model / agent 参数开新会话（:155-211）
  -> mcp/install：JSON 配置解析、env 校验，MCP 未就绪时挂起待启动后处理（:212-357）
  -> provider/install：payload 校验 + 预览 + 写入（:358-510）
  -> 安全：粘贴内容危险模式扫描（script/iframe/javascript:/on*=，:666-693，
     生成式输出笔记 §1 已引用）
```

**边界**：URL 协议注册的平台差异（Windows/macOS/Linux）未运行验证；`deepchat://` 参数经 URL 传递的凭据暴露面由调用方承担。

## 已归并到现有类目的能力

- **ACP 作为模型**：`归并已有类目`。Agent 角色笔记 §3（`agentManager.ts:54-118` 的 kind 分派）、LLM 渠道笔记 §2（`apiType: acp` 与 ACP backend 的边界）均已主链确认：ACP Agent 作为模型选择器一等条目、ACP-backed subagent 空工具目录、ACP workspace UI。本笔记不再重写。
- **会话内/跨会话搜索**（自有数据搜索）：归并会话与消息管理笔记 §5 与 Chat UI 笔记 §2（`useChatSearch` + FTS5 + conversationSearchServer）。
- **Artifact / MCP App 沙箱 / 本机 exec**：归并生成式输出与运行时笔记（主链确认 G3）。
- **cron 定时任务**：CHANGELOG 提及"定时任务 + 远程 /agent 命令"；cron 本体属 Agent 工具笔记边界，其 remote delivery 已在能力卡 1 记录交点，不重复展开。

## 声明不符、外部依赖与暂缓项

- "配置搜索助手模型连接任意搜索源"：`声明不符`（见能力卡 4）。
- Feishu 渠道的安装与鉴权依赖飞书开放平台应用；Weixin iLink 依赖企业微信接口；Telegram/QQBot/Discord 依赖各自 bot 平台——均为外部服务依赖，主链执行需真实凭证（`暂缓` 运行验证）。
- `useArtifactExport`（导出按钮）未接线（生成式输出笔记 §11）与 Tape 无关，不重复。

## 对特色贡献统计的影响

建议进入主贡献（`主链确认`，静态证据）：IM 远程控制（多表面连续性）、Tape & Trace（研究轨迹）、Skills 跨工具迁移（Skill 生态传输）。辅助贡献：Ollama 管理、DeepLink、web 搜索/深度研究链。归并不计数：ACP 作为模型、自有会话搜索、Artifact。

## 未验证事项

- 未运行任何 IM 平台真实回调/凭证；远程控制的端到端时序（流式回复在 IM 上的分段、交互回调 TTL、Feishu 卡片轮询）为静态推断。
- Tape：压缩与 Tape 的交互、FTS 投影时序、manifest hash 算法未逐行核对。
- Skill 适配器双向导入导出的兼容面未逐一验证。
- Ollama pull 进度事件与并发下载的运行时行为未实测。
- DeepLink 在三种平台的协议注册与 MCP 未就绪排队恢复未实测。
- 未运行构建、测试或应用本体；证据全部来自当前快照静态源码。

## 关键源码索引

- 远程控制入口与命令：`src/main/remote/index.ts:216-335`、`src/main/remote/conversation/commandRouter.ts:63-1078`、`src/main/remote/conversation/runner.ts:441-799`
- 远程绑定与运行时：`src/main/remote/binding/store.ts`、`src/main/remote/runtime/manager.ts`、`src/main/remote/types.ts:58-260`（命令清单）
- 远程文本渲染与投递：`src/main/remote/conversation/blockRenderer.ts:208-485`、`src/main/remote/delivery/service.ts`
- 远程设置面：`src/renderer/settings/components/RemoteSettings.vue`、`CronJobsSettings.vue`（remote delivery）
- Feishu 插件：`plugins/feishu/`（plugin.json / skills / mcp / settings）
- Tape：`src/main/tape/application/{sessionTape,factService,recallService,lineageService,viewReplayService,reconcilerService}.ts`、`src/main/tape/infrastructure/sqlite/tapeEntryStore.ts`
- Tape UI：`src/renderer/src/components/trace/TraceDialog.vue`（:377-550 四 tab 数据）
- Tape 工具：`src/main/tool/agentTools/agentTapeTools.ts:21-110`
- Skill 同步：`src/main/skill/sync/formatConverter.ts`、`src/main/skill/sync/adapters/`、`src/main/skill/agentSkillImportService.ts`
- 搜索：`src/main/mcp/inMemoryServers/{bochaSearchServer,braveSearchServer,deepResearchServer}.ts`、`src/main/mcp/settings.ts:130-151`、`src/main/desktop/browser/YoBrowserPresenter.ts`、`src/main/agent/deepchat/runtime/dispatch.ts:461-476`
- Ollama：`src/main/provider/managers/ollamaManager.ts:12-81`、`src/renderer/settings/components/OllamaProviderSettingsDetail.vue`
- DeepLink：`src/main/deeplink/index.ts:56-510`、`:666-693`（净化）

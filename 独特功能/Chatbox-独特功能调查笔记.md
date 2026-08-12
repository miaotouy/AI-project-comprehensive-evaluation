# Chatbox 独特功能调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：产品表面盘点（路由、设置菜单、feature flag、依赖）+ 只读源码核对 README 未列出的能力；未修改 chatbox 仓库
>
> 调查范围：第三批 P3/P2 补查——README 过时情况下的产品表面盘点；团队 API 资源共享、图像生成、提示词库；README 未列出的 Agent/MCP/Skills/Artifact 能力标注证据状态
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 根 README（`README.md:147-217`）明显落后于当前代码：仍以 ChatGLM-6B/llama2/Mixtral 等旧模型、DALL-E-3、简单 Prompt 库为卖点，未列出 MCP、Skills、知识库、Agent Mode、沙箱代码执行、Image Creator、Copilots、Web Search、Document Parser 等已实现能力。产品表面盘点显示这些能力均以路由/设置项/feature flag 存在，且大部分已被现有十类笔记覆盖。

| 候选 | 状态 | 依据 |
|---|---|---|
| 团队 API 资源共享 | `入口确认` | `team-sharing/` 伴生部署（Caddy 反代注入 Key）+ 客户端标准自定义 Provider 用法，见能力卡 1 |
| 图像生成（Image Creator） | `主链确认` | `/image-creator/` 独立工作台 + 记录/图片持久化 + 参考图 DAG，见能力卡 2 |
| 提示词库（Copilots） | `主链确认`（本地部分） | `/copilots/` 本地自建/收藏 + 远端系统 Copilot，见能力卡 3 |
| Agent Mode / 沙箱代码执行 | `归并已有类目` | 生成式输出与运行时笔记已主链确认（G3 可执行 Artifact） |
| MCP / Skills | `归并已有类目` | Agent 工具笔记已主链确认（工具集构建、install_skill 链、skills:execute-script IPC） |
| 知识库 / Web Search / Document Parser | `归并已有类目` | 会话与消息管理、对话请求与上下文、消息渲染笔记覆盖；Web Search 服务（searxng 等 provider）在 `src/main/services/webSearch/` |

README 的 "Team Collaboration"（`README.md:188-190`，链接 `team-sharing/README.md`）、"Image Generation with Dall-E-3"、"Prompt Library & Message Quoting" 三项声明与代码存在性一致；"Prompt Library" 的当代形态是 Copilots（不再叫提示词库）。

## 产品表面盘点（README 未列出的能力清单）

以路由与设置菜单为准（`src/renderer/routes/`、`settings/route.tsx:31-110`）：

| 表面 | 路由/入口 | feature flag | 现有笔记覆盖 |
|---|---|---|---|
| MCP | `settings/mcp.tsx` | `mcp: platform==='desktop'`（feature-flags.ts:4） | Agent 工具笔记 |
| 知识库 | `settings/knowledge-base.tsx` | `knowledgeBase: desktop` | 会话与消息管理/上下文笔记 |
| Skills | `settings/skills.tsx` + `src/main/skills/`（installer、github-fetcher、builtin 4 个） | `skills: desktop` | Agent 工具笔记 |
| Agent Mode | InputBox `AgentModeButton/Panel`（on/auto/off、approval/full_access、工作目录授权） | 无 flag，模型 capability 门控 | Agent 工具、生成式输出笔记 |
| 沙箱代码执行 | `src/main/sandbox/`（manager 1471 行、preview-server、persist-artifact） | desktop 生效 | 生成式输出笔记 |
| 图像生成 | `/image-creator/` | 无 | 本笔记能力卡 2 |
| Copilots | `/copilots/{index,my,featured,search}` | 无 | 本笔记能力卡 3 |
| Web Search | `settings/web-search.tsx`（searxng 等 provider） | 无 | 上下文笔记（webBrowsing 开关） |
| Document Parser | `settings/document-parser.tsx` | 无 | 附件/OCR 链 |
| 新用户引导 | `/guide/`（UserTypeCards、ClaimWaitingCard） | 无 | 未调查 |
| Chatbox AI 账号 | `settings/chatbox-ai.tsx`（登录、license、模型管理） | 无 | LLM 渠道笔记（chatbox-ai Provider） |

## 已确认的独特能力

### 能力卡 1：团队 API 资源共享

**用户目标**：团队成员共享同一个 OpenAI API 账户额度，且不泄露 API Key。README 的 Collaboration 板块专门宣传（`README.md:188-190`）。

**入口与触发者**：部署端在仓库内 `team-sharing/`（Caddyfile、Dockerfile、main.sh）；使用端是 Chatbox 的标准自定义 Provider——成员把共享服务器地址填入 API Host 且不填 Key。

**主链**（静态走通，部署配置级）：

```text
部署：docker run -e KEY=<team_key> -e HOST=<domain> bensdocker/chatbox-team
  -> main.sh 用 sed 把 <HOST>/<KEY> 注入 Caddyfile（team-sharing/main.sh:8-12）
  -> Caddyfile：reverse_proxy https://api.openai.com，
     header_up Authorization "Bearer <KEY>"（team-sharing/Caddyfile:2-5）
成员端：设置 -> 自定义 Provider（OpenAI Compatible）-> API Host = 共享地址
  -> 请求经反代注入团队 Key，客户端不接触 Key（LLM 渠道笔记 §1-3 的标准 Host 覆盖路径）
```

**边界**：代理面是明文的 Bearer 注入（HTTPS 传输加密但不做二次鉴权）；无用量/配额面板；属于"伴生部署 + 客户端既有能力"的组合。README 声称"without exposing your API KEY"，成立的前提是成员信任部署方。

**独特性判断**：团队共享是常见需求，但把方案以仓库内可复现部署（Caddy 反代）交付、且与客户端"免 Key 自定义 Host"直接配合，是当前样本中唯一成型的团队资源共享面。证据强度：部署配置静态确认；未运行部署。

### 能力卡 2：图像生成工作台（Image Creator）

**用户目标**：独立于聊天的图像创作工作台：模型选择、宽高比、参考图、历史记录与重新生成。

**完整主链**（静态走通）：

```text
侧栏/首页入口 -> /image-creator/（routes/image-creator/index.tsx）
  -> 模型分组 useImageModelGroups（按 provider 分组的 image 类型模型，
     DALL-E 等；chatboxai 定义含 callImageGeneration，definitions/models/chatboxai.ts:350-359）
  -> 参考图：本地上传 -> storage blob（StorageKeyGenerator.picture('image-creator-ref')），
     生成时 base64 进请求；记录间参考图保留来源 record id（DAG 语义，index.tsx:377）
  -> createAndGenerate（stores/imageGenerationActions.ts:190-372）
      -> 记录落 ImageGenerationStorage；产物图片写 blob（image-gen:<recordId>）
      -> cancelGeneration / resumeGeneration / retryGeneration
  -> 结果：GeneratedImagesGallery（全屏查看、导出）、HistoryPanel（按记录列出 prompt/模型/时间）
  -> 错误面：ImageGenerationErrorTips（内容审核拦截 image_content_moderation_blocked、
     升级引导等）
```

**持续性**：ImageGeneration 记录（prompt/model/status/图片键）与图片 blob 均持久化；历史可恢复、可再次生成。

**图像模型目录规则与记录来源**：

- 图像模型目录规则：OpenAI 走 OAuth 认证时（`isUsingOAuth`）不注入 OpenAI 组的 image 模型（`image-model-catalog.ts` 的 `isOpenAIImageGenerationAuthSupported`，`15028964`），避免 OAuth 会话无法走 DALL-E 计费路径。
- 记录含 `source` 字段：chatbox_cli 触发的图片生成记录记住 `{ sessionId, toolCallId }` 来源（`shared/types/image-generation.ts`），任务完成后经 `image-task-follow-up.ts` 把完成/失败结果以后台任务通知回填进原聊天会话，并支持从聊天内"恢复"该记录（`ecec96bd`，`SQLiteImageGenerationStorage`/`imageGenerationActions`）。这条链横跨 Agent 工具笔记 §11 的后台任务回填与消息渲染器笔记的工具卡。

**独特性判断**：独立的图像工作台 + 记录持久化 + 参考图 DAG，是"创作工作站"标签的完整实现之一（与 AIO Hub 媒体工作站的比较待横向调查）；在纯聊天客户端中罕见。README 只提 DALL-E-3 一句，实际产品面更完整。

**证据强度**：静态源码 + 组件/action 测试；未运行真实生成（计费操作）。

### 能力卡 3：Copilots（提示词库的当代形态）

**用户目标**：把常用提示词/角色预设做成可管理、可搜索、可从聊天中直接调用的 Copilot（含头像、标签、描述、prompt），并可收藏星标。

**完整主链**（静态走通，本地部分）：

```text
/copilots/（index 我的+推荐 / my 全量 / featured 官方精选 / search 搜索）
  -> useMyCopilots（本地存储，starred 排序）+
     useRemoteCopilotsByCursor（远端系统 Copilot，packages/remote.ts:178-220：
     /api/system_copilots/{list,tags,record_usage}、share-record）
  -> CopilotSettingsModal：创建/编辑（名称、头像、背景、描述、prompt、标签、验证）
  -> 新会话入口：ChatboxWelcomeCard / 首页把选中 Copilot 的 prompt 注入新会话（routes/index.tsx:227）
  -> CopilotDetailModal：查看、本地编辑、远端添加、直接使用
```

**边界**：远端精选依赖 Chatbox 后端（`getAPIOrigin()`），属于外部服务；本地部分（自建/收藏/星标）完全在仓库内。

**独特性判断**：本地 + 云混合的预设市场在样本中并不独特（LobeHub Agent Market 同型），但 README 的"Prompt Library"已演进为 Copilots 产品面，值得在横向比较中按"预设市场/提示词库"聚类对齐命名。

## 已归并到现有类目的能力（README 未列出部分）

- **Agent Mode / 沙箱代码执行 / create_download 产物 / HTML artifact 预览**：生成式输出与运行时笔记（快照即当前 HEAD `f90fc31a`）已主链确认：`agentMode('on')` 门控、`src/main/sandbox` 执行、`persistSandboxArtifact` 持久化、`DownloadArtifactsUI`、VibeDrop 网页发布。本次不再重写。
- **MCP / Skills**：Agent 工具笔记已主链确认（`buildToolsForSession` 工具集、`install_skill` 链、`skills:execute-script` IPC、MCP 审批面）。本次补两点产品表面：MCP 与 Skills 均以 desktop-only feature flag 存在（`feature-flags.ts:4-6`）；内置 Skills 为 chatbox-product-info / data-analysis / frontend-design / vibedrop 四个（`src/main/skills/builtin/index.ts`）。
- **知识库 / 附件 RAG / Web Search / Document Parser**：会话与消息管理、对话请求与上下文笔记覆盖；`session-attachment-rag` 模块与 `webSearch` 服务本次只记录存在。

## 声明不符、外部依赖与暂缓项

- README 模型清单（ChatGLM-6B、llama2、Mixtral、vicuna）与当前 Provider 注册表（24 个，LLM 渠道笔记 §1.1）不符——属文档过时，以代码为准。
- Copilots 的"官方精选/搜索"依赖 Chatbox 后端 API，离线不可用（`暂缓` 运行验证）。
- 图像生成涉及计费操作，未运行真实生成；team-sharing 部署未实际拉起 Docker。

## 对特色贡献统计的影响

建议进入主贡献：图像生成工作台（`创作工作站` 标签）、Agent Mode + 沙箱产物链已在生成式输出笔记贡献中，本笔记不重复计数。辅助贡献：团队 API 资源共享（`入口确认`，暂不计入特色统计）、Copilots（本地部分）。README 更新建议由主会话决定是否反馈上游。

## 未验证事项

- team-sharing 部署（Docker/Caddy）未运行，代理注入与客户端免 Key 请求的端到端行为未验证。
- 图像生成的真实模型调用（DALL-E 等）与参考图 DAG 的实际构图行为未实测。
- Copilots 远端 API 的可用性与分页未验证。
- 新用户引导（/guide/）与 Chatbox AI 账号面的细节未调查（非本批范围）；新用户引导的剧本场景已重写（`af40ab34` 用简历助手场景替换 Q&A 演练场景，`8c2a8a7b` 向 system prompt 注入稳定场景标记），本笔记仍不展开。
- 图像生成记录 source 字段（chatbox_cli 来源）与聊天内恢复的完整运行时行为未实测。

## 关键源码索引

- 团队共享部署：`team-sharing/Caddyfile`、`team-sharing/main.sh`、`team-sharing/README.md`
- 图像工作台：`src/renderer/routes/image-creator/index.tsx`、`src/renderer/stores/imageGenerationActions.ts:190-372`、`imageGenerationStore.ts`、`src/shared/types/image-generation.ts`
- Copilots：`src/renderer/routes/copilots/{index,my,featured,search}.tsx`、`-components/CopilotSettingsModal.tsx`、`src/renderer/packages/remote.ts:178-220`
- 设置菜单与 flag：`src/renderer/routes/settings/route.tsx:31-110`、`src/renderer/utils/feature-flags.ts:4-6`
- Skills 主进程：`src/main/skills/{installer,discovery,github-fetcher,user-exec-runner}.ts`、`builtin/index.ts`
- 沙箱与产物（归并引用）：`src/main/sandbox/manager.ts`、`src/renderer/components/Artifact.tsx`

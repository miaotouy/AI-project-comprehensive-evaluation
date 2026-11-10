# LobeHub 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
>
> 调查方式：静态源码阅读 + 关键词检索（artifact/canvas/sandbox/iframe/webview/notebook/diff/patch/execution/runtime/exec/preview/file/tool/mcp/dalle/code execution 等）+ 读取既有单测与文档；未启动应用运行验证
>
> 调查范围：Artifact 协议与 Portal 投影、Cloud Sandbox 代码执行与文件导出、文档工作区（编辑器/历史/diff/编辑锁）、agent 文档 VFS 与模型回流、工具输出渲染扩展点；未覆盖：桌面端本地文件全链路、移动端、插件市场治理、图片生成任务后端细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的生成式输出分为三个并存的层次：**Artifact**（`<lobeArtifact>` 私有标记协议，消息内卡片 + 右侧 Portal 预览面板，HTML iframe / React Sandpack / SVG / Mermaid 渲染，支持逐 token 流式更新与整段重生成）、**Cloud Sandbox 代码执行**（内置 `lobe-cloud-sandbox` 工具，远端沙箱执行 Python/JS/Shell，文件可导出为持久化文件对象）、**文档工作区**（Lexical 富文本编辑器 + 服务端无头编辑器，文档存数据库，带历史快照、编辑器内 diff 节点接受/拒绝、Redis 编辑锁、Page-Agent 结构化修改与模型上下文回流）。Artifact 源码仍来自消息 `content`，但 HTML Artifact 已增加发布与 revision 生命周期；普通未发布 Artifact 仍没有独立对象行。文档是独立持久化对象且模型可定向修改，构成 G4 级可编辑工作区。

## 系统边界与完整主链路

本类目与 Chat（会话/流式装配）、消息渲染器（普通 Markdown/工具卡）、Agent 工具（工具注册与执行调度）、插件生态的交接点：本文只记录"输出获得独立对象身份或专用运行环境"之后的环节；工具如何被调用、流式协议如何装配属于相邻类目。

**主链路 A（Artifact）：** 模型按内置技能 `lobe-artifacts` 的指令，在消息正文里写出 `<lobeArtifact identifier type title>` 标记，客户端收到后把标记变成卡片，并在生成过程中自动打开右侧 Portal 预览。协议指令与触发判定定义在技能内容文件；客户端先由 Markdown 管线归一化半截标记，再经 rehype 插件转成卡片节点，卡片组件负责自动开面板，Portal 再按类型选择渲染器（`packages/builtin-skills/src/artifacts/content.ts`；`src/features/Conversation/utils/markdown.ts`；`src/features/Conversation/Markdown/plugins/LobeArtifact/` 下的 rehype 插件与 `Render/index.tsx:79-83`）。消息结束后正文写入消息内容列，重新打开会话时再按正则从该消息内容提取源码用于展示（`packages/database/src/schemas/message.ts:103`；`src/store/chat/slices/portal/selectors.ts:103-118`）。**未运行验证。**

**主链路 B（文档工作区）：** 文档保存在 `documents` 表，正文与编辑态各存一份。
- 用户编辑：改动先落在 Lexical 编辑器里，前端文档 store 防抖后自动保存，服务端保存时写一条历史快照（`src/store/document/slices/` 下 `document/action.ts` 与 `editor/action.ts:293-374`；`apps/server/src/services/document/index.ts:623-755`）。
- 模型修改：Page-Agent 工具让服务端在无头编辑器上执行结构化改动（执行体位于 builtin-tool-page-agent 包的 executionRuntime），文档先以草稿打开、成功后提交，同一文档的并发写入由 pageCollab 的页面会话串行化，客户端在页面侧绑定当前文档 ID，不依赖执行器的调用后回调（`apps/server/src/services/toolExecution/serverRuntimes/pageAgent.ts:47`；`apps/server/src/services/pageCollab`；`src/features/PageEditor/PageAgentProvider.tsx`）。
- 模型回流闭环：agent 文档按加载规则与位置注入系统上下文，模型再用 lobe-agent-documents 工具读取内容、修改节点，形成读—改—再注入的循环（`apps/server/src/services/agentDocuments/index.ts:574-611`；`packages/builtin-tool-agent-documents/src/manifest.ts`）。

**未运行验证。**

## 1. 触发方式、输出协议与对象模型

- **触发**：模型在自由文本里写出 `<lobeArtifact>` 私有标记，就产生一条 Artifact；触发规则由内置技能 `lobe-artifacts` 以协议指令的形式注入系统提示。技能内容规定只有实质、自包含、可迭代的内容才用 Artifact，代码片段一律内联；属性方面要求 identifier 跨轮复用，并给出类型约束与示例。技能经 `<available_skills>` 装配进提示词（`packages/builtin-skills/src/artifacts/index.ts:12`、`packages/builtin-skills/src/artifacts/content.ts:1-204`；`apps/server/src/services/aiAgent/index.ts:4121,4254-4279`）。
- **协议**：标签形式为 `<lobeArtifact identifier="..." type="..." title="...">content</lobeArtifact>`，type 取值见下列清单；正则与闭合判定见 `packages/const/src/plugin.ts:26-42`。

  ```text
  image/svg+xml | text/html | application/lobe.artifacts.react | application/lobe.artifacts.mermaid | text/markdown | application/lobe.artifacts.code | python
  ```

  半截流处理：客户端归一化会补全未闭合标记、剥离包裹的代码围栏、处理 `lobeThinking` 相邻（`src/features/Conversation/utils/markdown.ts:3-73`）。嵌套/转义：正则非贪婪匹配到第一个闭合标签为止，未发现针对内容中含 `</lobeArtifact>` 的转义机制（推断为未处理）。
- **对象模型**：`PortalArtifact` 结构（`packages/types/src/artifact.ts:1-8`）字段为：

  ```text
  { children?, id, identifier?, language?, title?, type? }
  ```

  结构里的 id 是消息 ID，identifier 由模型自行维护。Artifact **没有独立持久化行**：源码以 `messages.content` 文本列为事实源，Portal 只是这份文本的投影，展示代码时由 `artifactCode(id, identifier)` 按正则从消息内容中抽取（`packages/database/src/schemas/message.ts:103`；`src/store/chat/slices/portal/selectors.ts:103-118`）。文档、文件和任务输出另有独立对象（见下）。

## 2. 增量生成、更新与最终化

- **Artifact**：内容随消息正文逐 token 流入。Portal 判断标记是否闭合：未闭合时停在代码视图并保留流式动画，闭合后自动切到预览。更新粒度是**整段重写**，模型在后续消息里用同一个 identifier 重发完整内容，没有 diff 或 patch 通道（`src/features/Portal/Artifacts/Body/index.tsx:35-40,62-68`；`packages/builtin-skills/src/artifacts/content.ts:40`）。
- **文档（模型修改）**：Page-Agent 的初始化页面、修改节点、替换文本三个动作，在服务端无头编辑器上以 LiteXML 节点操作（插入、修改、删除）执行，会话以草稿打开、成功后提交，最终由 pageCollab 的写入器落库并把来源记为 llm_call（`serverRuntimes/pageAgent.ts` 的 `buildService`；`services/agentDocuments/headlessEditor.ts`；`services/pageCollab`）。
- **文档（最终化）**：写库成功后，pageCollab 持久化页面状态并生成投影（`services/pageCollab`），编辑器侧通过 page room 客户端接收变更；工具调用的交付物由 page agent 客户端包中的检查、渲染、流式三类组件呈现（`packages/builtin-tool-page-agent/src/client/`）。
- **文档（注）**：服务端历史对比返回两份 editorData 快照，视觉差异交由客户端的 LexicalDiff 计算（`services/document/history.ts` 的 `compareDocumentHistoryItems`）。
- **失败收口**：Page-Agent 拿不到 documentId 时以 PageAgentMissingDocumentId 失败返回；Page Agent 不可用时，编辑器另弹提示引导改用 lobe-agent-documents（`packages/builtin-tool-page-agent/src/ExecutionRuntime/index.ts:72-80`；`src/features/PageEditor/Copilot/PageAgentUnavailableAlert.tsx`）。

## 3. 投影表面与多视图关系

- Portal 是右侧面板视图栈（`src/features/Portal/router.tsx:30-52`），投影面分为内容对象（Artifact、Document、Notebook、FilePreview、LocalFile 等）与消息/任务流程视图（MessageDetail、TaskDetail、Thread、TopicComments、VerifyReport 等）两类，完整集合见下列清单：

  ```text
  Artifact / Document / Notebook / FilePreview / LocalFile / MessageDetail / ToolUI（插件）/ TaskDetail / Thread / TopicComments / VerifyReport / VerifyResult / Acceptance
  ```

  同一对象可有多个投影：文档同时在 Document Portal、全页路由（`src/features/AgentDocumentPage`）、Notebook 列表、任务工作区出现，数据都回源同一 DB 行。
- Artifact 卡片同时出现在消息流（inline 卡片，可点击开/关 Portal，`LobeArtifact/Render/index.tsx:85-99`）与 Portal 详情；Portal Home 的 "ArtifactList" 实为工具消息列表（`src/features/Portal/Home/Body/Plugins/ArtifactList/index.tsx:15`，消息 `plugin` 字段），与 `<lobeArtifact>` 内容 Artifact 不是一回事。

## 4. 表现类型、依赖与运行环境

- 类型分派：按 MIME 类型选择渲染器（入口 `src/features/Portal/Artifacts/Body/Renderer/index.tsx:11-35`）：

  | 类型 | 渲染方式 |
  |---|---|
  | `application/lobe.artifacts.react` | Sandpack（浏览器内打包，iframe 预览） |
  | `image/svg+xml` | 消毒后内联渲染（`SVG.tsx`） |
  | `application/lobe.artifacts.mermaid` | Mermaid 渲染 |
  | `text/markdown` | Markdown 渲染 |
  | 其余 | 默认按 HTML 进 iframe |

  React 预览由 Sandpack 在浏览器内完成打包，项目模板来自 artifact-template 包，产出 Vite + React + Tailwind 工程；HTML 预览的 iframe 由 @lobehub/ui 的 HtmlPreview 提供（`src/components/HtmlPreview/InlinePreview.tsx`）。
- 代码/项目级运行：Cloud Sandbox 暴露 13 个 API，覆盖代码执行（Python、JS、TS）、命令执行（含后台命令与 120s 超时）、文件操作和导出。执行发生在远端沙箱，服务端经两个 provider 桥接，系统提示声明运行环境基于 AWS Bedrock AgentCore，与用户本机隔离（`packages/builtin-tool-cloud-sandbox/src/manifest.ts:8-318`；`apps/server/src/services/sandbox/providers/market.ts:19`、`onlyboxes.ts:47`；`systemRole.ts:3`）。
- 桌面端另有 **Local Sandbox 执行环境**，提供环境创建、启动计划、运行时与能力探测等接口（`packages/device-sandbox`）。客户端据此判断一次本地调用是否走围栏执行，判定同时覆盖成员与管理者的网络策略，本地 system 工具因此多出“沙箱围栏”这一执行形态，与 device gateway 转发、裸 spawn 并存；围栏强度（进程与网络隔离、可写目录）尚未运行验证（`src/helpers/localSandbox.ts`）。
- 依赖提供：HTML 只允许加载 cdnjs 上的外部脚本；React 模板预装 lucide-react、recharts、shadcn，外部图片被禁用；沙箱镜像预装 Python 数据栈、Node 与 Chromium（`content.ts:48-67`、`systemRole.ts:27-80`）。

## 5. 用户交互、事件与错误反馈

- Artifact：顶部可在预览与代码两种模式间切换，SVG 支持下载成 PNG/SVG 和复制为图片，生成中的卡片显示加载状态与字符数。文档侧的交互状态（待审 diff、dirty、编辑锁）在重新加载后由持久化行与锁服务重建（`src/features/Portal/Artifacts/Title.tsx:73-93`、`SVG.tsx:41-130`、`LobeArtifact/Render/index.tsx:106-124`）。
- 工具渲染层按四类注册表登记（类别清单见下），ToolUI Portal 再按工具 identifier 取出内置组件渲染，这套注册构成工具与插件输出的声明式扩展点，白名单内置（`packages/builtin-tools/src/register.ts:174-352`；`src/features/Portal/Plugins/Body/ToolRender.tsx:26-38`）。

  ```text
  Render / Inspector / Streaming / Intervention / Placeholder / Portal
  ```
- 错误反馈：沙箱执行失败时，错误信息、退出码与标准错误以结构化字段回传；文档保存冲突则以 toast 加阻塞状态提示用户（`packages/builtin-tool-cloud-sandbox/src/ExecutionRuntime/index.ts:40-74`；`src/store/document/slices/editor/action.ts:355-373`）。

## 6. 编辑、diff、版本与协作

- 用户编辑：Lexical 富文本（`src/features/EditorCanvas/InternalEditor.tsx`）或代码文件用 Monaco 高亮编辑（`src/features/Portal/Document/Body.tsx:220-317`），均防抖自动保存。
- 版本：`documentHistories` 表存 JSON editorData 快照，saveSource 区分五类来源（`apps/server/src/services/document/types.ts:3`）：

  ```text
  autosave / manual / restore / system / llm_call
  ```

  自动保存会合并时间窗口并限制条数（`src/const/documentHistory.ts`）。服务端对比接口返回两份 editorData 快照，视觉差异由客户端的 LexicalDiff 渲染（`apps/server/src/services/document/history.ts:109-125`、`src/features/PageEditor/History/DocumentHistoryDiff.tsx:61-114`）。
- diff 接受/拒绝：编辑器里的 diff 节点可以一键全部接受或拒绝，保存路径会刻意留住待审节点，只有用户显式确认时才归一化；节点的生成时机位于外部包 @lobehub/editor，本次未深挖，历史对比视图本身只读（`src/features/EditorCanvas/DiffAllToolbar.tsx:117-167`；`src/store/document/slices/editor/action.ts:325-327`）。
- 协作：编辑锁是独立的 Redis 租约服务，由文档服务注入使用，模型写操作与用户编辑因此排在同一把锁上，跨 tab、跨用户的互斥效果见页面侧的 hook。实时协同由 pageCollab 承担：它以 page room 客户端、房间会话和 fork/persist 组织多人编辑，无头侧通过 Yjs 插件接入，整条路径由开关控制，实际运行行为未验证（`apps/server/src/services/editLock`；`src/features/PageEditor/usePageLockedByOther.ts`；`apps/server/src/services/pageCollab`）。

## 7. 能力桥、执行位置与权限范围

- 沙箱工具中的写文件与命令执行类工具均标注 `humanIntervention: 'required'`（`packages/builtin-tool-cloud-sandbox/src/manifest.ts:13,107,137,161,190`），逐个经工具执行层的干预注册表审批（`packages/builtin-tools/src/register.ts:296-322`）。此类工具包括：

  ```text
  executeCode / writeFile / editFile / moveFiles / runCommand
  ```

- 执行位置分层：Artifact 的 HTML/React 在浏览器 iframe 或 Sandpack 内运行；Cloud Sandbox 在远端沙箱执行，由 HTTP provider 桥接；本地文件工具落在桌面设备，经 device gateway 转发，本次只确认到入口。沙箱产物可通过导出上传流程登记为云存储文件记录，生成的文件也能自动登记为 work 资产（`apps/server/src/services/sandbox/service.ts:141`、`routers/tools/market.ts:690-696`；`apps/server/src/services/toolExecution/workRegistration.ts`、`apps/server/src/services/workRegistration/`）。
- MCP/插件：本文只记录工具与插件输出的扩展点（ToolUI Portal 与渲染注册表），插件发现与授权属于插件生态类目，未展开。

## 8. 持久化、恢复、分享与导出

- Artifact：源码仍存在消息文本里，恢复时从数据库消息中提取。HTML Artifact 可以走工作区本地文件发布链，也可以执行 `lh artifact publish <file>` 打包本地依赖后发布；发布器返回 revision 编号和公开 URL，CLI 会打印分享地址。发布前会限制本地资源的数量与总量，并拒绝未打包的本地引用。具体发布后端由业务槽提供，OSS 自托管环境能看到的是发布入口，服务可用性取决于所配置的后端实现（`packages/html-artifact/src/publishWorkspaceHtmlArtifact.ts:35-118`；`apps/cli/src/commands/artifact.ts:84-138,204-246`）。
- 文档：一条文档记录同时保存正文与编辑态两份数据，外加标题、父节点、文件类型等元数据，另配历史表与编辑锁。恢复入口是 restoreFromHistoryId 与配套的历史对比，发布后可参与工作区可见性与权限控制（`apps/server/src/services/document/index.ts` 负责行构造与校验；`apps/server/src/routers/lambda/_schema/documentHistory.ts:47`）。
- 沙箱导出文件成为 `files` 记录（预签名 URL 下载），图片生成工具产出的图片直接在消息内渲染展示，其落库链路本次未追完（`packages/builtin-tool-image-generation/src/client/Render/GenerateImage.tsx`）。
- 备注：“保存到工作区”对应的 ArtifactDeploymentActions 目前是返回 null 的空桩，背后由 lab 开关 enableArtifactDeployment 控制，Artifact 到文档或文件的落盘能力未实现（`src/business/client/features/ArtifactDeploymentActions.tsx:11-13`、`src/store/user/slices/preference/selectors/labPrefer.ts:12-14`）。

## 9. 模型回流、对象感知与持续维护

- Artifact 迭代：模型从会话历史里读到上一版内容，按技能指令复用同一个 identifier 整段重发；对象身份（消息 ID 加 identifier）只存在于客户端 Portal 栈里，模型侧没有查询接口。
- 文档：完整闭环。模型经 `lobe-agent-documents` 工具集读写文档（`packages/builtin-tool-agent-documents/src/manifest.ts:8-283`）：
  - 读取：`listDocuments`、`readDocument`（XML 带节点 ID + markdown 双格式）；
  - 修改：`modifyNodes`、`replaceText`、`createDocument`、`renameDocument`、`copyDocument`、`removeDocument`；
  - 注入策略：`updateLoadRule`。
  agent 文档按加载策略与规则自动注入上下文，注入内容由上下文载荷构造（`apps/server/src/services/agentDocuments/index.ts`、`services/agentDocuments/contextPayload.ts`；`packages/agent-templates/src/types.ts:4-45`）。
- 注入链路在 context-engine 侧实现，三个处理器各司其职：
  - `AgentDocumentInjector/shared.ts`：按 `loadPosition`/`loadRules` 注入；
  - `SystemReplaceInjector`：让动态激活文档只携带一次、用绝对日期索引；
  - `ActivationResultTrim`：避免激活结果重复进 LLM 载荷（`packages/context-engine/src/processors/ActivationResultTrim.ts`）。
  文档写入前会自动留一份历史快照；服务端另有基于历史回滚的服务 receiptRollbackService，细节未深挖（`services/agentDocuments/index.ts`；`apps/server/src/services/agentSignal/services/receiptRollbackService.ts:179`）。
- 会话文件：用户上传的文件会自动同步进沙箱会话目录；沙箱为每个 topic 开独立会话，过期后重建（`systemRole.ts:21-24,222-227`）。

## 10. 生命周期、资源治理与性能

- 文档编辑：按 documentId 防抖保存、关闭时 flush（`src/store/document/slices/document/action.ts:78-135`）；dirty 文档在离开/卸载时有守卫（`src/features/EditorCanvas/UnsavedChangesGuard.tsx`，未细读）。编辑锁租约 10s 心跳、30s TTL（`src/const/documentLock.ts:20`，Redis 侧 TTL）。
- 历史上限（`src/const/documentHistory.ts:7-14`）：

  | 保存来源 | 条数上限 |
  |---|---|
  | `autosave` / `manual` | 各 20 条 |
  | `restore` / `system` / `llm_call` | 各 5 条 |

  免费窗口 30 天。
- 沙箱：后台命令可 kill、120s 超时、会话随 topic 隔离且过期回收（`manifest.ts:187-244`、`systemRole.ts:222-227`）。Artifact 运行时（iframe/Sandpack）随 Portal 视图卸载，未见显式定时器/媒体资源登记。

## 11. 测试、已确认边界与未验证事项

- 测试：以下均为单测，本文结论未经运行验证：
  - artifact 正则/闭合/identifier 转义：`selectors.test.ts`（`src/store/chat/slices/portal/selectors.test.ts:191-936`）；
  - 半截流归一化：`markdown.test.ts`（`src/features/Conversation/utils/markdown.ts` 配套测试）；
  - 协议正则：`const/plugin.test.ts`；文档 diff 工具：`document/diff/json.test.ts`；
  - 文档服务（含锁/历史/llm_call 快照）：`apps/server/src/services/document/__tests__/`；
  - pageAgent 服务端注册；cloudSandbox 运行时与 provider：`apps/server/src/services/sandbox/__tests__/`。
- 已确认边界：普通 Artifact 无独立对象存储、无 diff 更新、无模型对象寻址；HTML 发布通过消息 Artifact 与发布服务建立 revision，不改变普通 Artifact 的事实源。Notebook 工具已标记废弃，不再注入 LLM 工具；Notebook Portal 仍作为 topic 文档列表存在。
- 未验证/未覆盖：桌面本地文件编辑全链路与设备网关授权细节（桌面 Local Sandbox 见第 4 节，围栏强度/安装链未运行验证）、图片生成任务的文件落库、diff 节点在 `@lobehub/editor` 内的生成时机、编辑锁与实时推送的实际运行行为、移动端表现。声称"没有 X"均限于本次检索范围（src/packages/apps 的 `*.ts/tsx`，关键词见元数据）。

## 12. 关键源码索引

- `packages/types/src/artifact.ts:1-15`：PortalArtifact 对象模型与类型枚举
- `packages/const/src/plugin.ts:26-42`：lobeArtifact 协议标签与正则
- `packages/builtin-skills/src/artifacts/content.ts:1-204`：Artifact 输出协议指令（触发/类型/identifier 复用）
- `src/features/Conversation/Markdown/plugins/LobeArtifact/Render/index.tsx:59-129`：消息内卡片与自动打开 Portal
- `src/store/chat/slices/portal/selectors.ts:76-132`：Artifact 源码从消息内容提取
- `src/features/Portal/Artifacts/Body/index.tsx`、`Renderer/index.tsx`：Portal 渲染与类型分派
- `src/features/Portal/router.tsx:30-52`：Portal 投影面全集
- `packages/builtin-tool-cloud-sandbox/src/manifest.ts`：云端沙箱工具面（执行/文件/导出）
- `apps/server/src/services/sandbox/providers/market.ts:19`、`onlyboxes.ts:47`：沙箱 provider 桥
- `apps/server/src/services/toolExecution/serverRuntimes/pageAgent.ts:47`：Page Agent 服务端注册（无头 `EditorRuntime` + `pageCollab` 会话 + 编辑锁）
- `apps/server/src/services/pageCollab/`：文档会话、房间协同（Yjs）、fork 与持久化
- `packages/builtin-tool-page-agent/src/client/`：Page Agent 的 Inspector/Render/Streaming 交付组件
- `src/features/PageEditor/PageAgentProvider.tsx`：按 documentId 绑定页级会话
- `apps/server/src/services/agentDocuments/index.ts:574-611,744-829`：文档上下文注入与模型 CRUD（注入决策细节见 `packages/context-engine/src/providers/AgentDocumentInjector/`，含 `SystemReplaceInjector` 与 `ActivationResultTrim` 处理器）
- `apps/server/src/services/document/{index,history,editorData,json,writeLimit}.ts`：保存、历史快照、写入上限与 editorData 编解码
- `apps/server/src/services/editLock/index.ts`：编辑锁服务（Redis 租约）
- `src/features/EditorCanvas/DiffAllToolbar.tsx:117-167`：diff 节点接受/拒绝
- `packages/database/src/schemas/message.ts:95-140`：消息表（Artifact 事实源）
- `packages/builtin-tools/src/register.ts:174-352`：工具输出渲染/检查/审批/流式注册表
- `packages/html-artifact/src/`、`apps/cli/src/commands/artifact.ts`：HTML 本地资源打包、发布与 CLI 入口

## 能力等级评估

横向按指南轴给出：**协议开放度**——私有标记（Artifact）+ 文件/文档对象（VFS）；**更新粒度**——Artifact 整段重写、文档节点级 LiteXML 操作；**投影表面**——inline 卡片 + 右侧 Portal + 全页编辑器 + 文档列表 + 沙箱文件 tab；**执行强度**——浏览器 iframe/Sandpack（G3 级可执行）+ 远端代码沙箱；**持续性**——Artifact 随消息跨会话存活（只读重放）、文档为跨会话活对象；**闭环程度**——Artifact 只生成/可交互、文档可查询/可定向修改/可注入上下文；**能力范围**——沙箱逐项审批（代码执行、写文件、命令）、导出桥接云存储；**可移植性**——Artifact 可导出单文件（SVG/PNG/复制），文档无标准项目导出。

**能力等级：G3–G4 并存**（总评取 G4 依据最强的文档工作区）。依据：
- G3 由 HTML/React/Sandpack 可执行 Artifact 与云端代码沙箱支撑（`Artifacts/Body/Renderer/React/index.tsx`、`builtin-tool-cloud-sandbox`）；
- G4 由文档对象（DB 行 + editorData 双格式）、历史快照与对比、编辑器内 diff 接受/拒绝、Redis 编辑锁、模型经 Page-Agent/lobe-agent-documents 定向修改同一对象（节点 ID 寻址、load rules 回流）构成（`services/document/index.ts`、`serverRuntimes/pageAgent.ts`、`agentDocuments/index.ts`）。

未达 G5 的差距：内容型 Artifact 无独立对象身份与模型寻址能力，仅靠整段重生成；沙箱文件为临时会话资产，导出后才成为持久文件；无桌面级长期活对象挂载。

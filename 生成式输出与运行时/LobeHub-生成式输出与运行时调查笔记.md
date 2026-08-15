# LobeHub 生成式输出与运行时调查笔记

> 调查对象：`../../lobehub`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`3b57a07e3cc1f6b5aaabad36112e8ba40142df29`（分支：`canary`）
>
> 调查方式：静态源码阅读 + 关键词检索（artifact/canvas/sandbox/iframe/webview/notebook/diff/patch/execution/runtime/exec/preview/file/tool/mcp/dalle/code execution 等）+ 读取既有单测与文档；未启动应用运行验证
>
> 调查范围：Artifact 协议与 Portal 投影、Cloud Sandbox 代码执行与文件导出、文档工作区（编辑器/历史/diff/编辑锁）、agent 文档 VFS 与模型回流、工具输出渲染扩展点；未覆盖：桌面端本地文件全链路、移动端、插件市场治理、图片生成任务后端细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 的生成式输出分为三个并存的层次：**Artifact**（`<lobeArtifact>` 私有标记协议，消息内卡片 + 右侧 Portal 预览面板，HTML iframe / React Sandpack / SVG / Mermaid 渲染，支持逐 token 流式更新与整段重生成）、**Cloud Sandbox 代码执行**（内置 `lobe-cloud-sandbox` 工具，远端沙箱执行 Python/JS/Shell，文件可导出为持久化文件对象）、**文档工作区**（Lexical 富文本编辑器 + 服务端无头编辑器，文档存数据库，带历史快照、编辑器内 diff 节点接受/拒绝、Redis 编辑锁、Page-Agent 结构化修改与模型上下文回流）。Artifact 对象本身不独立持久化（源码事实源是消息 `content` 文本列），而文档是独立持久化对象且模型可定向修改，构成 G4 级可编辑工作区。

## 系统边界与完整主链路

本类目与 Chat（会话/流式装配）、消息渲染器（普通 Markdown/工具卡）、Agent 工具（工具注册与执行调度）、插件生态的交接点：本文只记录"输出获得独立对象身份或专用运行环境"之后的环节；工具如何被调用、流式协议如何装配属于相邻类目。

**主链路 A（Artifact）：** 模型经内置技能 `lobe-artifacts`（`packages/builtin-skills/src/artifacts/content.ts`）的指令在消息正文输出 `<lobeArtifact identifier type title>` 标记；客户端 Markdown 管线先归一化半截标记，再由 rehype 插件转成卡片节点，卡片组件在生成中自动打开 Portal（`src/features/Conversation/utils/markdown.ts`；`src/features/Conversation/Markdown/plugins/LobeArtifact/rehypePlugin.ts`；`LobeArtifact/Render/index.tsx:79-83`），Portal 按类型渲染预览。消息结束写入数据库 `messages.content` 文本列（`packages/database/src/schemas/message.ts:103`），重新打开会话时从该消息内容按正则提取源码展示（`src/store/chat/slices/portal/selectors.ts:103-118`）。**未运行验证。**

**主链路 B（文档工作区）：** 文档存 `documents` 表（content + editorData 双格式）。
- 用户编辑：Lexical 编辑器内修改，前端文档 store 防抖自动保存（`src/store/document/slices/document/action.ts`、`editor/action.ts:293-374`）；服务端 `DocumentService.updateDocument` 写历史快照（`apps/server/src/services/document/index.ts:623-755`）。
- 模型修改：Page-Agent 工具在服务端无头编辑器上做结构化修改（`apps/server/src/services/toolExecution/serverRuntimes/pageAgent.ts:330-388`），客户端 `onAfterCall` 把服务端快照推回活编辑器（`packages/builtin-tool-page-agent/src/client/executor/index.ts:143-189`）。
- 模型回流闭环：agent 文档按 load rules/position 注入系统上下文（`apps/server/src/services/agentDocuments/index.ts:574-611`），模型通过 `lobe-agent-documents` 工具做读取与节点修改（`readDocument`/`modifyNodes`/`replaceDocumentContent` 等，`packages/builtin-tool-agent-documents/src/manifest.ts`）。

**未运行验证。**

## 1. 触发方式、输出协议与对象模型

- **触发**：Artifact 由模型自由文本中的 `<lobeArtifact>` 私有标记触发，协议指令以内置技能 `lobe-artifacts`（`packages/builtin-skills/src/artifacts/index.ts:12`）的形式注入。技能内容定义触发判定（实质、自包含、可迭代内容才用；代码片段一律内联）、属性规范（`identifier` 需跨轮复用）、类型约束与示例（`packages/builtin-skills/src/artifacts/content.ts:1-204`）。技能经 `<available_skills>` 装配进系统提示（`apps/server/src/services/aiAgent/index.ts:4121,4254-4279`）。
- **协议**：标签形式为 `<lobeArtifact identifier="..." type="..." title="...">content</lobeArtifact>`，type 取值见下列清单；正则与闭合判定见 `packages/const/src/plugin.ts:26-42`。

  ```text
  image/svg+xml | text/html | application/lobe.artifacts.react | application/lobe.artifacts.mermaid | text/markdown | application/lobe.artifacts.code | python
  ```

  半截流处理：客户端归一化会补全未闭合标记、剥离包裹的代码围栏、处理 `lobeThinking` 相邻（`src/features/Conversation/utils/markdown.ts:3-73`）。嵌套/转义：正则非贪婪匹配到第一个闭合标签为止，未发现针对内容中含 `</lobeArtifact>` 的转义机制（推断为未处理）。
- **对象模型**：`PortalArtifact` 结构（`packages/types/src/artifact.ts:1-8`）字段为：

  ```text
  { children?, id, identifier?, language?, title?, type? }
  ```

  `id` 是消息 ID，`identifier` 是模型自管 ID。Artifact **没有独立持久化行**：源码事实源是 `messages.content` 文本列（`packages/database/src/schemas/message.ts:103`），Portal 仅是投影，代码经 `artifactCode(id, identifier)` 从消息内容正则抽取（`src/store/chat/slices/portal/selectors.ts:103-118`）。文档/文件/任务输出则另有独立对象（见下）。

## 2. 增量生成、更新与最终化

- **Artifact**：随消息正文逐 token 流式注入。Portal 内以 `isArtifactTagClosed` 判定标记是否闭合：未闭合时保持代码视图与流式动画，闭合后自动切到预览（`src/features/Portal/Artifacts/Body/index.tsx:35-40,62-68`）。更新粒度是**整段重写**：同一 `identifier` 在后续消息中由模型重发完整内容（技能指令要求复用 identifier，`content.ts:40`）；无 diff/patch。
- **文档（模型修改）**：Page-Agent 的 `initPage`/`modifyNodes`/`replaceText` 在服务端无头编辑器上以节点操作（LiteXML insert/modify/remove）执行，导出 Lexical JSON + Markdown 后整体写回 `updateDocument`（`apps/server/src/services/toolExecution/serverRuntimes/pageAgent.ts:240-262`；`agentDocuments/headlessEditor.ts:169-186`）。
- **文档（最终化）**：写库成功后在 `tool_end` 事件经 `onAfterCall` 把快照同步回活编辑器并清 dirty（`packages/builtin-tool-page-agent/src/client/executor/index.ts:143-189`）；有静默失败/意外变更的不变量检测（`pageAgent.ts:62-107`）。
- **文档（注）**：`services/document/diff/json.ts` 的 jsondiffpatch 工具（`createJsonPatch`/`applyJsonPatch`）在本快照中仅被自身单测引用，未接入生产路径；服务端历史对比只返回两份 editorData 快照（`history.ts:109-125`），视觉 diff 由客户端 `LexicalDiff` 计算。
- **失败收口**：Page-Agent 无 documentId 时返回 `PageAgentMissingDocumentId` 失败（`packages/builtin-tool-page-agent/src/ExecutionRuntime/index.ts:72-80`）；编辑器未挂载时客户端返回 `PAGE_EDITOR_NOT_MOUNTED` 并提示改用 lobe-agent-documents（`packages/builtin-tool-page-agent/src/client/executor/index.ts:65-86`）。

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

  Sandpack 依赖 `@codesandbox/sandpack-react` + `packages/artifact-template` 生成 Vite+React+Tailwind 项目；iframe 由 `@lobehub/ui` HtmlPreview 提供（`src/components/HtmlPreview/InlinePreview.tsx`）。
- 代码/项目级运行：Cloud Sandbox 提供 13 个 API（`packages/builtin-tool-cloud-sandbox/src/manifest.ts:8-318`），覆盖 `executeCode`（Python/JS/TS）、`runCommand`（含后台命令、120s 超时）、文件操作与导出；执行位置为远端沙箱，服务端经 `MarketSandboxProvider`/`OnlyboxesSandboxProvider` 桥接（`apps/server/src/services/sandbox/providers/market.ts:19`、`onlyboxes.ts:47`），系统提示声明基于 AWS Bedrock AgentCore 且与用户本机隔离（`systemRole.ts:3`）。
- 桌面端另有 **Local Sandbox 执行环境**（`packages/device-sandbox`，含环境创建、启动计划、运行时与能力探测等 API），相关提交：`e9b6d00ab`；`9b4f944cb`（给本地沙箱工作目录）；`95dfa1d38`（改为探测应用自带沙箱助手）。`src/helpers/localSandbox.ts` 在客户端判定是否围栏执行（`isLocalSandboxEnabled`/`resolveClientLocalSandbox`，含 `localSandboxNetwork` 成员/管理者双重判定），本地 system 工具因此多了“沙箱围栏”这一执行形态（与 device gateway 转发、裸 spawn 并存）；沙箱围栏强度（进程/网络隔离、writable roots）未运行验证。
- 依赖提供：HTML 仅允许 cdnjs 外部脚本；React 预装 lucide-react、recharts、shadcn 并禁用外部图片（`content.ts:48-67`）；沙箱预装 Python 数据栈、Node、Chromium 等（`systemRole.ts:27-80`）。

## 5. 用户交互、事件与错误反馈

- Artifact：预览/代码双模式切换（`src/features/Portal/Artifacts/Title.tsx:73-93`）、SVG 下载 PNG/SVG、复制为图片（`SVG.tsx:41-130`）；生成中卡片显示 loading 与字符数（`LobeArtifact/Render/index.tsx:106-124`）。文档内的交互状态（diff 待审、dirty、编辑锁）不随重载恢复，以持久化行 + 锁服务重建（见第 8/10 节）。
- 工具渲染层分四类注册表（`packages/builtin-tools/src/register.ts:174-352`，类别清单见下），ToolUI Portal 按工具 identifier 取内置 Portal 组件渲染（`src/features/Portal/Plugins/Body/ToolRender.tsx:26-38`）。这是工具/插件输出的声明式扩展点（内置白名单注册，非任意脚本）。

  ```text
  Render / Inspector / Streaming / Intervention / Placeholder / Portal
  ```
- 错误反馈：执行失败以 `state.error`/`exitCode`/`stderr` 结构化回传（`packages/builtin-tool-cloud-sandbox/src/ExecutionRuntime/index.ts:40-74`）；文档保存冲突以 toast + `saveBlockedByLock` 状态呈现（`src/store/document/slices/editor/action.ts:355-373`）。

## 6. 编辑、diff、版本与协作

- 用户编辑：Lexical 富文本（`src/features/EditorCanvas/InternalEditor.tsx`）或代码文件用 Monaco 高亮编辑（`src/features/Portal/Document/Body.tsx:220-317`），均防抖自动保存。
- 版本：`documentHistories` 表存 JSON editorData 快照，saveSource 区分五类来源（`apps/server/src/services/document/types.ts:3`）：

  ```text
  autosave / manual / restore / system / llm_call
  ```

  自动保存有窗口合并与上限（`src/const/documentHistory.ts`）。服务端 `compareDocumentHistoryItems` 返回两份快照（`apps/server/src/services/document/history.ts:109-125`），客户端 `LexicalDiff` 渲染视觉对比（`src/features/PageEditor/History/DocumentHistoryDiff.tsx:61-114`）。
- diff 接受/拒绝：编辑器内的 `diff` 类型节点由 `DiffAllToolbar` 一键全部接受/拒绝（`src/features/EditorCanvas/DiffAllToolbar.tsx:117-167`）；保存路径刻意保留待审 diff 节点，仅在显式接受/拒绝时归一化（`src/store/document/slices/editor/action.ts:325-327`）。diff 节点来源在 `@lobehub/editor`（外部包），本次未深挖其生成时机；历史对比视图本身是只读的。
- 协作：Redis 租约式编辑锁（`apps/server/src/services/document/index.ts:301-461`；`src/const/documentLock.ts`），模型写操作也走同一锁机制与用户编辑串行化（`pageAgent.ts:202-278`）；跨 tab/跨用户锁语义见 `src/features/PageEditor/usePageLockedByOther.ts`。未发现 CRDT/实时协同，锁冲突时拒绝写入并提示。

## 7. 能力桥、执行位置与权限范围

- 沙箱工具中的写文件与命令执行类工具均标注 `humanIntervention: 'required'`（`packages/builtin-tool-cloud-sandbox/src/manifest.ts:13,107,137,161,190`），逐个经工具执行层的干预注册表审批（`packages/builtin-tools/src/register.ts:296-322`）。此类工具包括：

  ```text
  executeCode / writeFile / editFile / moveFiles / runCommand
  ```

- 执行位置分层：Artifact HTML/React 在浏览器 iframe/Sandpack；Cloud Sandbox 在远端沙箱（HTTP provider 桥接）；本地文件工具在桌面设备（经 device gateway，本次仅确认入口）。沙箱文件可经导出并上传流程登记为云存储文件记录（`apps/server/src/services/sandbox/service.ts:141`；`routers/tools/market.ts:690-696`），生成文件可自动登记为 work 资产（`apps/server/src/services/agentRuntime/workRegistration.ts:631-745`）。
- MCP/插件：本文只确认其输出扩展点（ToolUI Portal + 注册表渲染、`ToolRender.tsx`），插件发现/授权属于插件生态类目，未展开。

## 8. 持久化、恢复、分享与导出

- Artifact：源码存消息文本（`messages.content`），恢复 = 从 DB 消息重新提取，无版本、无分享对象；SVG 可导出 PNG/SVG/复制图片（`SVG.tsx`）。文档声称 HTML 可 "Save HTML"（`docs/usage/agent/artifacts.mdx:149`），但 Artifact 内联预览关闭了复制/下载（`InlinePreview.tsx:32-34`），独立 HTML 导出按钮未找到（以代码为准）。
- 文档：`documents` 行（`apps/server/src/services/document/index.ts:123-216`）字段含 content、editorData、title、parentId、fileType 等，另配历史表与编辑锁；恢复 = `restoreFromHistoryId` 与历史对比（`apps/server/src/routers/lambda/_schema/documentHistory.ts:47`）。文档可发布到 workspace 并参与可见性/权限（`DocumentService.setVisibility`/`publishToWorkspace`）。
- 沙箱导出文件成为 `files` 记录（预签名 URL 下载），图片生成工具的图片以消息内渲染展示（`packages/builtin-tool-image-generation/src/client/Render/GenerateImage.tsx`），文件落库链路本次未追完。
- 备注：`ArtifactDeploymentActions`（"保存到工作区"）目前是空桩返回 null（`src/business/client/features/ArtifactDeploymentActions.tsx:11-13`），对应 lab 开关 `enableArtifactDeployment`（`src/store/user/slices/preference/selectors/labPrefer.ts:12-14`）——Artifact 到文档/文件的落盘能力未实现。

## 9. 模型回流、对象感知与持续维护

- Artifact 迭代：模型依靠会话历史看到上一版内容并按指令复用 `identifier` 整段重发，无对象查询接口；对象身份（消息 id + identifier）只存在于客户端 Portal 栈。
- 文档：完整闭环。模型经 `lobe-agent-documents` 工具集读写文档（`packages/builtin-tool-agent-documents/src/manifest.ts:8-283`）：
  - 读取：`listDocuments`、`readDocument`（XML 带节点 ID + markdown 双格式）；
  - 修改：`modifyNodes`、`replaceText`、`createDocument`、`renameDocument`、`copyDocument`、`removeDocument`；
  - 注入策略：`updateLoadRule`。
  agent 文档按 policy/loadRules 自动注入上下文（`apps/server/src/services/agentDocuments/index.ts:574-611`；`packages/agent-templates/src/types.ts:4-45`）。
- 注入链路在 context-engine 侧实现，三个处理器各司其职：
  - `AgentDocumentInjector/shared.ts`：按 `loadPosition`/`loadRules` 注入；
  - `SystemReplaceInjector`：让动态激活文档只携带一次（提交 `5b348e814`）、用绝对日期索引（提交 `cc064ee9b`）；
  - `ActivationResultTrim`：避免激活结果重复进 LLM 载荷（`packages/context-engine/src/processors/ActivationResultTrim.ts`）。
  文档写入前自动快照历史（`agentDocuments/index.ts:735-781`）；`receiptRollbackService` 存在基于历史回滚的服务端机制（`apps/server/src/services/agentSignal/services/receiptRollbackService.ts:179`，细节未深挖）。
- 会话文件：上传文件自动同步进沙箱会话目录（`systemRole.ts:21-24`），沙箱每 topic 独立会话、过期重建（`systemRole.ts:222-227`）。

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
- 已确认边界：Artifact 无独立对象存储、无 diff 更新、无模型对象寻址；HTML 预览禁用复制/下载；"部署到工作区"为空桩；Notebook 工具已标记废弃（`packages/builtin-tool-notebook/src/manifest.ts:7` 标注 deprecated，不再注入 LLM 工具），Notebook Portal 仍作为 topic 文档列表存在。
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
- `apps/server/src/services/toolExecution/serverRuntimes/pageAgent.ts:184-417`：模型结构化改文档（无头编辑器 + 锁 + 历史）
- `packages/builtin-tool-page-agent/src/client/executor/index.ts:143-189`：服务端快照回推活编辑器
- `apps/server/src/services/agentDocuments/index.ts:574-611,744-829`：文档上下文注入与模型 CRUD（注入决策细节见 `packages/context-engine/src/providers/AgentDocumentInjector/`，含 `SystemReplaceInjector` 与 `ActivationResultTrim` 处理器）
- `apps/server/src/services/document/index.ts:623-755`、`services/document/history.ts:109-168`：保存、历史快照与对比（jsondiffpatch 工具 `diff/json.ts` 未接入生产路径，见第 2 节）
- `src/features/EditorCanvas/DiffAllToolbar.tsx:117-167`：diff 节点接受/拒绝
- `packages/database/src/schemas/message.ts:95-140`：消息表（Artifact 事实源）
- `packages/builtin-tools/src/register.ts:174-352`：工具输出渲染/检查/审批/流式注册表

## 能力等级评估

横向按指南轴给出：**协议开放度**——私有标记（Artifact）+ 文件/文档对象（VFS）；**更新粒度**——Artifact 整段重写、文档节点级 LiteXML 操作；**投影表面**——inline 卡片 + 右侧 Portal + 全页编辑器 + 文档列表 + 沙箱文件 tab；**执行强度**——浏览器 iframe/Sandpack（G3 级可执行）+ 远端代码沙箱；**持续性**——Artifact 随消息跨会话存活（只读重放）、文档为跨会话活对象；**闭环程度**——Artifact 只生成/可交互、文档可查询/可定向修改/可注入上下文；**能力范围**——沙箱逐项审批（代码执行、写文件、命令）、导出桥接云存储；**可移植性**——Artifact 可导出单文件（SVG/PNG/复制），文档无标准项目导出。

**能力等级：G3–G4 并存**（总评取 G4 依据最强的文档工作区）。依据：
- G3 由 HTML/React/Sandpack 可执行 Artifact 与云端代码沙箱支撑（`Artifacts/Body/Renderer/React/index.tsx`、`builtin-tool-cloud-sandbox`）；
- G4 由文档对象（DB 行 + editorData 双格式）、历史快照与对比、编辑器内 diff 接受/拒绝、Redis 编辑锁、模型经 Page-Agent/lobe-agent-documents 定向修改同一对象（节点 ID 寻址、load rules 回流）构成（`services/document/index.ts`、`serverRuntimes/pageAgent.ts`、`agentDocuments/index.ts`）。

未达 G5 的差距：内容型 Artifact 无独立对象身份与模型寻址能力，仅靠整段重生成；沙箱文件为临时会话资产，导出后才成为持久文件；无桌面级长期活对象挂载。

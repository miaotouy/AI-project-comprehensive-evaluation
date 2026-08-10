# DeepChat 生成式输出与运行时调查笔记

> 调查对象：`../../deepchat`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`dc4177c2ac80905ebac985554a9f957aaca31ab8`（分支：`dev`）
>
> 调查方式：静态代码调查；grep/glob 关键词检索（artifact、canvas、sandbox、iframe、mcp-app、exec、runtime、notebook、diff、patch 等），通读消息块累积器、回显通道、Artifact 解析/渲染组件、MCP App 沙箱主链与 Agent 工具管理器；未安装依赖，未运行构建、单元测试或应用
>
> 调查范围：Artifact 对象（协议、解析、投影、持久化、回流）、MCP App 沙箱运行时、Agent exec/文件/图像工具的执行与权限、工作区文件预览与 Git diff 投影；消息流式更新链中的生成侧（echo 节流与 DB 落盘）；未覆盖：与 Chat 类目重叠的会话/分支/重试语义、浏览器工具（YoBrowser）内部实现、插件打包与发布治理、AC 协议（ACP）宿主细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 有三条可区分的生成式输出机制，共享同一消息对象模型：

1. **Artifact 对象**：模型在消息正文中输出 `<antArtifact>` XML 标记（6 种 MIME 类型），由内置内存 MCP 服务器 `Artifacts` 通过 `get_artifact_instructions` 工具注入使用规范。渲染器把标记解析为独立对象，在消息内显示卡片，并在右侧工作区面板（Workspace）中提供预览/代码双视图。对象事实源是消息块正文原文（SQLite），没有独立对象表。
2. **MCP App 沙箱**：任何 MCP 工具若声明 `ui` 元数据与 `text/html;profile=mcp-app` 资源，其 HTML 结果可进入 `mcp-app://` 协议的双层 iframe 沙箱，通过 JSON-RPC/postMessage 桥回宿主调用工具、资源、发消息与更新模型上下文，全部能力需用户逐次同意。
3. **Agent 本机执行**：`exec`/`process` 工具在本机 shell 中执行命令（目录白名单 + 命令权限审批 + 后台会话），`write`/`edit` 写文件，`read`/glob/grep 读工作区，图像生成工具产出 image 块。

**能力等级判定：`G3`（可执行 Artifact）**。HTML/React Artifact 进入带 `sandbox` 属性的 iframe 运行环境（脚本可执行、依赖经 `deepcdn://` 本地协议注入）；Agent exec 在宿主进程的子进程执行任意 shell 命令（经权限审批）。**未达 G4**：用户对 Artifact 无编辑保存通道（工作区代码视图显式只读，消息内编辑器无写回路径）；**未达 G5**：对象依附于消息文本，无独立环境级生命周期。

## 系统边界与完整主链路

- **输出协议层**：`<antArtifact>`/`<antThinking>`/`<tool_call>` 等文本标记（renderer 解析，`src/renderer/src/composables/useArtifacts.ts`）。
- **生成侧**：主进程 Agent 循环把模型文本按 token 追加进 `content` 块（`src/main/agent/deepchat/runtime/accumulator.ts`），按 120ms/600ms 节流快照给渲染器与数据库（`echo.ts`）。
- **投影侧**：消息内 ArtifactPreview 卡片 + 工作区侧栏 WorkspacePanel/WorkspaceViewer + 全文/预览视图。
- **执行侧**：iframe（Artifact HTML/React、MCP App、工作区文件预览）+ 本机子进程（Agent exec）+ 主进程内存 MCP 服务器。
- **持久化侧**：SQLite `deepchat_assistant_blocks`（text_content 为原始文本）。

**主链路（已走通，静态验证）**：

```
用户发送消息
  → 会话装配 Artifacts 内存 MCP 服务器（DEFAULT_ENABLED_SERVER_NAMES，src/main/mcp/settings.ts:249）
  → 模型按需调用 get_artifact_instructions（src/main/mcp/inMemoryServers/artifactsServer.ts:569-620）
  → 模型文本携带 <antArtifact identifier=type=title=language=>…</antArtifact>
  → accumulator.ts:99-107 把 text 事件追加进 content 块（token 级）
  → echo.ts:24-57 每 120ms 全块快照发 chat.stream.updated；每 600ms updateAssistantContent 落库
  → 渲染器 MessageBlockContent.vue:95-143 对内容快照做 memo 化解析并同步 artifactStore
  → 消息内出现 ArtifactPreview 卡片（ArtifactPreview.vue）
  → 点击卡片 → sidepanelStore.selectArtifact → WorkspacePanel/WorkspaceViewer 打开
  → 预览视图：Markdown/HTML(iframe)/SVG/Mermaid/React(iframe)；代码视图：只读 Monaco
  → 复制：deviceClient.copyText；HTML/React 依赖经 deepcdn:// 协议读取本地 cdn 目录
  → 重新打开会话：SQLite 读回 block.text_content → 相同解析路径，Artifact 恢复
  → 回流：contextBuilder.ts:928-938 把 content 块原文作为 assistant 文本传入模型，
    标记中的 identifier 随上下文可见，模型可复用 identifier 生成"更新版"（协议层约定，见 artifactsServer.ts:40）
```

**模型可继续维护闭环（部分存在）**：模型通过上下文读取已生成的 Artifact 原文并以同一 `identifier` 输出新版本，新版本作为新消息出现，旧版本不会被覆盖（无对象级更新，只有文本追加/重发）。Artifact 列表与状态不可被模型查询（无对象清单工具）。

## 1. 触发方式、输出协议与对象模型

### 触发方式

- 触发源是**模型自由文本**中的 XML 标记，无独立结构化 part，无用户命令触发。
- 使用规范通过 MCP 工具 `get_artifact_instructions` 注入（`artifactsServer.ts:573-585`），提示词明确要求：>15 行、可复用、独立成文的内容才用 Artifact；一个消息最多一个；更新时**复用旧 identifier**（`artifactsServer.ts:38-41`）。
- 该服务器是主进程内内存 MCP 服务器，默认启用（`mcp/settings.ts:249` `DEFAULT_ENABLED_SERVER_NAMES = ['Artifacts', ...]`），由 `inMemoryServerFactory` 在 `mcpClient.ts:514-517` 创建。

### 输出协议

- 标记格式：`<antArtifact identifier="…" type="…" title="…" language="…">content</antArtifact>`，类型白名单为：
  `application/vnd.ant.code` / `text/markdown` / `text/html` / `image/svg+xml` / `application/vnd.ant.mermaid` / `application/vnd.ant.react`（`useArtifacts.ts:43-49`）。
- 解析器是 renderer 的正则扫描器 `generatePart`（`useArtifacts.ts:322-499`）：
  - 处理**半截流**：未闭合的 `ARTIFACT_UNCLOSED_RE` 会在流式期间把剩余文本当作 loading 态 Artifact（`useArtifacts.ts:97-98, 300-319`）；
  - 处理嵌套/转义：正则要求属性 `type`/`identifier`/`title` 出现在开标签内（lookahead），内容为懒惰匹配到 `</antArtifact>`，不支持转义、不支持嵌套；
  - 误触发面：仅白名单 6 种 type 才被识别为 artifact part，其它内容按文本渲染；`<tool_call>`/`<tool_response>` 等标记被同一定位（`NEXT_TAG_RE`），与 Artifact 并存于同一正文流；
  - 有 last-parse memo（`useArtifacts.ts:157-159`），流式重复解析同字符串时直接返回缓存。
- 输入侧安全过滤：深链粘贴内容在 `src/main/deeplink/index.ts:666-693` 对 `antArtifact` 内容做危险模式扫描（script/iframe/javascript:/on*= 等），命中即整段丢弃。

### 对象模型

- **无独立对象存储**：Artifact 没有自己的表、ID 体系或版本号。对象身份 = `(messageId, blockId, identifier)` 三元组；`identifier` 只是模型自选字符串，宿主不校验唯一性（同一消息内同 identifier 的多个 Artifact 会作为多项显示）。
- 消息块的 `artifact?` 字段（identifier/title/type/language）在展示模型 `displayMessage.ts:152-163` 中定义，但持久化时**不单独落列**：`deepchatAssistantBlocks.ts:80-102` 只存 `text_content` 原文与 `extra_json`，artifact 属性靠 renderer 重新解析文本获得。运行中的 `ArtifactState`（`stores/artifact.ts:5-12`）是内存视图，含 id/type/title/content/status/language。
- 事实源层级：消息块原文（SQLite）→ 渲染时解析 → 运行态 Pinia store 缓存。三者由 renderer 单向往 artifactStore 同步（`MessageBlockContent.vue:95-143`），不存在用户侧反写路径。
- 对话级开关：`conversations.artifacts` 列（`src/main/data/schemaCatalog.ts:74`）存在，但本次仅在导出器 `nowledgeMemExporter.ts:206` 读到其使用；UI 侧是否暴露该开关未验证。

## 2. 增量生成、更新与最终化

- **生成粒度**：token 级追加到当前 `content` 块（`accumulator.ts:99-107`），一个块内直接 `block.content += event.content`；未闭合的 `<antArtifact>` 在渲染侧随文本逐 token 增长，解析器以"未闭合即 loading"处理（`useArtifacts.ts:300-319`）。
- **投影刷新**：全块快照，非 diff。`echo.ts:24-37` 每 120ms 把整块数组序列化后发 `chat.stream.updated`（`kind: 'snapshot'`），renderer 用 memo 化解析（`generatePart` 缓存 + `MessageBlockContent` 快照比对）避免每帧重算。
- **落盘**：每 600ms 节流 `updateAssistantContent` 整体替换块（`echo.ts:39-57`）；停止/错误/中止时 `flush()` 全量收口。
- **最终化**：`accumulator.ts:26-38` 把尾部的 pending narrative 块置为 success；error 事件把 pending 块全置 error 并追加 error 块（`accumulator.ts:266-281`）；工具批处理收口在 `dispatch.ts` 的 `settleToolBatch`/`finalize`（未逐行核实其全部分支，属次要环节）。
- **更新语义**：Artifact 内容更新唯一途径是模型在新消息里复用同一 identifier 再生成一份；旧消息内容不变，工作区列表按 createdAt 排序会把新版排前，但没有"合并/覆盖"操作（见 §6）。

## 3. 投影表面与多视图关系

| 表面 | 组件 | 位置 |
|---|---|---|
| 消息内卡片 | ArtifactPreview.vue（图标+标题+chevron，点击进工作区） | 消息正文内 |
| 消息内内联渲染 | ArtifactBlock.vue（含各类型渲染器 + 复制按钮） | 消息正文内 |
| 工作区列表 | WorkspacePanel.vue 的 artifacts 分区 | 右侧侧栏 |
| 工作区查看器 | WorkspaceViewer.vue + WorkspacePreviewPane / WorkspaceCodePane | 侧栏主区，可全屏 |
| 侧栏独立标签 | ChatSidePanel.vue 的 mcp-app 标签页（MCP App 专用） | 侧栏 |
| 外部位移 | McpAppView fullscreen/pip 模式（Teleport 到 body） | 覆盖层 |

- 同一 Artifact 可同时出现在消息卡片与工作区列表（列表来自对所有 assistant 消息的实时解析，`WorkspacePanel.vue:273-301`），两处共享 `artifactStore`，内容为同一内存对象，无编辑所以不存在不同步问题。
- 视图模式：preview/code 双标签（`useWorkspaceViewerModel.ts:78-107`）；`application/vnd.ant.code` 类型强制 code 视图（`:118-124`）。
- 文件投影（工作区）：`workspaceReadFilePreviewRoute` 提供 markdown/html/pdf/svg/image/text/binary 等预览，HTML/SVG/PDF 经 `workspace-preview://` 协议 iframe 呈现（`protocols.ts:250-299` + `workspacePreviewProtocol.ts`），与 Artifact 预览共用 WorkspacePreviewPane。
- 桌面挂件/窗口投影：本次未找到（无 artifact 桌面挂件；浮动窗口仅用于浏览器/CUA 预览，`src/renderer/src/floating`、`src/main/desktop/floatingButton`）。

## 4. 表现类型、依赖与运行环境

- **Markdown**：MarkdownRenderer（markstream-vue）内联渲染；仅样式/代码高亮，无独立生命周期（属消息渲染器范畴）。
- **SVG**：SvgArtifact.vue 直接注入（v-html 风格渲染，内容来自模型，见 `SvgArtifact.vue:28` 的 content 容器）。
- **Mermaid**：markstream-vue 的 MermaidBlockNode 渲染。
- **HTML Artifact**：`HTMLArtifact.vue:4-11` 用 `iframe srcdoc=block.content`，`sandbox="allow-scripts allow-same-origin"`，预览模式注入 viewport meta 与 reset CSS。**脚本可执行**，同源允许但 iframe 无宿主 DOM 访问（沙箱属性在渲染进程层生效，非 CSP 头）。
- **React Artifact**：`ReactTemplate.ts:1-46` 把模型内容包进带 `deepcdn://` 引用的 HTML 模板（react/react-dom/babel/lucide/prop-types/Recharts/tailwind），`ReactArtifact.vue` 以 `sandbox="allow-scripts"`（无 allow-same-origin）的 iframe srcdoc 加载；`deepcdn://` 由主进程协议处理器只读本地 `resources/cdn` 目录（`protocols.ts:154-205`，含路径越界检查 `resolvePathInsideRoot`）。依赖为内置本地副本，无外网 CDN。
- **Code Artifact**：Monaco（stream-monaco）只读展示 + 复制；`CodeArtifact.vue:70-74` 未传 readOnly，可编辑与否取决于 stream-monaco 默认值（node_modules 未安装，无法核实）；**无论可不可编辑都没有写回路径**。
- **图像生成**：`agentImageGenerationTool.ts` 走供应商图像模型，结果转为独立 image 块（`imageGenerationBlocks.ts:42-58` 把 imagePreviews 提升为 `type:'image'` 块）。
- **MCP App**：见 §7。
- 工作区文件 HTML 预览 iframe：`WorkspacePreviewPane.vue:189-195` 同样 `sandbox="allow-scripts allow-same-origin"`，经 `workspace-preview://` 协议由主进程流式供档（协议响应带 `X-Content-Type-Options: nosniff`，`protocols.ts:271-277`）。
- 视频/音频/Canvas/WebGL/notebook：本次未找到（grep `notebook|Notebook` 主进程无命中，renderer 仅图标名；canvas 仅用于 CUA/浏览器 PiP 帧缓冲与图片压缩，非生成式画布；accumulator 只处理 text/reasoning/plan/tool_call/image_data/usage/stop/error 事件）。

## 5. 用户交互、事件与错误反馈

- **Artifact**：
  - 卡片点击开/关工作区（`ArtifactPreview.vue:296-320`，含"再次点击同一对象则关闭"的等价判定）；
  - 复制按钮：`deviceClient.copyText`（`ArtifactBlock.vue:87-91`、`CodeArtifact.vue:181-191`）；
  - HTML/SVG 代码预览按钮：`CodeArtifact.vue:194-217` 把代码临时转成 Artifact 打开（`temp-<lang>-<id>`）；
  - 工作区查看器：preview/code 切换、全屏（`WorkspaceViewer.vue`）；文件视图可"打开外部文件"（`workspaceOpenFileRoute`）；
  - 流式期间 ArtifactThinking.vue 显示"生成中"占位，`artifact_think_collapse` 设置持久化（`ArtifactThinking.vue:18-27`）；
  - **导出/另存**：`useArtifactExport.ts`（SVG 导出/Mermaid 渲染、代码下载、复制为图片）**无任何组件调用**（grep 全文仅定义处命中），即导出按钮本次未找到；工作区查看器对 Artifact 无下载/保存按钮。
- **工具调用反馈**：`MessageBlockToolCall.vue` 提供参数/响应折叠视图、exec/终端输出样式、`editText`/`textReplace` 的 diff 视图（`:543-576` 从响应 JSON 提取 original/updated 渲染 CodeBlockNode diff）、图像预览徽标与缩略图、长时工具自动展开（`:482-492`）、子代理任务卡、权限审批状态环。错误状态映射在 `displayMessage.ts:141-150` 与块 status 上。
- **交互状态恢复**：展开/收起、viewMode、全屏是 renderer 内存态（sidepanel store），重新打开应用后不保留；Artifact 内容本身从 DB 恢复。未发现交互状态持久化。
- **MCP App**：见 §7。

## 6. 编辑、diff、版本与协作

- **用户编辑：不存在**。
  - 工作区代码视图显式只读：`WorkspaceCodePane.vue:38-39` `readOnly: true, domReadOnly: true`；
  - 消息内 CodeArtifact 编辑器无保存/写回（renderer 无任何 `updateAssistantContent` 或消息补丁 IPC，grep 无命中）；
  - Artifact 编辑/接受/拒绝/撤销/分支机制本次未找到。
- **模型侧"编辑"**：模型通过 `write`/`edit` 工具改**工作区文件**（文件 diff 见下），Artifact 则只能整段重发（协议要求"完整内容，不得截断"，`artifactsServer.ts:46`）。
- **文件级 diff（属于本类目的交点）**：`WorkspaceDiffView.vue` + `workspaceGetGitDiffRoute` 展示工作区 Git diff（staged/unstaged，`WorkspaceViewer.vue:94-127`）；工具响应内联 diff 渲染见 §5。均为只读展示，无应用/拒绝操作（git 操作属文件与项目工作区类目，交接点在此）。
- **版本/CRDT/协作：未找到**。Artifact 无版本字段；同 identifier 的多代内容以多条消息并存。

## 7. 能力桥、执行位置与权限范围

### 7.1 MCP App 沙箱（最完整的受控运行时）

- **执行位置**：renderer 中 `<iframe :src="mcp-app://{instanceId}/sandbox.html">`（`McpAppView.vue:567-582`）；主进程 `protocol.handle(MCP_APP_SCHEME)` 返回沙箱代理页（`sandboxProtocol.ts:198-234`），代理页再创建内层 `sandbox="allow-scripts allow-same-origin allow-forms"` iframe 写入 App HTML（`:94-96, 140-144`）。双层结构把 `mcp-app://` 协议源与 App 内容的执行源隔离。
- **协议约束**：代理页响应带动态 CSP 头（`buildMcpAppContentSecurityPolicy`，`:25-43`：default-src 'none'，script/style 仅 self+unsafe-inline+声明域，connect-src 默认 'none'，frame-src 默认 'none'，object/form-action 禁用）与 Permissions-Policy（camera/microphone/geolocation/clipboard-write 默认关闭，`:45-55`）。CSP 域声明来自工具资源的 `_meta.ui.csp`，经 `appHost.ts:60-123` 严格归一化（拒绝 `*`、凭据、非 https 等）。
- **桥**：JSON-RPC 2.0 over postMessage（官方 `@modelcontextprotocol/ext-apps/app-bridge`，`McpAppView.vue:236-351`），消息大小上限 20MiB，`isBoundedRpcMessage` 校验；代理页还校验自己处于 iframe 且与宿主隔离（`sandboxProtocol.ts:75-82`）。
- **能力桥（全部需同意或审批）**：
  - 调工具：`callAppTool` → `appHost.ts:293-400`，经 ToolPermissionBroker 逐次审批，拒绝后 `toolAccessSuspended` 挂起（可 retry）；
  - 读资源/列工具：`listAppTools/readAppResource/...` → `appHost.ts:402-525`；
  - 打开外链：`openAppLink` → 用户同意后 `shell.openExternal`（`appHost.ts:527-544`，仅 http/https 无凭据）；
  - 发送消息：`authorizeAppMessage` 同意后写入会话（`McpAppView.vue:328-335`，`appHost.ts:546-566`）；
  - 更新模型上下文：`updateAppModelContext` 同意后把内容**持久化到消息块**（`deepchatAssistantBlocks.ts:223-271` `updateMcpAppModelContext`），供后续回合回流。
- **实例生命周期**：`McpAppSandboxRegistry` 限额 64 实例/窗口 32（`sandboxRegistry.ts:14-15`），TTL 30 分钟（`:11`），webContents 销毁/服务器变更/源不匹配（`validateLive` + `assertDescriptorCurrent`，校验 configGeneration/bindingHash）即撤销；同意请求 2 分钟超时、去重、上限 64（`:12-13, 297-308`）。**重载后实例不恢复**（内存态），但持久化工具结果里的 `app` 描述符（`resultProjection.ts:137-156`）允许重新 prepare 一个新的沙箱实例——恢复的是"可再生视图"而非原实例状态。
- **来源校验**：App HTML 必须来自 MCP 资源（`text/html;profile=mcp-app`，2MiB 上限，`appHost.ts:146-168, 247`）；每次 prepare/callTool 都重新校验工具声明与持久化结果一致（`assertBoundServerCurrent` 等）。

### 7.2 Agent 代码执行（本机进程）

- **exec 工具**：`agentBashHandler.ts` 经 `spawn(shell)` 在**主进程本机**执行（`runDetachedShellProcess`/`runManagedShellProcess`），默认超时 120s、kill 宽限 5s（`:31-33`），目录限定 `allowedDirectories`（工作区根 + skill 根 + 会话目录 + temp + 用户批准路径，`agentToolManager.ts:1323-1377`），cwd 越界拒绝（`agentBashHandler.ts:233-250`）。
- **权限**：`CommandPermissionService` 分级（low/medium/high/critical）审批，未批准抛 `CommandPermissionRequiredError` 转为 UI 审批请求（`agentBashHandler.ts:121-138`）；文件读写走 `FilePermissionService`（read/write/all，`agentToolManager.ts:885-889`）。
- **后台会话**：`backgroundExecSessionManager` 支持 background/yield 与 `process` 工具（list/poll/log/write/kill/clear/remove，`agentToolManager.ts:891-986`），输出超 10k 字符落会话目录 log 文件（`agentBashHandler.ts:33, 487-511`）。
- **命令改写**：RTK（`rtkRuntimeService`）对命令做受限改写，失败自动回退原文（`agentBashHandler.ts:604-637`）。
- **执行结果反馈**：工具输出作为 `tool_call.response` 存入块并展示（§5），错误/权限拒绝分别以 `tool_call_error` 与 `action_type=tool_call_permission` 表达。

### 7.3 Artifact 渲染器能力

- HTML/React iframe 仅能访问同源页与 `deepcdn://` 本地资源（React 模板的依赖来源），无任何宿主 API 桥（不同于 MCP App）；`allow-same-origin` 意味着 iframe 与渲染进程同源，脚本可读主页面 DOM 属理论风险面（沙箱属性未加 CSP 头约束，属静态推断，未运行验证）。

## 8. 持久化、恢复、分享与导出

- **持久化对象**：SQLite 表 `deepchat_assistant_blocks`，`text_content` 存 content 块原文（含 `<antArtifact>` 标签），`extra_json` 存 extra/tool_call 附加信息（`deepchatAssistantBlocks.ts:80-166`）；助手消息行在 `deepchat_messages`（`tables/deepchatMessages.ts:42`）。
- **恢复**：重新打开会话 → 读块 → renderer 重新解析 → artifactStore 同步（`MessageBlockContent.vue:95-143` 与历史加载共用同一解析链）。Artifact 在会话重载后**可恢复**，但交互状态（展开、viewMode、侧栏上下文）不恢复。
- **复制/分享**：仅文本复制（copyText）；`useArtifactExport.ts` 的 SVG/代码导出与"复制为图片"未被任何组件接入（见 §5）；无 artifact 级分享 URL。
- **导出**：会话导出（`conversationExporter.ts:371-429`）把 content 块原样带出（`formatInlineHtml(block.content)`），`artifact-thinking` 块单独渲染为"创作思考"模板（`conversationExportTemplates.ts:127-132`）；MCP App 的模型上下文随块 extra_json 持久化。
- **deepcdn 资源**：随应用打包在 `resources/cdn`（`protocols.ts:159-165`）。
- 图像生成产物：base64 存块（`image_data`），`image_mime_type` 列（`deepchatAssistantBlocks.ts:158`）。

## 9. 模型回流、对象感知与持续维护

- **回流通道（存在）**：`contextBuilder.ts:928-938` 把 content 块原文并入 assistant 消息文本传给模型；Artifact 标签随之完整可见。协议指令要求更新时复用 identifier（`artifactsServer.ts:40`），因此模型可以在后续回合"续写"同一对象——以新消息形式。
- **对象感知（部分）**：模型能读到自己生成的 Artifact 原文（来自上下文），但**不能**查询对象列表、状态或独立读取某个 identifier 的当前版本（无 artifact 查询工具）；同 identifier 的多代内容混在上下文里，模型需自行区分新旧。
- **状态回流（MCP App 例外）**：MCP App 的 `updateModelContext` 经用户同意后写入块并随上下文回流（`deepchatAssistantBlocks.ts:223-271` + `compactionService.ts:226` 的 `formatApprovedMcpAppModelContext` 在压缩时保留），是本次找到的唯一的"对象状态写回模型上下文"通道。
- **持续维护能力评估**：模型可以持续"重发整版"维护 Artifact，宿主不做去重/合并/定位替换；无 G5 级对象身份绑定（无稳定对象 ID 之外的地址机制；identifier 非宿主签发、不唯一、不校验）。

## 10. 生命周期、资源治理与性能

- **Artifact**：无独立生命周期。随消息块存在；预览 iframe 随组件卸载销毁；`artifactStore` 是内存态，切换会话/侧栏关闭时由 watcher 清理上下文（`WorkspacePanel.vue:339-363`）。
- **MCP App**：见 §7.1——TTL、实例上限、webContents 销毁回收、consent 超时、服务器绑定变更失效，是本项目最完整的资源治理。
- **进程**：exec 超时 + 进程树终止（`terminateProcessTree`）；后台会话由 `backgroundExecSessionManager` 登记，会话目录 log 落盘（`agentBashHandler.ts:487-511`）；未发现运行中进程清单的应用级限额（限额在权限层）。
- **流式性能**：renderer 端 120ms 节流 + 解析 memo（`useArtifacts.ts:157-159`）+ `MessageBlockContent` 快照比对；DB 600ms 节流。全块快照序列化（含 JSON schema 校验 `cloneBlocksForRenderer`）在超长输出下成本线性，未见增量 diff 机制。
- **长会话**：上下文预算/压缩（`contextBudget.ts`/`compactionService.ts`）会把 Artifact 文本随消息压缩，压缩后标记可能丢失对象形态（`compactionService.ts:210` 只保留 content 文本行，未验证压缩产物对 antArtifact 标签的保留策略）。

## 11. 测试、已确认边界与未验证事项

### 测试覆盖（静态确认存在，未运行）

- `test/renderer/composables/useArtifacts.test.ts`：协议解析、半截流（loading artifact）、memo 缓存、extractArtifactsFromContent。
- `test/renderer/components/WorkspacePanel.test.ts`、`message/MessageBlockContent.test.ts`：Artifact 列表与块解析联动。
- `test/renderer/components/McpAppView.test.ts`：App 视图挂载/桥接。
- `test/main/mcp/mcpAppHost.test.ts`、`mcpAppSandboxRegistry.test.ts`、`mcpAppSandboxProtocol.test.ts`：prepareView、实例注册、CSP 构造。
- 未覆盖（本次 grep 未见）：Artifact 保存/恢复的端到端测试、iframe 执行的行为测试、回流（identifier 复用）的协议测试、导出路径测试。

### 已确认边界（源码级）

1. 用户不可编辑 Artifact，无保存/导出按钮（§5/§6，grep 范围 `src/renderer/src/components`、`composables`）。
2. `useArtifactExport` 与 `artifactStore.updateArtifactContent`/`dismissArtifact` 为未接入代码。
3. `artifact-thinking` 块类型仅在 mock 会话、导出器与 remote blockRenderer 中处理，主生成路径不产生该块（模型输出 `antThinking` 由 renderer 文本解析呈现）。
4. cron 任务的 `task_output_mode='artifact'` 选项仅落库（`scheduler/data/tables/cronJobs.ts:100`），执行链路未读取（grep `task_output_mode` 仅 repository 与表定义命中），属未接线选项。
5. React Artifact 依赖全部来自本地 `deepcdn://`，无外网加载。
6. MCP App 是"可再生沙箱视图"，非跨重载持久运行实例。

### 未验证事项（未运行）

- 未安装 node_modules，未运行应用/测试/构建；一切 UI 行为（卡片交互、iframe 渲染、编辑器可编辑性、全屏/PiP）为静态推断。
- stream-monaco 默认是否只读未核实（影响消息内 CodeArtifact 的可编辑外观，不影响"无写回路径"结论）。
- HTML Artifact `allow-same-origin` 的实际隔离强度、`deepcdn://` 在打包环境（asar.unpacked）的资源定位未运行验证。
- 压缩（compaction）对 `<antArtifact>` 标签的保留策略未验证。
- 深链净化规则（`deeplink/index.ts:666-693`）只覆盖深链入口，消息编辑等其他入口的净化未核实。

## 12. 关键源码索引

- 输出协议与解析：`src/renderer/src/composables/useArtifacts.ts:93-113`（正则）、`:322-499`（generatePart）
- 协议规范注入：`src/main/mcp/inMemoryServers/artifactsServer.ts:5-49`（指令）、`:569-620`（tools/list、tools/call）、`src/main/mcp/settings.ts:249`（默认启用）
- 生成与流式：`src/main/agent/deepchat/runtime/accumulator.ts:99-107`、`src/main/agent/deepchat/runtime/echo.ts:24-57`
- 渲染投影：`src/renderer/src/components/artifacts/ArtifactPreview.vue`、`ArtifactBlock.vue`、`src/renderer/src/components/sidepanel/WorkspacePanel.vue:273-301`、`WorkspaceViewer.vue`、`src/renderer/src/components/sidepanel/composables/useWorkspaceViewerModel.ts:44-59`
- Artifact 运行环境：`HTMLArtifact.vue:4-11`、`ReactArtifact.vue` + `ReactTemplate.ts:1-46`、`src/main/app/protocols.ts:154-205`（deepcdn）、`CodeArtifact.vue:70-74`、`WorkspaceCodePane.vue:37-39`
- MCP App：`src/main/mcp/apps/sandboxProtocol.ts:57-177`（代理页）、`:25-43`（CSP）、`src/main/mcp/apps/appHost.ts:218-286`（prepareView）、`src/main/mcp/apps/sandboxRegistry.ts:11-15`（限额/TTL）、`src/main/mcp/resultProjection.ts:137-156`（app 描述符）、`src/renderer/src/components/mcp/McpAppView.vue:229-351`（桥）
- 执行与权限：`src/main/tool/agentTools/agentBashHandler.ts:99-213`、`src/main/tool/agentTools/agentToolManager.ts:704-842`（工具定义）、`:1323-1377`（目录白名单）、`src/main/tool/permission/commandPermissionService.ts`、`agentImageGenerationTool.ts`
- 持久化：`src/main/session/data/tables/deepchatAssistantBlocks.ts:80-166`、`deepchatAssistantBlocks.ts:223-271`（App 模型上下文回流）
- 回流：`src/main/agent/deepchat/runtime/contextBuilder.ts:928-938`
- 工具调用展示：`src/renderer/src/components/message/MessageBlockToolCall.vue:543-576`（diff）、`:482-492`（自动展开）
- 导出：`src/main/exporter/formats/conversationExporter.ts:371-429`

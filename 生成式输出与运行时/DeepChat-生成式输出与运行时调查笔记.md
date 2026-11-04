# DeepChat 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`（重点 `src/main/mcp/apps/`、`src/main/tool/agentTools/`、`src/renderer/src/components/mcp/`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`3db91f876ad903b17215da94cd1a4a6398823dad`（分支：`dev`）
>
> 调查方式：静态代码调查；grep/glob 关键词检索（artifact、canvas、sandbox、iframe、mcp-app、exec、runtime、notebook、diff、patch 等），通读 MCP App 沙箱主链、Agent 工具执行与图像链路、消息流式更新链；未安装依赖，未运行构建、单元测试或应用
>
> 调查范围：内置 Artifact 的退役与历史兼容、MCP App 沙箱运行时、Agent exec/文件/图像工具的执行与权限、工作区文件预览与 Git diff 投影、消息流式更新链中的生成侧；未覆盖：与 Chat 类目重叠的会话/分支/重试语义、浏览器工具（YoBrowser）内部实现、插件打包与发布治理、ACP 宿主细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 不再把模型输出物化成可执行的内置 Artifact 对象。Agent 改为创建工作区文件并用浏览器工具承载交互式内容；内置 Artifact 的生成、预览与执行运行时已移除，历史消息只保留“标题 + 可复制原文”的静态兼容视图（`docs/architecture/remove-built-in-artifacts/spec.md`）。当前承担生成式输出运行面的机制有四条：

1. **历史 Artifact 兼容层**：消息里的 `<antArtifact>`/`<antThinking>` 文本仍被解析，但只渲染标题与原文并提供复制，HTML、SVG、React、Mermaid 一律不执行，也不触发工作区面板。保留旧消息类型、解析与导出支持，无需数据库迁移。
2. **MCP App 沙箱**：任何 MCP 工具若声明 `ui` 元数据与 `text/html;profile=mcp-app` 资源，其 HTML 结果可进入 `mcp-app://` 协议的双层 iframe 沙箱，通过 JSON-RPC/postMessage 桥回宿主调用工具、资源、发消息与更新模型上下文，全部能力需用户逐次同意。
3. **Agent 本机执行**：命令类工具在本机 shell 中执行（目录白名单 + 命令权限审批 + 后台会话），文件类工具读写工作区，图像生成工具产出 image 块。
4. **Provider 图像产物**：OpenAI Codex 图像生成走 Provider 适配层，结果作为聊天 image 块进入既有消息投影；工具响应中的 base64 图片预览会在主进程尽量转存为 `imgcache://`，单次最多处理 4 个不同预览。

**能力等级判定：`G3`（可执行输出环境）**。承载者是 MCP App 的受控 iframe 运行时与 Agent 的本机命令执行；内置 Artifact 级的 inline 运行时（HTML/React 预览 iframe、`deepcdn://` 依赖注入）已不存在。**未达 G4**：用户对 MCP App 与工作区文件都没有编辑保存通道（工作区代码视图显式只读）；**未达 G5**：没有脱离消息与文件、可被模型查询状态并定向维护的活对象。

## 系统边界与完整主链路

- **输出协议层**：历史 Artifact 标记文本（renderer 解析，`src/renderer/src/composables/useArtifacts.ts`）；MCP App 由 MCP 资源与工具结果中的 app 描述符声明。
- **生成侧**：主进程 Agent 循环把模型文本按 token 追加进 `content` 块（`src/main/agent/deepchat/runtime/accumulator.ts:141`），按 120ms/600ms 节流快照给渲染器与数据库（`echo.ts:6-7`、`:33`）。
- **投影侧**：消息内工具调用卡与历史 Artifact 原文块、侧栏工作区面板（subagents/files/git 三段）、工作区文件查看器、MCP App 标签页与全屏/PiP 覆盖层。
- **执行侧**：iframe（MCP App、工作区文件预览）+ 本机子进程（Agent exec）。
- **持久化侧**：SQLite `deepchat_assistant_blocks`（`text_content` 为原始文本，`extra_json` 存工具调用与 MCP App 模型上下文）。

**当前主链路（MCP App，已走通，静态验证）**：

```text
工具声明 ui 元数据与 mcp-app 资源
  → 工具结果投影出 app 描述符（resultProjection.ts:183，MIME text/html;profile=mcp-app）
  → renderer 打开 McpAppView，请求 mcp-app://{instanceId}/sandbox.html
  → 主进程沙箱协议返回代理页（sandboxProtocol.ts:95-230，动态 CSP + Permissions-Policy）
  → 代理页创建内层 sandbox="allow-scripts allow-same-origin allow-forms" iframe 写入 App HTML
  → App 通过 JSON-RPC/postMessage 请求 callTool / listTools / readResource / openLink /
    authorizeMessage / updateModelContext
  → appHost.ts:293-640 逐项做来源校验、权限审批与用户同意
  → 结果回 return 给 App；模型上下文写回消息块 extra_json
```

**历史兼容主链路**：SQLite 读回 `block.text_content` → renderer 的 `useArtifacts` 解析出 artifact part → `MessageBlockContent.vue:26-31` 渲染 `LegacyArtifactSource.vue`（标题 + `<pre>` 原文 + 复制按钮）→ 不再有预览、执行或面板跳转。

## 1. 触发方式、输出协议与对象模型

### 内置 Artifact 的退役

- 生成侧：`src/main/mcp/inMemoryServers/artifactsServer.ts` 删除，`get_artifact_instructions` 工具不再存在；MCP 设置的默认启用列表只剩 macOS 的 `deepchat/apple-server`（`src/main/mcp/settings.ts:242`），归一化时会把持久化下来的 `inmemory` 型 Artifacts 服务器剔除（`settings.ts:560`）。外部用户自建的 MCP server 不受影响。
- 渲染侧：`components/artifacts/` 全部组件、`stores/artifact.ts`、`useArtifact*` 组合式函数与 `resources/skills/web-artifacts-builder` 技能一起移除；普通 Markdown 代码块不再提供 Artifact 预览入口。
- 替代路径：Agent 用文件工具把内容写成工作区文件，交互式内容交给浏览器工具；规格明确不引入新的替代工具，也不自动把历史 Artifact 迁移成文件。

### 历史兼容与输出协议

- 解析器仍是 renderer 的 `useArtifacts`（`src/renderer/src/composables/useArtifacts.ts:58-110` 的正则集合、`:284` 起的 `generatePart`）：识别六种 type 的 `<antArtifact identifier type title language>`，未闭合标记在流式期间按 loading 处理；`message` 里已有结构化 artifact 字段时直接按 artifact part 展示。
- 兼容视图边界：`LegacyArtifactSource.vue` 只显示 `block.artifact.title` 与 `block.content` 原文，没有 iframe、没有渲染器分派、没有导出。历史的未闭合块同样可读。
- 输入侧净化保留：深链粘贴内容仍对 `antArtifact` 内部做危险模式扫描（script/iframe/javascript:/on*= 等），命中即丢弃整段（`src/main/deeplink/index.ts:666-700`）。
- 对象模型：历史 Artifact 在运行期不再有对象身份——没有 store、没有选择态、没有版本号；它只是消息块原文的一部分。唯一带宿主签发身份的输出对象是 MCP App 实例，身份由 `instanceId` 与工具结果里的 app 描述符共同构成，事实源是持久化的工具结果。

## 2. 增量生成、更新与最终化

- **生成粒度**：token 级追加到当前 content 块（`accumulator.ts:141` 起的 `accumulate`）；历史 Artifact 标记在兼容视图里随文本增长，但只更新纯文本。
- **投影刷新**：全块快照，非 diff。`echo.ts:6-7` 定义渲染器 120ms、数据库 600ms 两个节流间隔，渲染器侧拿整块数组序列化后发 `chat.stream.updated`，数据库侧整体替换块内容（`:33`）；renderer 用解析缓存与快照比对避免每帧重算。
- **落盘与最终化**：停止/错误/中止时 `flush()` 全量收口；`accumulator.ts` 把 pending narrative 块置为成功，error 事件把挂起块置错并追加错误块；工具批处理收口在 `dispatch.ts` 的 `settleToolBatch`/`finalize`（未逐行核实全部分支，属次要环节）。
- **更新语义**：模型不能再“重发同一个 Artifact”更新对象，也没有对象级替换；要改内容只能改写成工作区文件并用文件工具更新（`write`/`edit`），文件 diff 由工作区查看器展示。历史消息里的旧 Artifact 文本保持不变。

## 3. 投影表面与多视图关系

| 表面 | 组件 | 位置 |
|---|---|---|
| 消息内工具调用卡 | `MessageBlockToolCall.vue`（参数/响应折叠、diff、图像预览、权限徽标） | 消息正文内 |
| 历史 Artifact 原文块 | `LegacyArtifactSource.vue` | 消息正文内 |
| 工作区面板 | `WorkspacePanel.vue` 的 subagents / files / git 三段 | 右侧侧栏 |
| 工作区文件查看器 | `WorkspaceViewer.vue` + `WorkspacePreviewPane` / 代码面板 | 侧栏主区，可全屏 |
| MCP App 标签页 | `ChatSidePanel.vue` 的 mcp-app 标签页 | 侧栏 |
| MCP App 全屏/PiP | `McpAppView.vue` 的 fullscreen/pip 模式（Teleport 到 body） | 覆盖层 |

- 工作区面板只负责文件、Git 与实时委派，不再有 artifact 集合、选择与自动打开；文件预览与 Git diff 链路保持原行为（`WorkspacePanel.vue` 的 files/git 两段）。
- 文件投影：预览路由提供 markdown/html/pdf/svg/image/text/binary 等格式，HTML/SVG/PDF 经 `workspace-preview://` 协议 iframe 呈现（`WorkspacePreviewPane.vue:47`、`:157` 设置 `allow-scripts allow-same-origin`，主进程协议在 `src/main/app/protocols.ts`）。
- 工作区文件还可通过上下文菜单交给系统已安装应用。主进程按平台探测候选应用并用受控 launcher 打开，renderer 只显示可用列表；入口见 `src/main/workspace/openInApp/`、`src/shared/workspace/fileOpenApps.ts` 与 `WorkspaceViewer.vue:391`。
- 桌面挂件/窗口投影：本次未找到（浮动窗口仅用于浏览器/CUA 预览，`src/renderer/src/floating`、`src/main/desktop/floatingButton`）。

## 4. 表现类型、依赖与运行环境

- **Markdown/SVG/Mermaid**：均按普通消息渲染（MarkdownRenderer 与 markstream-vue 的代码块/Mermaid 节点），没有 Artifact 级运行环境；历史 Artifact 里的同类内容是纯文本。
- **MCP App**：见 §7.1，双层 iframe + 动态 CSP，是当前唯一由输出内容自带脚本并运行的环境。
- **工作区文件预览**：HTML/SVG/PDF 走 `workspace-preview://`；SVG 预览有独立组件 `WorkspaceSvgPreview.vue`；代码面板为只读 Monaco（`WorkspaceCodePane.vue`）。
- **图像生成**：`agentImageGenerationTool.ts` 走供应商图像模型，结果转为独立 image 块（`imageGenerationBlocks.ts:8-106` 负责预览呈现与块插入）。
- **图像持久化（#2094）**：生成图片经 `src/main/platform/imageCache.ts` 落盘并以 `imgcache://` 引用进消息文本，协议处理器在 `protocols.ts:207-230`；MCP 工具调用时参数里的 `imgcache://` 引用会被解析回 data URL；renderer 侧已提升为独立 image 块的图不再在 Markdown 中重复显示（消息渲染器笔记 §3）。
- **工具图片预览**：`cacheToolCallImagePreviews` 在工具结果写块前处理预览列表，HTTP(S) 与既有缓存引用直接保留，base64 尽量落盘为缓存引用并去重，最多 4 个不同输入（`src/main/lib/toolCallImagePreviews.ts:383`）；调用点在 `src/main/agent/deepchat/runtime/dispatch.ts:2325`。
- **deepcdn 协议**：注册与本地 `resources/cdn`（7 个文件）仍在（`protocols.ts:154-198`，`electron-builder.yml` 仍复制该目录），但本次在 renderer 与主进程业务代码中未找到 `deepcdn://` 的使用方；它随 Artifact 运行时退役后保留为未清理的注册面。
- 视频/音频/Canvas/WebGL/notebook：本次未找到（grep `notebook` 主进程无命中，renderer 仅图标名；canvas 仅用于 CUA/浏览器 PiP 帧缓冲与图片压缩）。

## 5. 用户交互、事件与错误反馈

- **历史 Artifact**：仅剩标题与复制按钮（`LegacyArtifactSource.vue`，`DcCopyButton` 复制整段原文）；没有点击打开工作区、没有 viewMode 切换、没有“生成中”占位。
- **工具调用反馈**：`MessageBlockToolCall.vue` 提供参数/响应折叠、exec/终端输出样式、文本编辑类工具结果的 diff 视图、图像预览徽标与缩略图、长时工具自动展开、子代理任务卡与权限状态环；状态字面量为 running/reviewing/error（`MessageBlockToolCall.vue:24-70`、`:360-620`）。
- **MCP App**：工具调用、读资源、打开外链、发送消息、更新模型上下文都走显式同意；同意请求有超时、去重与数量上限，拒绝后工具访问进入挂起态并可重试（§7.1）。
- **交互状态恢复**：展开/收起、viewMode、全屏属 renderer 内存态（sidepanel store），重新打开应用后不保留；MCP App 实例也不跨重载恢复。

## 6. 编辑、diff、版本与协作

- **用户编辑：不存在**。工作区代码视图显式只读（`WorkspaceCodePane.vue` 的 `readOnly`/`domReadOnly`）；历史 Artifact 是静态原文；MCP App 的内容由服务器资源决定，宿侧无编辑入口。
- **模型侧“编辑”**：模型用 `write`/`edit`/`apply_patch` 改工作区文件，文件级 diff 由 `WorkspaceDiffView.vue` + `workspaceGetGitDiffRoute` 展示（staged/unstaged，入口在 `WorkspaceViewer.vue`）；工具响应内联 diff 见 §5。均为只读展示，无应用/拒绝操作（git 操作属文件与项目工作区类目，交接点在此）。
- **版本/CRDT/协作**：本次未找到。历史 Artifact 无版本字段；MCP App 实例由服务器每次 prepare 重新生成。

## 7. 能力桥、执行位置与权限范围

### 7.1 MCP App 沙箱（最完整的受控运行时）

- **执行位置**：renderer 中 `<iframe :src="mcp-app://{instanceId}/sandbox.html">`（`McpAppView.vue`）；主进程协议处理器返回沙箱代理页（`src/main/mcp/apps/sandboxProtocol.ts:95-230`），代理页再创建内层 `sandbox="allow-scripts allow-same-origin allow-forms"` iframe 写入 App HTML。双层结构把协议源与 App 内容的执行源隔离。
- **协议约束**：代理页响应带动态 CSP（`buildMcpAppContentSecurityPolicy`，`sandboxProtocol.ts:25`）与 Permissions-Policy（`:230`）——默认拒绝一切加载，脚本与样式仅放行自身源、内联与声明域，连接与嵌套框架默认关闭，对象与表单动作禁用；CSP 域声明来自工具资源的 `_meta.ui.csp`，经 `appHost.ts` 严格归一化（拒绝 `*`、凭据、非 https 等）。
- **桥**：JSON-RPC 2.0 over postMessage（官方 app-bridge 库），消息大小经 `assertBoundedMcpJson` 上限校验；代理页还校验自己处于 iframe 且与宿主隔离。
- **能力桥（全部需同意或审批）**：
  - 调工具：`callTool`（`appHost.ts:293-400`）经 ToolPermissionBroker 逐次审批，拒绝后挂起并可 `retryToolAccess`（`:614`）；
  - 读资源/列工具：`listTools`/`readResource`/`listResources`/`listResourceTemplates`/`listPrompts`（`:402-525`）；
  - 打开外链：`openLink`（`:527-544`，用户同意后 `shell.openExternal`，仅 http/https 无凭据）；
  - 发送消息：`authorizeMessage`（`:546-566`，同意后写入会话）；
  - 更新模型上下文：`updateModelContext`（`:568-612`）同意后持久化到消息块（`deepchatAssistantBlocks.ts:263` 的 `updateMcpAppModelContext`），供后续回合回流。
- **实例生命周期**：`McpAppSandboxRegistry` 限额 64 实例、每 webContents 32、TTL 30 分钟、pending consent 上限 64（`src/main/mcp/apps/sandboxRegistry.ts:11-15`）；webContents 销毁、服务器变更或源不匹配（每次使用都校验配置代际与绑定哈希，`appHost.ts` 的 `assertBoundServerCurrent`）即撤销实例。**重载后实例不恢复**（内存态），但持久化工具结果里的 app 描述符（`src/main/mcp/resultProjection.ts:183`）允许重新 prepare 一个新实例——恢复的是“可再生视图”而非原实例状态。
- **来源校验**：App HTML 必须来自 MCP 资源（`text/html;profile=mcp-app`，2MiB 上限）；每次 prepare/callTool 都重新校验工具声明与持久化结果一致。

### 7.2 Agent 代码执行（本机进程）

- **exec 工具**：`agentBashHandler.ts` 经 `spawn(shell)` 在**主进程本机**执行（分离/托管两种子进程形态），默认超时 120s、kill 宽限 5s，目录限定 `allowedDirectories`（工作区根 + skill 根 + 会话目录 + temp + 用户批准路径），cwd 越界拒绝。
- **命令 shell 可配置（#2109）**：执行 shell 从用户默认 shell 改为解析后的命令 shell（`src/shared/commandShell.ts`：8 种 preference/profile，dialect 归为 posix、cmd、powershell 三种，pathStyle 有 native/win32/msys），按 dialect 拼命令与提示；RTK 改写只在 posix 方言启用；后台会话同样携带该配置；命令审批请求附带 shellProfile（Agent 工具笔记 §3）。
- **权限**：`CommandPermissionService` 按低/中/高/关键四级审批，白名单与破坏性/网络模式按 shell 方言分别匹配；文件读写走 `FilePermissionService`（read/write/all 三档），`auto_approve` 下的审阅范围由 `resolveAgentToolReview` 统一裁决（Agent 工具笔记 §3）。
- **输出预览与落盘**：执行结果按内联上限截取预览，超过阈值的完整输出落会话目录 log 文件；Agent 配置的 `commandOutputInlineChars`/`toolOutputInlineChars` 可调节（Agent 角色笔记 §1）。
- **后台会话**：`backgroundExecSessionManager` 支持 background/yield 与 `process` 工具（查询、轮询、日志、写入、终止、清理、移除），输出超限落会话目录 log 文件。
- **二进制读取放宽（#2110）**：`src/main/lib/binaryReadGuard.ts:69-80` 只拒绝固定二进制 MIME 与 audio/video，文本型 octet-stream 文件允许读取。

### 7.3 历史 Artifact 运行时

已不存在。历史消息不会因为被阅读而启动任何预览运行时或打开工作区面板（`remove-built-in-artifacts` 规格的验收项）。

## 8. 持久化、恢复、分享与导出

- **持久化对象**：SQLite 表 `deepchat_assistant_blocks` 的 `text_content` 存 content 块原文（含历史 `<antArtifact>` 标签），`extra_json` 存额外信息、工具调用与 MCP App 模型上下文（`deepchatAssistantBlocks.ts`）；助手消息行在 `deepchat_messages`。
- **恢复**：重新打开会话 → 读块 → renderer 重新解析 → 历史 Artifact 以原文块恢复；MCP App 由持久化描述符重新 prepare。
- **复制/分享**：历史 Artifact 仅文本复制；无对象级分享 URL、无导出按钮（导出辅助函数已随组件移除）。
- **导出**：会话导出把 content 块原样带出（`formatInlineHtml(block.content)`），`artifact-thinking` 块在导出器里仍单独渲染为“创作思考”模板（`conversationExporter.ts:244`/`:391`/`:637` 三处分支）；MCP App 的模型上下文随块 `extra_json` 持久化。
- 图像生成产物：base64 存块（`image_data`）并有 `image_mime_type` 列。

## 9. 模型回流、对象感知与持续维护

- **回流通道**：`contextBuilder.ts` 把 content 块原文并入 assistant 消息文本传给模型；历史 Artifact 标签只是普通文本，模型看到的是原文，不再有“复用 identifier 更新对象”的协议约定（指令工具已删除）。
- **对象感知**：模型可以读到 MCP App 工具结果与其模型上下文，但没有 artifact 列表/状态/版本查询能力；工作区文件的内容通过文件工具读取与修改。
- **状态回流（MCP App 例外）**：`updateModelContext` 经用户同意后写入块并随上下文回流（`deepchatAssistantBlocks.ts:263` + 压缩时保留的 `formatApprovedMcpAppModelContext`），是本次找到的唯一“对象状态写回模型上下文”通道。
- **持续维护能力评估**：模型可以持续修改工作区文件（有文件 diff 与工具级替换），但对消息内的历史 Artifact 与 MCP App 视图都只能整段重生成；无 G5 级对象身份绑定。

## 10. 生命周期、资源治理与性能

- **历史 Artifact**：无独立生命周期，随消息块存在；兼容视图不持有任何运行时资源。
- **MCP App**：TTL、实例上限、webContents 销毁回收、consent 超时、服务器绑定变更失效，是本项目最完整的资源治理。
- **进程**：exec 超时 + 进程树终止（`terminateProcessTree`）；后台会话由 `backgroundExecSessionManager` 登记，会话目录 log 落盘；应用级进程清单限额本次未找到（限额在权限层）。
- **流式性能**：renderer 端 120ms 节流 + 解析 memo + `MessageBlockContent` 快照比对；DB 600ms 节流。全块快照序列化在超长输出下成本线性，未见增量 diff 机制。
- **长会话**：上下文预算/压缩会截断历史消息文本；压缩后的历史 Artifact 文本与普通文本一并处理，兼容视图不依赖压缩前结构。

## 11. 测试、已确认边界与未验证事项

### 测试覆盖（静态确认存在，未运行）

- `test/renderer/composables/useArtifacts.test.ts`：历史标记解析、半截流兼容、memo 缓存。
- `test/renderer/components/WorkspacePanel.test.ts`：工作区文件/Git 面板。
- `test/renderer/components/McpAppView.test.ts`：App 视图挂载与桥接。
- `test/main/mcp/mcpAppHost.test.ts`、`mcpAppSandboxRegistry.test.ts`、`mcpAppSandboxProtocol.test.ts`：prepareView、实例注册、CSP 构造。
- 未覆盖（本次 grep 未见）：历史 Artifact 原文视图的快照测试、MCP App 端到端交互回放、导出路径测试。

### 已确认边界（源码级）

1. 内置 Artifact 生成与预览已退役：`artifactsServer.ts`、artifact 组件树、artifact store 与 `useArtifactExport` 均不存在；普通 Markdown 代码块不再提供 Artifact 预览。
2. 历史 Artifact 可读可复制，但不执行 HTML/SVG/React/Mermaid，也不触发工作区面板。
3. `artifact-thinking` 块仍由导出器与 `MessageItemAssistant` 的折叠判定处理，主生成路径不再产生该块。
4. deepcdn 协议与 `resources/cdn` 仍在，但本次未找到使用方。
5. MCP App 是“可再生沙箱视图”，非跨重载持久运行实例。

### 未验证事项（未运行）

- 未安装 node_modules，未运行应用/测试/构建；一切 UI 行为（历史块渲染、iframe 渲染、全屏/PiP）为静态推断。
- HTML/SVG 工作区预览与 MCP App 内层 iframe 的实际隔离强度、`workspace-preview://` 在打包环境的资源定位未运行验证。
- Windows 命令 shell 在各 dialect 下的实际执行差异、输出 offload 阈值行为、`imgcache://` 引用在 MCP 工具参数中的端到端解析均未运行验证。
- 压缩（compaction）对历史 `antArtifact` 文本的截断位置未验证。

## 12. 关键源码索引

- 历史 Artifact 解析与兼容视图：`src/renderer/src/composables/useArtifacts.ts`、`src/renderer/src/components/message/MessageBlockContent.vue:26-31`、`LegacyArtifactSource.vue`
- 退役规格：`docs/architecture/remove-built-in-artifacts/spec.md`
- Artifacts 服务器剔除：`src/main/mcp/settings.ts:242`、`:560`
- 生成与流式：`src/main/agent/deepchat/runtime/accumulator.ts:141`、`src/main/agent/deepchat/runtime/echo.ts:6-33`
- 工作区投影：`src/renderer/src/components/sidepanel/WorkspacePanel.vue`、`WorkspaceViewer.vue:391`、`viewer/WorkspacePreviewPane.vue:47-157`、`src/main/workspace/openInApp/`
- MCP App：`src/main/mcp/apps/sandboxProtocol.ts:25-230`（代理页/CSP）、`src/main/mcp/apps/appHost.ts:188-640`（能力桥）、`src/main/mcp/apps/sandboxRegistry.ts:11-15`（限额/TTL）、`src/main/mcp/resultProjection.ts:183`（app 描述符）、`src/renderer/src/components/mcp/McpAppView.vue:330`
- 执行与权限：`src/main/tool/agentTools/agentBashHandler.ts`、`src/main/tool/permission/commandPermissionService.ts`、`src/main/tool/permission/agentToolReviewPolicy.ts`
- 命令 shell：`src/shared/commandShell.ts`
- 图像链路：`src/main/platform/imageCache.ts`、`src/main/lib/toolCallImagePreviews.ts:383`、`src/main/agent/deepchat/runtime/dispatch.ts:2325`、`src/main/agent/deepchat/runtime/imageGenerationBlocks.ts:8-106`、`src/main/app/protocols.ts:154-230`
- 持久化与回流：`src/main/session/data/tables/deepchatAssistantBlocks.ts:263`、`src/main/agent/deepchat/runtime/contextBuilder.ts`
- 工具调用展示：`src/renderer/src/components/message/MessageBlockToolCall.vue:24-70`、`:360-620`
- 导出：`src/main/exporter/formats/conversationExporter.ts:244`、`:391`、`:637`

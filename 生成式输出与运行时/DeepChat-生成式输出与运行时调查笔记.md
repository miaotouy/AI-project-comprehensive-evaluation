# DeepChat 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`（重点 `src/main/mcp/apps/`、`src/main/tool/agentTools/`、`src/renderer/src/components/mcp/`）
>
> 调查更新日期：2026-11-05
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
2. **MCP App 沙箱**：MCP 工具通过 UI 元数据与 `text/html;profile=mcp-app` 资源声明 App；宿主校验持久化工具结果与当前服务器声明后，签发实例并用独立协议源的双层 iframe 承载。JSON-RPC/postMessage 桥允许受控工具调用、资源读取与上下文交互；审批按方法和会话权限模式区分，开外链、发消息、更新模型上下文与敏感浏览器权限另需用户同意（§7.1）。
3. **Agent 本机执行**：命令类工具在本机 shell 中执行（目录白名单 + 命令权限审批 + 后台会话），文件类工具读写工作区，图像生成工具产出 image 块。
4. **Provider 图像产物**：OpenAI Codex 图像生成走 Provider 适配层，结果作为聊天 image 块进入既有消息投影；工具响应中的 base64 图片预览会在主进程尽量转存为 `imgcache://`，单次最多处理 4 个不同预览。

**能力等级判定：`G3`（可执行输出环境）**。承载者是 MCP App 的受控 iframe 运行时与 Agent 的本机命令执行；内置 Artifact 级的 inline 运行时（HTML/React 预览 iframe、`deepcdn://` 依赖注入）已不存在。**未达 G4**：用户对 MCP App 与工作区文件都没有编辑保存通道（工作区代码视图显式只读）；**未达 G5**：没有脱离消息与文件、可被模型查询状态并定向维护的活对象。

## 系统边界与完整主链路

- **输出协议层**：渲染进程从消息文本中解析历史 Artifact 标记，MCP App 由 MCP 资源与工具结果里的 app 描述符声明；解析入口见 `src/renderer/src/composables/useArtifacts.ts`。
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
  → appHost.ts:293-640 校验实例与服务器绑定，按方法及会话权限模式审批/取得同意
  → 结果回 return 给 App；模型上下文写回消息块 extra_json
```

**历史兼容主链路**：SQLite 读回 `block.text_content` → renderer 的 `useArtifacts` 解析出 artifact part → `MessageBlockContent.vue:26-31` 渲染 `LegacyArtifactSource.vue`（标题 + `<pre>` 原文 + 复制按钮）→ 不再有预览、执行或面板跳转。

## 1. 触发方式、输出协议与对象模型

### 内置 Artifact 的退役

- 生成侧：内置 Artifacts 服务器实现（`src/main/mcp/inMemoryServers/artifactsServer.ts`）已删除，`get_artifact_instructions` 工具随之消失；MCP 设置的默认启用列表只剩 macOS 的 `deepchat/apple-server`，配置归一化时还会剔除持久化下来的 `inmemory` 型 Artifacts 服务器，外部用户自建的 MCP 服务器不受影响（`src/main/mcp/settings.ts:242`、`:560`）。
- 渲染侧：旧预览组件、artifact store、预览/导出组合式函数与内置 web-artifacts-builder 技能已移除；正文解析用的 useArtifacts 保留，用于历史标签兼容。普通 Markdown 代码块不再提供 Artifact 预览入口，见 [退役规格](<../../deepchat/docs/architecture/remove-built-in-artifacts/spec.md#L10-L19>) 与 [MessageBlockContent.vue:26–46](<../../deepchat/src/renderer/src/components/message/MessageBlockContent.vue#L26-L46>)。
- 替代路径：Agent 用文件工具把内容写成工作区文件，交互式内容交给浏览器工具；规格明确不引入新的替代工具，也不自动把历史 Artifact 迁移成文件。

### 历史兼容与输出协议

- 渲染进程仍由 `useArtifacts` 解析历史 Artifact 标记：它用一组正则识别六种 type 的 `<antArtifact identifier type title language>` 写法，未闭合的标记在流式输出期间按 loading 处理；消息里已有结构化 artifact 字段时直接按 artifact part 展示。正则集合与 `generatePart` 的入口见 `src/renderer/src/composables/useArtifacts.ts:58-110`、`:284`。
- 兼容视图边界：`LegacyArtifactSource.vue` 只显示 `block.artifact.title` 与 `block.content` 原文，没有 iframe、没有渲染器分派、没有导出。历史的未闭合块同样可读。
- 输入侧净化保留：深链粘贴内容仍对 `antArtifact` 内部做危险模式扫描（script/iframe/javascript:/on*= 等），命中即丢弃整段（`src/main/deeplink/index.ts:666-700`）。
- 对象模型：历史 Artifact 在运行期不再有对象身份——没有 store、没有选择态、没有版本号；它只是消息块原文的一部分。唯一带宿主签发身份的输出对象是 MCP App 实例，身份由 `instanceId` 与工具结果里的 app 描述符共同构成，事实源是持久化的工具结果。

## 2. 增量生成、更新与最终化

- **生成粒度**：模型每输出一个 token，就追加到当前的 content 块；历史 Artifact 标记在兼容视图里随文本一起变长，更新的始终只有纯文本。追加逻辑从 `accumulator.ts:141` 起的 `accumulate` 开始。
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

- 工作区面板只负责文件、Git 与实时委派三类内容，artifact 的集合、选择与自动打开入口已移除；文件预览与 Git diff 保持原行为，由面板里的 files、git 两段承担，入口见 `WorkspacePanel.vue`。
- 文件投影：预览路由提供 markdown/html/pdf/svg/image/text/binary 等格式，HTML/SVG/PDF 经 `workspace-preview://` 协议 iframe 呈现（`WorkspacePreviewPane.vue:47`、`:157` 设置 `allow-scripts allow-same-origin`，主进程协议在 `src/main/app/protocols.ts`）。
- 工作区文件还可通过上下文菜单交给系统已安装应用。主进程按平台探测候选应用并用受控 launcher 打开，renderer 只显示可用列表；入口见 `src/main/workspace/openInApp/`、`src/shared/workspace/fileOpenApps.ts` 与 `WorkspaceViewer.vue:391`。
- 桌面挂件/窗口投影：本次未找到（浮动窗口仅用于浏览器/CUA 预览，`src/renderer/src/floating`、`src/main/desktop/floatingButton`）。

## 4. 表现类型、依赖与运行环境

- **Markdown/SVG/Mermaid**：消息渲染器对这三类内容一律按普通消息处理，整体由 MarkdownRenderer 输出，代码块与 Mermaid 节点走 markstream-vue，没有 Artifact 级的运行环境；历史 Artifact 里的同类内容只以纯文本呈现。
- **MCP App**：双层 iframe + 动态 CSP 承载 MCP 服务器资源中的 HTML 脚本；工作区文件预览有自己的协议与执行面，详见 §7.1 与下一项。
- **工作区文件预览**：HTML/SVG/PDF 走 `workspace-preview://`；SVG 预览有独立组件 `WorkspaceSvgPreview.vue`；代码面板为只读 Monaco（`WorkspaceCodePane.vue`）。
- **图像生成**：`agentImageGenerationTool.ts` 走供应商图像模型，结果转为独立 image 块（`imageGenerationBlocks.ts:8-106` 负责预览呈现与块插入）。
- **图像持久化（#2094）**：生成图片经 `src/main/platform/imageCache.ts` 落盘并以 `imgcache://` 引用进消息文本，协议处理器在 `protocols.ts:207-230`；MCP 工具调用时参数里的 `imgcache://` 引用会被解析回 data URL；renderer 侧已提升为独立 image 块的图不再在 Markdown 中重复显示（消息渲染器笔记 §3）。
- **工具图片预览**：`cacheToolCallImagePreviews` 在工具结果写块前处理预览列表，HTTP(S) 与既有缓存引用直接保留，base64 尽量落盘为缓存引用并去重，最多 4 个不同输入（`src/main/lib/toolCallImagePreviews.ts:383`）；调用点在 `src/main/agent/deepchat/runtime/dispatch.ts:2325`。
- **deepcdn 协议**：注册与本地 `resources/cdn`（7 个文件）仍在（`protocols.ts:154-198`，`electron-builder.yml` 仍复制该目录），但本次在 renderer 与主进程业务代码中未找到 `deepcdn://` 的使用方；它随 Artifact 运行时退役后保留为未清理的注册面。
- 视频/音频/Canvas/WebGL/notebook：本次未找到（grep `notebook` 主进程无命中，renderer 仅图标名；canvas 仅用于 CUA/浏览器 PiP 帧缓冲与图片压缩）。

## 5. 用户交互、事件与错误反馈

- **历史 Artifact**：兼容视图展示标题、原文和复制按钮，复制内容为整段原文；消息本身即可阅读，不触发工作区跳转，见 [LegacyArtifactSource.vue:1–10](<../../deepchat/src/renderer/src/components/message/LegacyArtifactSource.vue#L1-L10>)。
- **工具调用反馈**：`MessageBlockToolCall.vue` 提供参数/响应折叠、exec/终端输出样式、文本编辑类工具结果的 diff 视图、图像预览徽标与缩略图、长时工具自动展开、子代理任务卡与权限状态环；状态字面量为 running/reviewing/error（`MessageBlockToolCall.vue:24-70`、`:360-620`）。
- **MCP App**：工具调用按会话权限模式审批或放行，读资源/列工具校验绑定与预算；开外链、发送消息与更新模型上下文另需同意。同意请求有超时、去重与数量上限，工具调用被拒绝后访问挂起，可由用户重试（§7.1）。
- **交互状态恢复**：展开/收起、viewMode、全屏属 renderer 内存态（sidepanel store），重新打开应用后不保留；MCP App 实例也不跨重载恢复。

## 6. 编辑、diff、版本与协作

- **用户编辑**：工作区的代码视图显式只读，`WorkspaceCodePane.vue` 同时设置了 `readOnly` 与 `domReadOnly`；历史 Artifact 以静态原文呈现，MCP App 的内容由服务器资源决定，三处都没有留给用户的编辑入口。
- **模型侧“编辑”**：模型用 `write`/`edit`/`apply_patch` 改工作区文件，文件级 diff 由 `WorkspaceDiffView.vue` + `workspaceGetGitDiffRoute` 展示（staged/unstaged，入口在 `WorkspaceViewer.vue`）；工具响应内联 diff 见 §5。均为只读展示，无应用/拒绝操作（git 操作属文件与项目工作区类目，交接点在此）。
- **版本/CRDT/协作**：本次未找到。历史 Artifact 无版本字段；MCP App 实例由服务器每次 prepare 重新生成。

## 7. 能力桥、执行位置与权限范围

### 7.1 MCP App 沙箱（最完整的受控运行时）

MCP App 使用独立协议源承载脚本，与聊天宿主分域。外层 iframe 载入 `mcp-app://{instanceId}/sandbox.html` 代理页，内层 iframe 允许脚本、同源与表单并执行 App HTML。内层与代理页共享 App 协议源，代理页启动时确认无法读取宿主顶层地址；隔离发生在 App 与聊天宿主之间（[sandboxProtocol.ts:57–177](<../../deepchat/src/main/mcp/apps/sandboxProtocol.ts#L57-L177>)、[appHost.ts:274–284](<../../deepchat/src/main/mcp/apps/appHost.ts#L274-L284>)）。

代理页响应携带动态 CSP 与 Permissions-Policy。CSP 以 default-src 拒绝为基线，同时显式允许自身源、内联脚本/样式和部分 data/blob 资源；外部资源、连接与嵌套 frame 按声明域放行，对象与表单提交禁用。资源中的域声明会经过归一化。摄像头、麦克风、地理位置与剪贴板写入需声明对应权限，并由 Electron 的请求级同意处理器逐次裁决，没有常驻授权（`src/main/mcp/apps/sandboxProtocol.ts:25-55`、`sandboxRegistry.ts:371-434`）。

能力桥使用 JSON-RPC 2.0/postMessage，代理页检查消息 source/origin 与体积，宿主按方法校验存活实例、所属窗口、原工具结果和服务器绑定。具体权限如下：

| 请求 | 条件与行为 | 主要源码 |
|---|---|---|
| 调用工具 | 只接受 App 可见且插件策略允许的工具；default 模式进入用户审批。当前调用未传 explicit_user，auto_approve/full_access 可由 broker 直接放行；拒绝后挂起工具访问，用户可重试 | `src/main/mcp/apps/appHost.ts:293-400`、`src/main/tool/permission/toolPermissionBroker.ts:146-168` |
| 列工具、读资源、列资源/模板/提示词 | 校验实例和服务器绑定并限制结果体积；列工具还按 App 可见性与插件策略过滤。这些方法没有另行请求用户同意 | `src/main/mcp/apps/appHost.ts:402-525` |
| 打开外链 | 仅接受无凭据的 HTTP(S)，同意后交系统浏览器 | `src/main/mcp/apps/appHost.ts:527-544` |
| 发送消息 | 校验非空与长度，取得用户同意后允许进入会话 | `src/main/mcp/apps/appHost.ts:546-566` |
| 更新模型上下文 | 校验体积并计算批准 hash，用户同意后持久化到来源消息块，供后续回合回流 | `src/main/mcp/apps/appHost.ts:568-612` |

App HTML 必须来自指定 MIME 的 MCP 资源，大小上限 2 MiB；prepare 会核对持久化结果与当前工具声明，工具执行前再次校验 App 可见性、插件策略与服务器绑定。原消息、工具输入或配置绑定变化会使视图失效（`src/main/mcp/apps/appHost.ts:218-271`、`:375-390`、`:647-699`）。

实例保存在内存：总上限 64、每 webContents 上限 32，TTL 为创建后 30 分钟；创建或访问时清理过期记录。pending consent 上限 64，同意请求 2 分钟超时。服务器撤销、原消息失效或所属 webContents 销毁会撤销实例及待决同意，见 [sandboxRegistry.ts](<../../deepchat/src/main/mcp/apps/sandboxRegistry.ts>)。

视图卸载时尝试 teardown，最多等待 500ms 后关闭桥并释放宿主实例，见 [McpAppView.vue:206–227](<../../deepchat/src/renderer/src/components/mcp/McpAppView.vue#L206-L227>)。TTL 到期约束后续协议与宿主访问，源码没有在到点时主动移除 iframe 的定时器；脚本停止时序仍需在目标环境观察。

重载后原实例及其交互状态不恢复。持久化工具结果里的 App 描述符可以重新 prepare 新视图，前提是资源、工具声明与服务器绑定仍有效；保存的是可再生视图的来源与已批准模型上下文，运行实例没有跨重载状态快照（`src/main/mcp/resultProjection.ts:183`、`src/main/mcp/apps/appHost.ts:218-285`）。

### 7.2 Agent 代码执行（本机进程）

- **exec 工具**：命令交给本机 shell 以子进程执行，分为分离与托管两种形态，默认超时 120 秒、终止宽限 5 秒。启动目录必须落在 allowedDirectories 白名单内，范围可含工作区、Skill、会话目录、临时目录与用户批准过的路径，越界的 cwd 会被拒绝；这项检查只约束启动位置，进程随后仍以本机用户权限运行（[agentBashHandler.ts:287–325](<../../deepchat/src/main/tool/agentTools/agentBashHandler.ts#L287-L325>)）。
- **命令 shell 可配置（#2109）**：执行命令所用的 shell 由 `src/shared/commandShell.ts` 解析出的 preference/profile 决定（8 种 preference/profile，dialect 归为 posix、cmd、powershell 三种，pathStyle 有 native/win32/msys），按 dialect 拼命令与提示；RTK 改写只在 posix 方言启用；后台会话同样携带该配置；命令审批请求附带 shellProfile（Agent 工具笔记 §3）。
- **权限**：`CommandPermissionService` 按低/中/高/关键四级审批，白名单与破坏性/网络模式按 shell 方言分别匹配；文件读写走 `FilePermissionService`（read/write/all 三档），`auto_approve` 下的审阅范围由 `resolveAgentToolReview` 统一裁决（Agent 工具笔记 §3）。
- **输出预览与落盘**：执行结果按内联上限截取预览，超过阈值的完整输出落会话目录 log 文件；Agent 配置的 `commandOutputInlineChars`/`toolOutputInlineChars` 可调节（Agent 角色笔记 §1）。
- **后台会话**：`backgroundExecSessionManager` 支持 background/yield 与 `process` 工具（查询、轮询、日志、写入、终止、清理、移除），输出超限落会话目录 log 文件。
- **二进制读取放宽（#2110）**：`src/main/lib/binaryReadGuard.ts:69-80` 只拒绝固定二进制 MIME 与 audio/video，文本型 octet-stream 文件允许读取。

### 7.3 历史 Artifact 运行时

已不存在。历史消息不会因为被阅读而启动任何预览运行时或打开工作区面板（`remove-built-in-artifacts` 规格的验收项）。

## 8. 持久化、恢复、分享与导出

- **持久化对象**：content 块原文连同历史 `<antArtifact>` 标签，一起写进 SQLite 表 `deepchat_assistant_blocks` 的 `text_content` 列；工具调用与 MCP App 模型上下文等附加信息放在 `extra_json` 列，助手消息行存放在 `deepchat_messages` 表。表结构定义见 `deepchatAssistantBlocks.ts`。
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
- **MCP App**：实例上限与访问时 TTL 检查限制宿主登记，视图卸载关闭桥并释放实例，webContents 销毁与绑定变更触发撤销；同意请求独立超时。重载后重新准备视图，原运行状态不恢复；TTL 撤销与 frame 脚本停止应分开观察（§7.1）。
- **进程**：exec 超时 + 进程树终止（`terminateProcessTree`）；后台会话由 `backgroundExecSessionManager` 登记，会话目录 log 落盘；应用级进程清单限额本次未找到（限额在权限层）。
- **流式性能**：renderer 端 120ms 节流 + 解析 memo + `MessageBlockContent` 快照比对；DB 600ms 节流。全块快照序列化在超长输出下成本线性，未见增量 diff 机制。
- **长会话**：上下文预算/压缩会截断历史消息文本；压缩后的历史 Artifact 文本与普通文本一并处理，兼容视图不依赖压缩前结构。

## 11. 测试、已确认边界与未验证事项

### 测试覆盖（静态确认存在，未运行）

- 历史 Artifact 标记解析、半截流兼容与 memo 缓存由 `test/renderer/composables/useArtifacts.test.ts` 覆盖。
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

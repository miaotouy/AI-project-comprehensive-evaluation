# Chatbox 生成式输出与运行时调查笔记

> 调查对象：`../../chatbox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：静态阅读源码与配套文档（`docs/technical/code-execution.md`、`windows-sandbox.md`），结合 grep/glob 关键词检索（artifact、canvas、sandbox、iframe、webview、notebook、execute_code、create_download 等）；未运行应用、未执行测试
>
> 调查范围：代码执行沙箱、生成文件（下载产物）、HTML artifact 预览、工具结果消息化与持久化、模型回流维护闭环；图片生成记录、MCP、Skills 仅记录边界交点
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 以聊天为主，没有独立的 artifact 对象模型或专用工作区。生成式输出的主要形态是嵌入消息的工具调用结果（`MessageToolCallPart`），辅以三类可寻址结果：`create_download` 声明的持久化文件、HTML artifact 预览、图片生成记录。代码执行由 Agent Mode 门控，桌面端经 `src/main/sandbox` 在本地运行 Node/PowerShell/Bash；macOS/Linux 走 `@anthropic-ai/sandbox-runtime` OS 沙箱，Windows 无 OS 隔离。用户对产物的操作限于预览、保存导出、批准/暂停/继续工具调用；没有编辑器、diff、版本或工作区。模型侧具备"查询（read/list/search）→ 读取 → 定向修改（write/edit）"的文件维护闭环，工作目录以会话 ID 确定性定位，重启后可持续。综合判定为 **G3（可执行 Artifact）**，模型侧编辑链具备 G4 的部分特征（详见"能力等级评估"）。

## 系统边界与完整主链路

系统分层：renderer（UI + 工具集 + 消息持久化缓存）→ IPC（`sandbox:*` 处理器）→ main（沙箱会话、进程执行、预览服务器、artifact 持久化）。事实源是**会话消息 JSON**（含工具调用结果），磁盘文件是运行实例与持久化副本。

**主链路（触发 → 生成 → 展示/运行 → 交互 → 保存 → 重新打开）**：

1. **触发**：用户发送消息，会话 `agentMode` 为 `on`（或 `auto` 首轮经分类器建议、用户确认），且模型 `isSupportToolUse('agent')`。`src/renderer/stores/session/orchestration.ts:500-575`（auto 建议）、`agent-harness.ts:204-243`（有效模式与沙箱提供器创建）。
2. **工具构建**：`buildToolsForSession`（`src/renderer/stores/session/tools-builder.ts:221`）注入三类模型侧工具——代码执行、文件读取、产物声明（`code_execution`、`read_file`、`create_download`，定义于 `src/renderer/packages/model-calls/toolsets/code-execution.ts:77`）——以及文件系统工具（`filesystem.ts:296`）。
3. **生成**：模型流式调用工具，`stream-chunk-processor.ts:243-298` 把工具调用 part 从 `call` 态推进到 `result` 态，大结果溢出时写 blob（`resultStorageKey`）；每 2 秒持久化一次当前消息（`src/renderer/stores/session/messages.ts:143`）。
4. **运行**：`code_execution` 沿渲染层提供器、IPC、主进程执行器三层落地（入口 `LocalSandboxProvider.exec` → `sandbox:exec-code` → `execCode`，定位见文末源码索引），首次调用懒初始化会话临时目录并复制上传附件（`code-execution.ts:87-156`）。
5. **产物声明**：模型调用 `create_download`（`code-execution.ts:316`）→ `persistSandboxArtifact`（`manager.ts:1454`）把文件复制到 `userData/chatbox-sandbox/artifacts/<sessionId>/<sha1>/<basename>`，消息内保存绝对路径。
6. **展示与交互**：消息时间线内工具卡（`src/renderer/components/message-parts/ToolCallPartUI.tsx`）与底部产物文件卡（`ToolCallPartUI.tsx:925`）提供 HTML/图片 Preview 与 Save 按钮，保存走系统保存对话框（`exportFileFromSandbox`）。提交 `b8db137c` 起，下载卡内的沙箱文件链接经链接重映射组件渲染：模型幻觉出、不在沙箱允许根内的路径会被重映射或标记不可用（`sandbox-link.ts`），避免展示无效链接。
7. **保存**：整个会话（含 tool-call parts 与 result 路径）序列化为 storage 键（`chatStore.ts:350-391`）。
8. **重新打开**：会话从 storage 加载；artifact 因位于 userData 持久根而继续可 Save/Preview（`manager.ts:1379` 的 `getSandboxAllowedRoots` 重启回退逻辑；`persist-artifact.test.ts:48` 验证）。

未运行验证：第 3-8 步的运行时行为均为静态确认。

## 1. 触发方式、输出协议与对象模型

**触发**：全部由模型自由文本发起工具调用，无用户直接运行的入口。门控链为：桌面平台 + `agentMode` 为 `on` + 模型 agent scope + 沙箱可用性检查（`agent-harness.ts:208-227`；`orchestration.ts:506-575,767-788`）。`auto` 模式首轮由快速分类模型决定是否注入 `agent-mode-suggestion` part，用户接受后锁定为开启态。

**输出协议**：无独立 artifact 协议。输出走 AI SDK `ToolSet` + JSON schema（`code-execution.ts:166-187`）。唯一"产物声明"是 `create_download` 的返回，字段如下：

```text
{ downloadable: true, file_path, display_name, provider_type }
```

HTML 预览存在第二个隐性协议：消息正文的 html 代码块由 `isContainRenderableCode` 探测（`src/renderer/components/Artifact.tsx:22`）。经 `Markdown.tsx` 的 Preview 按钮进入 artifact 模态框，该路径把整段 markdown 拼装成 HTML（`Markdown.tsx:574,647`、`Artifact.tsx:232-296` 附近）。

**对象模型**：核心对象是 `MessageToolCallPart`（`src/shared/types/session.ts:159-206`），嵌入消息内容部件数组，无独立 ID 体系——`toolCallId` 是唯一寻址键，生命周期绑定消息与会话；产物文件本身没有元数据记录（无版本/状态/能力声明），`downloadable` 仅是结果字段。主要字段：

- `state`：call / result / error / paused
- `toolName`、`args`、`result`
- `resultStorageKey`：大结果溢出落盘键
- `pauseReason`、`duration`

## 2. 增量生成、更新与最终化

- 流式逐 chunk 更新消息 contentParts（`stream-chunk-processor.ts:243-298`），工具调用间穿插文本与 reasoning part。
- 大工具结果溢出阈值触发 blob 落盘，消息内只留预览片段（`stream-chunk-processor.ts:285-295`；`TOOL_RESULT_SIZE_LIMIT` 与 `TOOL_RESULT_PREVIEW_LENGTH`）；`f90fc31a`（#3827）保证转存 blob 时保留 part 原有的 provider metadata 等字段。
- 最终化：`finishReason` 结束消息；工具失败置 `state='error'`，超时置退出码 124 并在 stderr 标注（`manager.ts:839-864`）。提交 `5cbe2e0b` 起，停止生成时仍在运行的 tool-call 也会被收口为错误态落盘（`generation-cancellation.ts`）。
- 暂停机制持久化：`tool_call_limit` 上限与三类审批（user_exec / file_mutation / app_action）把 part 置 `paused`（`session.ts:178-203`），随会话落盘；重启后经 `continuePausedToolCall` 在原消息内继续（`orchestration.ts:1157-1212`）。暂停的调用不注入上下文（`docs/technical/code-execution.md:179`）。
- 确认点可配置：提交 `1db662a9`/`22ec7806` 起，`tool_call_limit` 确认点可被会话或全局关闭（`pauseOnToolCallLimit`），暂停卡片继续按钮拆分为"继续"与"继续并本次不再暂停"（`ToolCallPartUI.tsx`；设计文档同步更新）。

## 3. 投影表面与多视图关系

产物只投影在**消息时间线内**：工具卡（可展开 args/result/错误）、消息底部汇总的 `DownloadArtifactsUI` 文件卡、HTML artifact 预览模态框（全屏）。同一 HTML 文件可有三种投影：`create_download` 预览（本地 preview server URL）、消息代码块预览（postMessage 到远端 `https://artifact-preview.chatboxai.app/preview`）、外部浏览器打开。无侧栏、画布、notebook、工作区投影（在 src 内检索 notebook、canvas 工作区类 UI 均无命中）。

## 4. 表现类型、依赖与运行环境

- **artifact iframe**：`sandbox="allow-scripts allow-forms"`，本地 preview URL 追加 `allow-same-origin`（`Artifact.tsx:222-228`）；远程宿主经 postMessage 注入 HTML，srcDoc 内嵌 Tailwind CDN（`Artifact.tsx:281-294`）。
- **代码执行**：语言为 node（Electron 内置二进制，`ELECTRON_RUN_AS_NODE`）、powershell（仅 Windows）与 bash（macOS/Linux 直跑，Windows 需 Git Bash/WSL 或回退）（`manager.ts:714-748`）。Python 不可用；依赖只允许 Node 内置与 shell 工具，并提示模型避免安装包（`code-execution.ts:425,427-434`）。
- **本地预览服务器**：127.0.0.1 随机端口，路径解析限制在沙箱允许根、拒绝 symlink、重写根相对引用（`preview-server.ts:94-151`）。

## 5. 用户交互、事件与错误反馈

- 工具卡展开/折叠、运行中状态、耗时、错误摘要（`ToolCallPartUI.tsx:1377-1536` 附近）。`d63902e0` 起运行中的命令卡可展开读取结构化输出，取消的命令显示 "Stopped" 而非失败。
- 暂停卡片提供批准/拒绝/停止（`ToolCallPartUI.tsx:1301`）；审批经 `requestUserExecApproval`/`requestFileMutationApproval` 两个入口（`tools-builder.ts:545`、`filesystem.ts:11`）。
- artifact 模态框操作：刷新、全屏、Open in Browser（仅 previewUrl）、Publish Webpage（Vibedrop）（`src/renderer/modals/ArtifactPreview.tsx:68-87,124-168`）；`d55d0b1f` 把移动端操作收进安全头部（避免误触），`ArtifactPreview.tsx` 布局重排为移动优先（`:1-239`）。
- 下载卡：图片内联预览、HTML Preview、Save（导出）按钮与错误回显（`ToolCallPartUI.tsx:750-910`，`DownloadArtifactsUI:925`）。
- 无编辑器、无沙箱文件浏览器 UI（检索 `SandboxFile*`、`sandbox files` 无命中；`SandboxFileLink` 只是下载卡内链接组件，不是文件浏览器）。

## 6. 编辑、diff、版本与协作

用户侧没有对生成对象的编辑器，修改只能"继续对话"由模型执行。模型侧文件修改是结构化 search-replace：`write_file`/`edit_file`（`filesystem.ts:296-552`）要求 `edits[]` 唯一匹配，并经主进程同构校验（`manager.ts:969-1016`）。沙箱与用户授予目录免审批，其余真实路径需 file_mutation_approval 审批或 Full Access。无 diff 视图、版本、接受/拒绝（审批除外）、撤销或分支；分支/重试属于 Chat 层能力（fork、regenerate）。

## 7. 能力桥、执行位置与权限范围

执行位置：桌面端为主进程 spawn 的子进程；macOS/Linux 经 SRT（`@anthropic-ai/sandbox-runtime`）OS 沙箱包裹（`manager.ts:758-771`），Windows 无 OS 沙箱、原生执行（`manager.ts:596-607`，`docs/technical/windows-sandbox.md`）。

文件权限（`manager.ts:377-414`、`src/shared/task-sandbox.ts`）分三类规则：

| 规则 | 覆盖范围 |
|---|---|
| denyRead | `~/.ssh` 等 |
| allowWrite | 工作目录、`/tmp`、用户授予目录（含 symlink 规范化与安全根校验 `isUnsafeResolvedPath`，`manager.ts:283-317`） |
| denyWrite | `.env*` |

网络：SRT config 未设 `allowedDomains`，注释表明生成 `(allow network*)`（`manager.ts:401-407`）；Windows 无网络限制。宿主桥：导出保存对话框、`openLink`、平台 `fsRead` 回退（`code-execution.ts:249-272`）、Vibedrop 外部发布。IPC 表面完整登记于 `ipc-handlers.ts:36-298`。

## 8. 持久化、恢复、分享与导出

- 消息与工具结果随会话 JSON 持久化（`chatStore.ts:362`）；临时沙箱目录位于 `os.tmpdir()/chatbox-sandbox/<sessionId>`，启动时清理 7 天以上旧目录（`manager.ts:1582-1606`）。
- `create_download` 产物持久化到 userData 且豁免清理（`manager.ts:1436-1505`）；删除会话时提示并删除（`chatStore.ts:439-455,481`）。
- 导出：保存对话框复制（`manager.ts:1511-1570`）；大结果 blob 随备份重映射（`src/renderer/packages/backup/resources.ts:77-79,207-210`）。导出聊天含工具调用摘要（`src/shared/utils/chat-export.ts`）。
- 重新打开后下载卡仍可用，依赖持久副本路径与 `getSandboxAllowedRoots` 的重启回退（`manager.ts:1374-1380`）。

## 9. 模型回流、对象感知与持续维护

- 上下文默认保留最近若干轮的 tool-call parts（`src/shared/context/builder.ts:101-154`，`cleanToolCalls` 仅清理更早轮次）；暂停调用不注入。
- sandboxMode 下附件以 `<SANDBOX_PATH>/<PARSED_SANDBOX_PATH>` 元数据注入而不带内容（`builder.ts:186-190`），模型通过 `read_file`/`code_execution` 主动读取。
- 模型可查询沙箱状态（`read_file`/`list_files`/`search_files`，路径经 ripgrep 与沙箱校验），工作目录由会话 ID 确定性计算（`resolveSandboxWorkingDir`，`manager.ts:1250-1255`），重启后复用同一目录——"查询 → 读取 → 定向修改"闭环在代码路径上成立。此为静态推断，未运行验证。

## 10. 生命周期、资源治理与性能

- 每会话至多一个运行子进程（`session.runningChild`）。终止走 `killRunningCommand` 入口（`manager.ts:874`，`d63902e0` 起支持按 toolCallId 定位）；超时默认 30s（执行器）/120s（工具层），超时先 SIGTERM 后 SIGKILL，Windows 用 taskkill /T。POSIX 侧命令以进程组 spawn，`killProcessTree()`（`src/main/process-tree.ts`）用负 pid 信号终止整棵树，避免孤儿进程。
- stdout/stderr 各 10MB 缓冲上限 + tail 截断 + 脱敏（`manager.ts:775,844-849`）。
- 会话重置、退出时 `resetAllSessions`，预览服务器随 quit 关闭（`sandbox/index.ts:6-15`）；temp 目录 7 天清理（`cleanupStaleSandboxDirs`，`manager.ts:1600`），持久 artifact 永不清理。
- 多轮工具调用上限 `MAX_TOOL_CALLS_BEFORE_CONFIRMATION` 暂停防循环（`orchestration.ts:750-752`，可经 `pauseOnToolCallLimit` 关闭）。无对象级冻结/卸载逻辑（对象即消息 part，随消息生命周期）。

## 11. 测试、已确认边界与未验证事项

测试覆盖（均未执行，仅静态确认存在）：
- `src/main/sandbox/`：`manager.test.ts`（路径与写入授权）、`manager.windows.test.ts`（Windows 原生路径）、`persist-artifact.test.ts`（持久化、会话删除、路径穿越拒绝，`persist-artifact.test.ts:114`）、`preview-server.test.ts`、`exec-script.test.ts`、`file-read.test.ts`、`truncate.test.ts`
- renderer 侧：`code-execution.test.ts`（懒初始化/文件注入/错误处理）、`tools-builder.test.ts`（不同 agent mode 下工具可见性）、`stream-chunk-processor.test.ts`（resultStorageKey 溢出）、`agent-harness.test.ts`（有效模式计算）
- 文档 `docs/technical/code-execution.md:223-235` 列有对应测试清单

**已确认边界**：

- 云沙箱（Web/Mobile）是 stub，全部方法返回"not yet implemented"（`src/renderer/sandbox/cloud-provider.ts:17-86`），实际能力仅桌面端。
- 消息级 `MessageArtifact`（整条消息 HTML 拼装预览）与 `needArtifact`/`previewArtifact` 状态已保留但未接入渲染（`Message.tsx:85,193,431` 仅定义/计算，全仓检索无渲染调用点）——旧路径疑似被逐代码块预览取代，此为静态推断。
- `autoPreviewArtifacts` 默认关闭（`src/shared/defaults.ts:98`）。

**未验证事项**：整个运行时链路（执行、预览、下载、暂停继续、重启恢复）均未运行验证；Windows 原生执行与 SRT 隔离的实际行为、网络放行策略的实际生效情况、artifact 跨重启可用性只由代码路径与测试文件支持。

## 12. 能力等级评估

| 等级 | 判定 |
|---|---|
| G0 | 支持（普通 Markdown/代码块） |
| G1 | 支持：生成文件可单独预览/下载/导出，持久化到 userData（`create_download`） |
| G2 | 不适用：无宿主 schema 渲染的声明式控件，交互对象是工具调用结果卡 |
| G3 | **支持（桌面端）**：代码进入专用执行环境（SRT 沙箱/本机进程），用户可查看结果、暂停/继续、下载产物、全屏预览 HTML |
| G4 | 部分：模型可对同一文件对象持续读写（回流 + write/edit），但用户侧无编辑器、无 diff/版本/接受拒绝，不构成完整可编辑工作区 |
| G5 | 不支持：无桌面活对象、无对象状态感知与长期维护 |

**总等级：G3**。依据：`code_execution` 在专用运行环境中执行并可实际操作（`manager.ts:652`、`ToolCallPartUI.tsx` 交互卡）、产物经 `persistArtifact` 获得跨会话持久性（`manager.ts:1436`）、模型维护闭环存在（第 9 节）；但对象身份、编辑工具与版本体系缺失，达不到 G4/G5。

## 与相邻类目的边界

- **Chat**：发送、中止、重试、fork、分支属于 Chat 层，本笔记只覆盖输出对象被创建/更新/恢复的部分。
- **消息渲染器**：Markdown、代码高亮、普通工具卡显示留在消息渲染器类目；本笔记接手的是工具结果物化为可寻址产物（下载卡、预览模态框、暂停继续）的部分。
- **Agent 工具**：`user_exec` 审批、MCP、Skills 的调度语义属于 Agent 工具类目；本笔记只记录其与输出对象（paused part、下载产物）的交点。
- **文件与项目工作区**：通用文件浏览、备份恢复属于文件类目；本笔记只覆盖模型生成的沙箱文件如何落盘、预览与回流。
- 图片生成（picture 会话、`imageGenerationStore` 的 `ImageGenerationRecord`，状态 pending/generating/done/error + blob 键）是第三类输出记录，但触发与调度属于 Agent 工具类目，此处仅记录存在性，未展开；`ecec96bd` 起记录新增 `source` 字段（chatbox_cli 来源），可在聊天内恢复该生成任务（独特功能笔记能力卡 2 有展开）。

## 关键源码索引

- `src/renderer/stores/session/orchestration.ts:500-610`：agent mode 判定与生成编排
- `src/renderer/stores/session/agent-harness.ts:204-304`：沙箱提供器创建与工具装配
- `src/renderer/stores/session/tools-builder.ts:221-366`：工具集构建与门控
- `src/renderer/packages/model-calls/toolsets/code-execution.ts:77-466`：code_execution/read_file/create_download 工具
- `src/renderer/packages/model-calls/toolsets/filesystem.ts:296-552`：write_file/edit_file 等文件工具
- `src/renderer/sandbox/local-provider.ts:17-199`：桌面沙箱提供器
- `src/main/sandbox/manager.ts:650-1600`：沙箱会话、执行、文件操作、artifact 持久化
- `src/main/sandbox/ipc-handlers.ts:36-298`：IPC 桥
- `src/main/sandbox/preview-server.ts:94-208`：HTML 预览服务器
- `src/main/process-tree.ts`：跨平台进程树终止（`killProcessTree`）
- `src/renderer/components/Artifact.tsx:22-296`：artifact 探测与 iframe 预览
- `src/renderer/components/message-parts/ToolCallPartUI.tsx:750-925`：下载卡与产物 UI
- `src/renderer/modals/ArtifactPreview.tsx:1-239`：artifact 预览模态框
- `src/renderer/stores/session/stream-chunk-processor.ts:243-298`：工具结果流式落盘
- `src/renderer/stores/chatStore.ts:350-391,439-481`：会话持久化与删除清理
- `src/shared/types/session.ts:159-206`：MessageToolCallPart 对象模型
- `src/shared/context/builder.ts:101-190`：工具调用回流与 sandboxMode 附件注入
- `docs/technical/code-execution.md`、`docs/technical/windows-sandbox.md`：设计文档

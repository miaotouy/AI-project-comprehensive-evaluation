# Chatbox 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/chatboxai/chatbox`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`d17455c5ca8fd3ff44385c6d4d2118599e4c970f`（分支：`main`）
>
> 调查方式：静态阅读源码与配套文档（`docs/technical/code-execution.md`、`windows-sandbox.md`），结合 grep/glob 关键词检索（artifact、canvas、sandbox、iframe、webview、notebook、execute_code、create_download 等）；未运行应用、未执行测试
>
> 调查范围：代码执行沙箱、生成文件（下载产物）、HTML artifact 预览、工具结果消息化与持久化、模型回流维护闭环；图片生成记录、MCP、Skills 仅记录边界交点
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 以聊天为主，没有独立的 artifact 对象模型或专用工作区。生成式输出的主要形态是嵌入消息的工具调用结果，辅以持久化文件、HTML 预览和图片生成记录。Work Mode 的 `run_command` 采用 sandbox-first 执行并可按审批策略升级到宿主环境，`view_image` 让模型重新读取生成或修改后的图片；生成图片与 `create_download` 文件统一投影到消息底部 artifacts 区域。用户仍没有编辑器、diff 或对象版本界面，模型侧则可围绕同一文件持续读、看、写、运行与声明下载。综合判定仍为 **G3（可执行 Artifact）**，文件维护闭环具备 G4 的部分特征。

## 系统边界与完整主链路

系统分层：renderer（UI + 工具集 + 消息持久化缓存）→ IPC（`sandbox:*` 处理器）→ main（沙箱会话、进程执行、预览服务器、artifact 持久化）。事实源是**会话消息 JSON**（含工具调用结果），磁盘文件是运行实例与持久化副本。

**主链路（触发 → 生成 → 展示/运行 → 交互 → 保存 → 重新打开）**：

1. **触发**：用户发送消息后，只要会话的 `agentMode` 为 `on`（`auto` 模式首轮由分类器给出建议、用户确认后同样进入），且当前模型的 agent scope 声明支持工具调用，本轮就带上工具集开始生成。模式判定与自动建议见 `src/renderer/stores/session/orchestration.ts:500-575`，沙箱提供器创建见同目录 `agent-harness.ts:204-243`。
2. **工具构建**：会话开始时由 `buildToolsForSession` 装配本轮工具集，注入代码执行（`code_execution`）、文件读取（`read_file`）与产物声明（`create_download`）三类模型侧工具，以及写入和编辑文件的文件系统工具。装配入口见 `src/renderer/stores/session/tools-builder.ts:221`，三类工具定义在 `src/renderer/packages/model-calls/toolsets/code-execution.ts:77`，文件系统工具在 `filesystem.ts:296`。
3. **生成**：模型以流式方式发起工具调用，处理器把对应 part 从 call 态推进到 result 态；结果体积超过阈值时转存为 blob，消息里只留引用键，当前消息每 2 秒落盘一次。流式推进见 `src/renderer/stores/session/stream-chunk-processor.ts:243-298`，定时持久化见同目录 `messages.ts:143`。
4. **运行**：`code_execution` 的请求按渲染层提供器、IPC 通道 `sandbox:exec-code`、主进程执行器三层转发，首次调用时懒初始化会话临时目录并把上传附件复制进去。三层入口见文末源码索引，懒初始化与附件复制见 `code-execution.ts:87-156`。
5. **产物声明**：模型调用 `create_download` 后，主进程把文件复制到 userData 下的 artifacts 目录，路径按会话 ID、内容哈希与文件名分层（`userData/chatbox-sandbox/artifacts/<sessionId>/<sha1>/<basename>`），消息里只记录该绝对路径。工具入参见 `code-execution.ts:316`，复制与落盘见 `src/main/sandbox/manager.ts:1454`。
6. **展示与交互**：消息时间线里的工具卡和消息底部的产物文件卡提供 HTML、图片预览与保存按钮，保存经系统保存对话框完成；下载卡内的沙箱文件链接由重映射组件渲染，模型编造或位于沙箱允许根之外的路径会被改写或标记为不可用，避免展示无效链接。卡片实现在 `src/renderer/components/message-parts/ToolCallPartUI.tsx:925`，链接重映射在 `sandbox-link.ts`。
7. **保存**：整个会话连同工具调用 part 与结果路径一起提交为行存储记录，由 `SessionService` 与 `RowBackedSessionRepository` 写入。
8. **重新打开**：会话从 storage 重新加载后，产物仍可预览与保存，原因是文件位于 userData 持久根内，允许根在重启时由 `getSandboxAllowedRoots` 补齐回退。回退逻辑见 `src/main/sandbox/manager.ts:1379`，验证用例在 `persist-artifact.test.ts:48`。

未运行验证：第 3-8 步的运行时行为均为静态确认。

## 1. 触发方式、输出协议与对象模型

**触发**：工具调用全部由模型在自由文本中发起，用户侧没有直接执行的入口。一次调用需同时满足四项条件：运行在桌面平台、`agentMode` 为 `on`、当前模型的 agent scope 允许、沙箱可用性检查通过。`auto` 模式首轮由快速分类模型判断是否注入 `agent-mode-suggestion` part，用户接受后锁定为开启态。门控链与自动建议分支见 `agent-harness.ts:208-227`、`orchestration.ts:506-788`。

**输出协议**：无独立 artifact 协议。输出走 AI SDK `ToolSet` + JSON schema（`code-execution.ts:166-187`）。唯一"产物声明"是 `create_download` 的返回，字段如下：

```text
{ downloadable: true, file_path, display_name, provider_type }
```

HTML 预览存在第二个隐性协议：消息正文的 html 代码块由 `isContainRenderableCode` 探测（`src/renderer/components/Artifact.tsx:22`）。经 `Markdown.tsx` 的 Preview 按钮进入 artifact 模态框，该路径把整段 markdown 拼装成 HTML（`Markdown.tsx:574,647`、`Artifact.tsx:232-296` 附近）。

**对象模型**：核心对象是 `MessageToolCallPart`（`src/shared/types/session.ts:159-206`），嵌入消息内容部件数组，无独立 ID 体系——`toolCallId` 是唯一寻址键，生命周期绑定消息与会话；产物文件本身没有元数据记录（无版本/状态/能力声明），`downloadable` 仅是结果字段。主要字段：

| 字段 | 说明 |
|---|---|
| `state` | call / result / error / paused |
| `toolName`、`args`、`result` | 工具名、入参与返回结果 |
| `resultStorageKey` | 大结果溢出后落盘所用的键 |
| `pauseReason`、`duration` | 暂停原因与调用耗时 |

## 2. 增量生成、更新与最终化

- 模型回复以流式方式逐段更新消息的内容部件数组，工具调用与文本、reasoning 片段按到达顺序穿插排列。处理器实现在 `stream-chunk-processor.ts:243-298`。
- 单个工具结果超过阈值后转存为 blob，消息里只保留预览片段，转存时保留 part 原有的 provider metadata 等字段；阈值与预览长度由 `TOOL_RESULT_SIZE_LIMIT`、`TOOL_RESULT_PREVIEW_LENGTH` 两个常量决定。相关逻辑见 `stream-chunk-processor.ts:285-295`。
- 最终化由 `finishReason` 收尾整条消息：工具执行失败把 part 置为 `state='error'`，超时以退出码 124 结束并在 stderr 标注；停止生成时仍在运行的工具调用同样收口为错误态落盘。执行与超时处理见 `manager.ts:839-864`，取消收口见 `generation-cancellation.ts`。
- 暂停机制持久化：工具调用数达到上限，或命中用户执行、文件变更、应用操作三类审批时，part 被置为 `paused` 并随会话落盘，重启后经 `continuePausedToolCall` 在原消息内继续；暂停中的调用不进入上下文。字段定义见 `session.ts:178-203`，继续逻辑见 `orchestration.ts:1157-1212`，上下文规则见 `docs/technical/code-execution.md:179`。
- 确认点可配置：工具调用上限的确认点由 `pauseOnToolCallLimit` 控制，可在会话级或全局关闭；暂停卡片的继续按钮拆分为"继续"与"继续并本次不再暂停"两种。界面见 `ToolCallPartUI.tsx`。

## 3. 投影表面与多视图关系

产物的投影集中在**消息时间线内**：工具卡（可展开 args/result/错误）、消息底部汇总的 `DownloadArtifactsUI` 文件卡、HTML artifact 预览模态框（全屏）。同一 HTML 文件可有三种投影：`create_download` 预览（本地 preview server URL）、消息代码块预览（postMessage 到远端 `https://artifact-preview.chatboxai.app/preview`）、外部浏览器打开。无侧栏、画布、notebook、工作区投影（在 src 内检索 notebook、canvas 工作区类 UI 均无命中）。

## 4. 表现类型、依赖与运行环境

- **artifact iframe**：iframe 的 sandbox 属性设为 `allow-scripts allow-forms`，本地预览地址再追加 `allow-same-origin`；远程预览宿主经 postMessage 注入 HTML，srcDoc 中内嵌 Tailwind CDN。两处实现同在 `Artifact.tsx:222-294`。
- **代码执行**：可执行语言为 node（Electron 内置二进制，以 ELECTRON_RUN_AS_NODE 方式运行）、powershell（仅 Windows）与 bash（macOS/Linux 直接执行，Windows 需 Git Bash、WSL 或回退）。Python 不可用；依赖限于 Node 内置模块与 shell 工具，提示词要求模型避免安装包。语言分支见 `manager.ts:714-748`，依赖约束见 `code-execution.ts:425-434`。
- **本地预览服务器**：监听 127.0.0.1 的随机端口，路径解析限定在沙箱允许根内，拒绝 symlink，并重写根相对引用。实现见 `preview-server.ts:94-151`。

## 5. 用户交互、事件与错误反馈

- 工具卡支持展开与折叠，显示运行中状态、耗时和错误摘要；运行中的命令卡可展开查看结构化输出，被取消的命令显示为 "Stopped"，与执行失败区分。卡片实现见 `ToolCallPartUI.tsx:1377-1536`。
- 暂停卡片提供批准、拒绝与停止三个操作，审批受理分用户执行与文件变更两个入口。卡片见 `ToolCallPartUI.tsx:1301`，两个审批入口见 `tools-builder.ts:545` 与 `filesystem.ts:11`。
- artifact 模态框提供刷新、全屏、在浏览器打开（仅在存在预览地址时）与发布网页（Vibedrop）四项操作；移动端把操作收进安全头部以避免误触，整体布局按移动优先重排。操作与布局同在 `src/renderer/modals/ArtifactPreview.tsx:1-239`。
- 下载卡提供图片内联预览、HTML 预览、导出保存按钮和错误回显，卡片主体与产物汇总区同在 `ToolCallPartUI.tsx:750-925`。
- 图片生成的结果图与下载文件一起集中到消息 artifacts 区，Work Mode 完成后折叠过程时间线时结果图仍保持可见。装配见 `ToolCallPartUI.tsx:1038-1069`，消息侧挂载见 `Message.tsx:553`。
- 用户侧交互集中在消息时间线的工具卡与下载卡，代码中没有编辑器或沙箱文件浏览器界面；按 `SandboxFile*` 与 sandbox files 检索无命中，`SandboxFileLink` 这个链接组件只负责渲染下载卡内的链接。

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

网络：SRT 沙箱配置没有设置 `allowedDomains`，注释显示最终生成 `(allow network*)`，即允许全部网络访问；Windows 平台不施加网络限制。沙箱之外的宿主桥接覆盖导出保存对话框、打开链接、平台相关的文件读取回退与 Vibedrop 外部发布。SRT 配置生成见 `manager.ts:401-407`，宿主桥接见 `code-execution.ts:249-272`，IPC 表面登记在 `ipc-handlers.ts:36-298`。

## 8. 持久化、恢复、分享与导出

- 消息与工具结果随会话行树写入 `session_messages` 表；临时沙箱目录放在系统临时目录下按会话 ID 分隔（`os.tmpdir()/chatbox-sandbox/<sessionId>`），启动时清理超过 7 天的旧目录。清理逻辑见 `manager.ts:1582-1606`。
- `create_download` 产物持久化到 userData，不参与上述清理；删除会话时提示用户并一并删除。持久化见 `manager.ts:1436-1505`，会话删除在 `src/renderer/stores/session/crud.ts`。
- 导出走系统保存对话框复制文件，导出的聊天记录中含工具调用摘要，大结果 blob 随备份重映射。导出入口见 `manager.ts:1511-1570`，备份重映射见 `packages/chatbox-core/src/backup-export/session.ts:77-210`。
- 重新打开会话后下载卡仍可用，依赖持久副本路径与允许根在重启时的回退。回退实现见 `manager.ts:1374-1380`。

## 9. 模型回流、对象感知与持续维护

- 上下文中默认保留最近若干轮的工具调用 part，更早轮次由 `cleanToolCalls` 清理，处于暂停状态的调用不进入上下文。清理逻辑见 `src/shared/context/builder.ts:101-154`。
- sandboxMode 下附件只以路径元数据注入，正文不带文件内容，元数据由 `<SANDBOX_PATH>` 与 `<PARSED_SANDBOX_PATH>` 两个占位符组成；模型需要时通过 `read_file` 或 `code_execution` 主动读取。注入逻辑见 `builder.ts:186-190`。
- 模型可查询沙箱状态：读取、列目录与全文检索三类操作均先做路径校验，工作目录由会话 ID 确定性计算（`resolveSandboxWorkingDir`），重启后复用同一目录，因此"查询 → 读取 → 定向修改"的闭环在代码路径上成立。该结论为静态推断，未运行验证；实现见 `manager.ts:1250-1255`。
- `view_image` 把沙箱或授权路径中的图片作为图像内容重新注入，让模型核对只靠文件名与文本输出看不到的视觉结果；不支持 tool-result image 的模型改由后续 user 消息注入，并限制历史图像负载。实现见 `src/renderer/packages/model-calls/toolsets/view-image.ts:302-488`。

## 10. 生命周期、资源治理与性能

- 每个会话同时最多运行一个子进程，终止统一走 `killRunningCommand` 并按工具调用 ID 定位目标；超时阈值为执行器 30 秒、工具层 120 秒，到点先发 SIGTERM 再发 SIGKILL，Windows 上改用 taskkill /T。POSIX 侧命令以进程组启动，进程树终止用负 pid 向整组发信号，避免留下孤儿进程。终止入口见 `manager.ts:874`，进程树实现在 `src/main/process-tree.ts`。
- stdout 与 stderr 各设 10MB 缓冲上限，超出后保留尾部并做脱敏。上限与清理逻辑见 `manager.ts:775-849`。
- 会话重置与进程退出时调用 `resetAllSessions` 关闭全部会话，预览服务器随应用退出关闭；临时目录按 7 天清理，持久 artifact 不参与清理。关闭流程见 `sandbox/index.ts:6-15`，清理见 `manager.ts:1600`。
- 多轮工具调用累计到上限时暂停请求以打断循环，该暂停可经 `pauseOnToolCallLimit` 关闭；对象本身即消息 part，随消息生命周期存在，没有独立的冻结或卸载逻辑。上限判定见 `orchestration.ts:750-752`。

## 11. 测试、已确认边界与未验证事项

测试覆盖（均未执行，仅静态确认存在）：

| 范围 | 测试文件 | 覆盖内容 |
|---|---|---|
| 主进程沙箱 | `manager.test.ts` | 路径与写入授权 |
| 主进程沙箱 | `manager.windows.test.ts` | Windows 原生路径 |
| 主进程沙箱 | `persist-artifact.test.ts` | 持久化、会话删除、路径穿越拒绝（第 114 行有对应断言） |
| 主进程沙箱 | `preview-server.test.ts`、`exec-script.test.ts`、`file-read.test.ts`、`truncate.test.ts` | 对应模块的单元测试 |
| renderer | `code-execution.test.ts` | 懒初始化、文件注入、错误处理 |
| renderer | `tools-builder.test.ts` | 不同 agent mode 下的工具可见性 |
| renderer | `stream-chunk-processor.test.ts` | `resultStorageKey` 溢出 |
| renderer | `agent-harness.test.ts` | 有效模式计算 |

对应测试清单另见 `docs/technical/code-execution.md:223-235`。

**已确认边界**：

- 云沙箱在 Web 与 Mobile 端是 stub，全部方法直接返回 "not yet implemented"，实际能力仅桌面端。见 `src/renderer/sandbox/cloud-provider.ts:17-86`。
- 消息级 `MessageArtifact`（把整条消息的 HTML 拼装成预览）与 `needArtifact`、`previewArtifact` 两个状态仍在代码中定义和计算，渲染层没有调用点，全仓检索未发现使用。定位见 `Message.tsx:85-431`。
- `autoPreviewArtifacts` 默认为关闭状态，见 `src/shared/defaults.ts:98`。

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

## 13. 与相邻类目的边界

- **Chat**：发送、中止、重试、fork、分支属于 Chat 层，本笔记只覆盖输出对象被创建/更新/恢复的部分。
- **消息渲染器**：Markdown、代码高亮、普通工具卡显示留在消息渲染器类目；本笔记接手的是工具结果物化为可寻址产物（下载卡、预览模态框、暂停继续）的部分。
- **Agent 工具**：`user_exec` 审批、MCP、Skills 的调度语义属于 Agent 工具类目；本笔记只记录其与输出对象（paused part、下载产物）的交点。
- **文件与项目工作区**：通用文件浏览、备份恢复属于文件类目；本笔记只覆盖模型生成的沙箱文件如何落盘、预览与回流。
- 图片生成（picture 会话、`imageGenerationStore` 的 `ImageGenerationRecord`，状态 pending/generating/done/error + blob 键）是第三类输出记录，但触发与调度属于 Agent 工具类目，此处仅记录存在性，未展开；记录新增 `source` 字段（chatbox_cli 来源），可在聊天内恢复该生成任务（独特功能笔记能力卡 2 有展开）。

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
- `src/renderer/stores/session/`：会话持久化与删除清理
- `src/shared/types/session.ts:159-206`：MessageToolCallPart 对象模型
- `src/shared/context/builder.ts:101-190`：工具调用回流与 sandboxMode 附件注入
- `docs/technical/code-execution.md`、`docs/technical/windows-sandbox.md`：设计文档

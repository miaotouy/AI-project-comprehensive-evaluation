# OpenOcta 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：静态源码核对。沿 A2UI 协议（Go 侧解析/流式包装/网关广播）与前端渲染、工具结果落库、本机执行与审批、转录回放逐层阅读，并用 grep 交叉验证（a2ui、surface、deliverable、approve、resume、checkpoint、diff）；未运行应用、未执行命令、未做交互验证
>
> 调查范围：Agent 产出如何成为可交互或可执行对象（结构化消息、工具产物、脚本执行、审批、回放）及承载它的运行时；排除普通消息渲染样式、模型接入与上下文装配、渠道投递、技能市场、多 Agent 编排的调度细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenOcta 的生成式输出走 **A2UI v0.9（Agent-to-UI）声明式协议**，而不是 Artifact、Canvas 或 Notebook。服务端把模型文本流包装成 `createSurface` / `updateComponents` / `updateDataModel` 三类消息，经网关的 `chat` 事件以 `state: "a2ui"` 推给前端；前端用 `@a2ui/web_core` 的 MessageProcessor 加 `@a2ui/lit` 的 basic catalog 渲染，用户点击组件后通过 `chat.a2ui.action` 回到网关并合成一条新的用户消息，形成"生成 → 渲染 → 交互 → 再生成"的闭环。

协议与渲染栈具备声明式交互对象（能力谱系 G2）的完整组件，但**当前快照的生产端只发文本表面**：`AssistantTextStream` 固定生成 Column + Text 结构，富组件（按钮、输入框等）有渲染与事件回传路径，却本次未找到由模型或工具提交 components 的入口。因此实际投影更接近 G0/G1（格式化文本与可查看文件）。G3（隔离执行的 Artifact）与 G4（可编辑工作区）本次未找到；执行发生在本机进程，没有容器、WebView 或 iframe 沙箱运行时。

事实源分三处：会话 JSONL 转录保存助手消息与 A2UI 内容块，工作区文件保存工具真正写盘的结果，检查点文件保存可恢复的运行状态。三者不互相覆盖：转录里的 A2UI data model 是展示侧事实源，模型历史则只从 text/thinking/toolcall 三类内容块重建。

本机命令执行采用 deny 规则转换后的遗留校验器：命令名检查只取整条字符串的首词，片段与禁用参数另行匹配；完整的 allow/ask/deny 分段求值器没有生产调用。开启审批时另按工具名统一中断 `execute`，规则中的 ask/allow 不参与选择哪些调用需要审批（见第 7 节）。

## 系统边界与完整主链路

本类目从"输出获得独立消息形态或运行环境"开始。消息调度、上下文装配、发送中止属于对话请求类目；气泡样式与 Markdown 属于消息渲染器类目；工具注册与执行语义属于 Agent 工具类目。本文只记录产出被物化为可展示对象、可执行命令和可恢复转录的部分。

**运行时的实际形状。** Wails 只是窗口壳：`src/main.go:71-107` 创建窗口并把内置的启动页交给 WebView，启动页在探活成功后跳转到 `http://127.0.0.1:18900?_shell=d`（`src/wails-bootstrap/index.html:10-45`）。界面本身由本地网关进程托管的 Web 页面提供，业务通信走网关 WebSocket，而不是 Wails 的运行时事件——全仓库只有 `wailsruntime.Quit` 一处运行时调用（`src/main.go:92`）。这一点决定了"结果回显"由网关事件与 HTTP/WS RPC 承担。

**主链路（触发 → 生成 → 投递 → 展示 → 持久化 → 重开 → 回流）：**

1. 用户发送消息，网关 `chat.send` 建立运行时并进入流式回合（`src/pkg/gateway/handlers/chat.go:2342` 附近的运行时创建）。
2. Eino 迭代器产出模型增量，`StreamEventsFromIterator` 为每个会话创建 `AssistantTextStream`（`src/pkg/agent/eino/event_bridge.go:304`）。
3. 文本增量同时走两条路：包装成 A2UI 消息（`src/pkg/agent/eino/a2ui_emit.go:25-30`），以及作为普通 text delta 事件。首块文本触发 `createSurface`、一次布局 `updateComponents`，之后每个增量都发一条携带**累积全文**的 `updateDataModel`（`src/pkg/a2ui/stream.go:26-70`）。
4. 网关把 A2UI 事件转成 `chat` 事件广播，并把内容块并入当前助手消息（`src/pkg/gateway/handlers/chat.go:2679-2690`）。
5. 回合结束时收到 `message_stop`：若本轮出现过 A2UI，则剥掉 text 块、合并同 surface 的 data model，再写入转录并广播 final（`chat.go:958-973`、`chat.go:997-1067`）。
6. 前端按消息内容分派：纯文本表面渲染为 Markdown，非文本表面挂载 `chat-a2ui-panel`（`ui/src/ui/chat/grouped-render.ts:1375-1412`）。
7. 用户点击组件 → `chat.a2ui.action` → 网关把动作序列化成用户消息并触发新一轮（`chat.go:3622-3674`）；前端同时把被消费的 surface 从历史中移除（`ui/src/ui/chat/a2ui-bridge.ts:122-160`）。

**重开链路：** `chat.history` 读转录并按 limit（默认 100，上限 1000）返回最后若干条（`chat.go:1556-1616`），前端把 a2ui 块交给面板重放；面板按"首条消息指纹 + 已处理条数"决定整体重放还是增量追加（`ui/src/ui/components/chat-a2ui-panel.ts:207-243`）。

## 1. 触发方式、输出协议与对象模型

**三种触发来源。**

- **助手文本**：唯一的常规生产路径。文本增量由服务端包装成 A2UI，模型本身不写协议字段。
- **工具结果**：工具调用与结果作为 `toolCall` / `toolResult` 内容块进入转录和界面；写文件、抓网页、读图片等工具的输出还会被解析成附件块（`src/pkg/gateway/handlers/chat.go:2751-2806`）。
- **A2UI 客户端动作**：组件事件被转换成一条带 `[A2UI Action: <name>]` 前缀和完整 JSON 上下文的用户消息（`chat.go:3649-3662`），随后走普通发送流程。

**协议形状。** 一条服务端消息必须且只能带一个动作键，取值集合为 `createSurface`、`updateComponents`、`updateDataModel`、`deleteSurface`，另兼容 v0.8 的 `surfaceUpdate` / `dataModelUpdate` / `beginRendering` 并在解析后归一（`src/pkg/a2ui/message.go:14-175`）。catalog 标识会被归一成客户端 basic catalog 的正式 URL，接受 `basic`、`standard` 等简写（`message.go:150-160`）。校验只检查"恰好一个动作键"，不校验组件树结构（`message.go:161-171`）；组件数组同时接受数组、`{"item":[...]}` 包装和以 id 为键的对象映射（`message.go:53-100`）。

**对象模型。** A2UI 对象没有独立于会话的持久标识：

| 维度 | 实现 |
|---|---|
| surface 标识 | 取当前会话 ID，空则回退 `main`（`src/pkg/a2ui/stream.go:11-23`） |
| 组件标识 | 组件自带 `id`，以 `root`/`body` 等字符串在 surface 内寻址（`stream.go:41-60`） |
| 数据模型 | 单个路径 `/content` 承载正文（`stream.go:62-69`） |
| 版本 / 来源 | 无对象版本号、无来源消息引用；归属由转录消息的 id 与时间戳间接表达 |
| 状态 | 无生命周期状态；surface 只在流式过程中存在，回合结束即定稿 |

转录消息 id 是 8 位截断 UUID（`chat.go:1005`），不是面向对象的稳定 ID。内容块类型由 `src/pkg/session/transcript.go:41-55` 统一定义，包含 text、thinking、toolCall、toolResult、image、file、a2ui 等；`a2ui` 字段直接存整条协议消息。

**能力声明与边界。** 对象没有能力声明字段；能否交互完全由渲染端按组件类型与目录决定（见第 4 节）。

## 2. 增量生成、更新与最终化

**更新粒度是整段覆盖，不是补丁。** `AppendDelta` 每次把累积后的全文写进 `updateDataModel.value`（`src/pkg/a2ui/stream.go:62-69`）。前端 `dedupeA2UIMessages` 以 `surfaceId + path` 为键，用最新一条替换旧条（`ui/src/ui/chat/a2ui-bridge.ts:319-379`）；服务端同样做折叠：`AppendAssistantA2UIBlock` 命中同一 surface/path 时替换原块（`src/pkg/a2ui/dedupe.go:83-108`），落库前再整体 `CoalesceAssistantA2UIBlocks`（`src/pkg/a2ui/dedupe.go:24-32`）。因此一次回复在转录里只剩一条最终 data model，流式中间态不持久化。

**文本去重规则。** 只要本轮出现过 A2UI，纯 text 块在落库前被剥离（`chat.go:916-930`、`chat.go:958-973`）。这带来两个并存表示：界面看到的是 A2UI 的 data model，IM 投递则从 textBuf 兜底取原文，代码注释明确写出这一分工（`chat.go:1105-1119`）。

**回合收口与失败。**

- 正常：`message_stop` 携带 stop reason，触发快照落库并按 `tool_use` 与否区分 turn/final 广播（`chat.go:2818-2860`、`chat.go:1057-1061`）。
- 工具轮：助手消息带 toolCall 落库，工具结果按"先挂起、助手消息落库后再补写"的顺序写入转录，避免前端先看到结果后看到调用（`chat.go:2570-2595`）。
- 中断：`run_interrupted` 事件把 stop reason 置为 `interrupt`，同时广播一条 `state: "interrupted"` 的 `chat` 事件（`chat.go:2811-2817`、`chat.go:3231-3253`）。
- 协议解析失败：服务端流式行缓冲遇到不完整 JSON 会把整段退回缓冲等下一块（`src/pkg/a2ui/parser.go:55-95`），不产生错误事件；前端处理消息抛错时改为显示 "Interactive UI failed to render" 面板并把异常打到控制台（`ui/src/ui/components/chat-a2ui-panel.ts:228-242`、`:252-260`）。

## 3. 投影表面与多视图关系

所有投影都在同一条消息流内，没有侧栏画布或独立窗口。

| 表面 | 触发条件 | 承载实现 |
|---|---|---|
| 气泡内 Markdown | 仅 Text/Column/Row 的纯文本表面 | `isTextOnlyA2UIDisplay` 判定后直接走气泡（`ui/src/ui/chat/a2ui-bridge.ts:269-300`、`grouped-render.ts:1389-1392`） |
| 交互面板 | 表面含非文本组件 | `chat-a2ui-panel` 内 `a2ui-surface`（`chat-a2ui-panel.ts:276-288`） |
| 工具卡片 | toolCall / toolResult 块 | `ui/src/ui/chat/tool-cards.ts:11-56`，图标与标题来自 `ui/src/ui/tool-display.json` |
| 交付物附件条 | 工具输出被识别为可预览文件 | `ui/src/ui/components/chat-deliverable-attachments.ts`，数据来自 Go 侧附件块 |
| 文件预览浮层 | 点击附件 | `ui/src/ui/components/chat-file-preview.ts:246-269` |
| 技能提炼弹窗 | 用户对整段会话执行"提取技能" | `ui/src/ui/controllers/chat-extract-skill.ts:15-42` |

纯文本表面主动绕过 A2UI 面板是设计选择，注释说明原因是要保住可靠换行（`grouped-render.ts:1389`）。同一对象没有多份同步投影：面板只是把同一批消息喂给一个新的 MessageProcessor 实例（`chat-a2ui-panel.ts:39-53`）。

## 4. 表现类型、依赖与运行环境

**渲染层级。** 只有一层"声明式组件 + Markdown"，没有 HTML 组件、脚本组件或语言解释器：

- 组件由 `@a2ui/lit` 的 basic catalog 提供，面板样式针对 `a2ui-basic-text`、`a2ui-basic-row`、`a2ui-basic-button` 做了覆盖（`ui/src/ui/components/chat-a2ui-panel.ts:88-108`），说明文本、行列布局与按钮是实际使用过的组件。
- Text 组件的 Markdown 由注入的渲染器处理，最终仍走 DOMPurify 白名单清洗（`ui/src/ui/chat/a2ui-markdown.ts:4-7`、`ui/src/ui/markdown.ts:172-221`）。
- 依赖集中在三处：`lit` 与 `@a2ui/lit`、`@a2ui/web_core` 负责组件与协议，`marked` + `dompurify` 负责文本（`ui/package.json:13-19`）。

**交付物运行环境。** HTML 与 PDF 在预览浮层中用 `iframe` 直接载入 data URL（`chat-file-preview.ts:225-232`），未设置 `sandbox` 属性；按浏览器规则 data URL 文档属 opaque origin，但这属于运行时行为，本次未验证。图片走 `<img>`，文本类文件由前端按扩展名解码后渲染表格或代码块（`chat-file-preview.ts:212-244`）。

## 5. 用户交互、事件与错误反馈

**事件回传。** 面板把 `A2uiClientAction` 交给 chat 控制器的 `dispatchA2UIActionFromChat`，后者先按 surface 清理本地历史，再发 `chat.a2ui.action` 请求并把返回的 runId 设为当前运行（`ui/src/ui/controllers/chat.ts:180-228`）。网关侧只透传 `name`、`surfaceId`、`sourceComponentId`、`timestamp`、`context`（`a2ui-bridge.ts:74-93`），不解释业务语义——交互含义完全落在下一轮模型提示里。

**交互状态不恢复。** 面板的 processor 是组件私有实例，`resetChatA2UISurfaces` 已退化为空操作（`a2ui-bridge.ts:69-72`）；重开时从数据模型重建，按钮的按下态、输入框内容等不落库。动作提交后原 surface 被从消息中剔除（`a2ui-bridge.ts:122-160`），因此同一按钮不会被重复点击消费。

**命令类确认不通过组件。** `stripCommandConfirmationButtons` 会删除 action 名以 confirm 开头、或文案含"确认/取消"的按钮，并追加一句"请在聊天输入框回复 **确认** 执行"（`src/pkg/a2ui/confirmation_strip.go:7-46`、`:119-161`）。也就是说，命令批准被有意退回对话层，由用户在输入框作答。该修复函数只在 `repair.go:164` 的组件修复链内被调用，而修复链本身在当前快照里没有非测试调用方（检索范围：`src/**/*.go` 中 `RepairMessages`、`ExtractMessagesFromToolParams` 的引用），所以它更像为外部/历史产出准备的兼容层。

**错误反馈。** 面板级错误是局部文案；运行错误走 `chat` 事件 `state: "error"` 并清空流式状态，由历史重载呈现（`ui/src/ui/controllers/chat.ts:611-618`）。前端没有为未知 state 设兜底分支（`ChatEventPayload` 的联合类型只列了 7 种，见 `chat.ts:232-236`），见第 7 节关于中断的说明。

## 6. 编辑、diff、版本与协作

本次未找到面向输出对象的编辑、diff、版本或协作机制。检查范围：`ui/src/ui/chat` 下除测试外全文检索 diff、patch、undo、revert、version 无命中；`src/pkg/a2ui` 只处理消息归一与展示修复，不含变更集。用户能做的"修改"只有两种：

- 在聊天框继续说话，触发新一轮生成（整段替换，不保留旧版本）；
- 通过工具改写工作区文件，结果以新的工具结果消息出现，没有接受/拒绝、回滚或历史版本界面。

因此，`write` / `edit` 之类的文件工具在 UI 上表现为工具卡片与 diff 文本（由工具输出渲染），而不是可审查的补丁对象。

## 7. 能力桥、执行位置与权限范围

**执行位置是本机进程。** Eino DeepAgent 使用本地文件系统后端，`Execute` / `ExecuteStreaming` 直接拉起子进程：Windows 走 `cmd.exe /c`，并隐藏控制台窗口（`src/pkg/agent/eino/localbackend/shell_windows.go:22-33`、`:29-31`）；非 Windows 委托给 eino-ext 的本地后端（`shell_unix.go:12-26`）。未找到容器、虚拟机、WebView、iframe 或远端沙箱作为执行环境；`runtime.Options.EnableSandbox` 字段存在但未被运行时读取（`src/pkg/agent/runtime/runtime.go:206`，全仓库检索仅赋值处）。

**命令校验、中断审批与兼容文件分属不同路径。**

| 路径 | 条件与行为 | 实现边界 |
|---|---|---|
| 本机执行前校验 | 策略启用时，把 deny 规则与通用校验字段转换为遗留配置，注入文件系统后端 | 不消费 allow、ask 与默认策略，也不调用完整分段求值器 |
| Eino 中断审批 | 审批开关启用时，每次首次调用 `execute` 均触发 `StatefulInterrupt`，带批准结果恢复后继续或返回拒绝文本 | 依据工具名决定是否审批，未按命令规则筛出 ask，也未用 allow 跳过审批 |
| SDK 兼容权限文件 | 审批队列配置启用时，把规则写成工作区下的 Claude 权限设置文件 | 当前本机 Eino 校验与审批中间件未读取该文件 |

本机校验的规则转换只复制 deny、禁用参数、长度和密钥模式等字段；实际校验按整条命令首词匹配禁用命令，再对整串匹配片段、对后续分词匹配禁用参数，并检查长度和控制字符。密钥模式未在校验函数使用，阻止 shell 元字符的注释所对应的检查已注释。复合命令后段的命令名因此不在首词匹配范围，片段或参数规则仍可能命中（[runtime.go:104–114](<../../openocta/src/pkg/agent/runtime/runtime.go#L104-L114>)、[command_policy.go:307–326](<../../openocta/src/pkg/agent/runtime/command_policy.go#L307-L326>)、[command_validation.go:15–74](<../../openocta/src/pkg/agent/runtime/command_validation.go#L15-L74>)）。

完整求值器 `EvaluateCommandAccess` 的实现包含分段后取最严格结果，单段按 deny、allow、ask、默认策略的顺序匹配；全部 Go 源码中只找到包装方法与测试引用。这套求值结果没有被注入后端；实际注入的是上述遗留校验回调（[command_policy.go:157–242](<../../openocta/src/pkg/agent/runtime/command_policy.go#L157-L242>)、[engine.go:76–78](<../../openocta/src/pkg/agent/eino/engine.go#L76-L78>)）。

审批中间件按工具名拦截，恢复入口是 `chat.resume`；运行时另将三组规则写入 SDK 兼容文件，两条链路各自消费不同状态（[engine.go:100–102](<../../openocta/src/pkg/agent/eino/engine.go#L100-L102>)、[approval_middleware.go:45–85](<../../openocta/src/pkg/agent/eino/approval_middleware.go#L45-L85>)、[runtime.go:151–159、392–450](<../../openocta/src/pkg/agent/runtime/runtime.go#L151-L159>)）。

**UI 侧审批入口与后端不闭环（静态事实）。** 聊天页有一个 `exec.approval.requested` 驱动的居中确认卡（`ui/src/ui/views/exec-approval.ts:25-89`），决议经 `exec.approval.resolve` 发送（`ui/src/ui/app.ts:976-994`）；但该事件的广播名单里只有事件名（`src/pkg/gateway/ws/hub.go:109-112`），仓库内没有生产者，`exec.approval.request` 与 `exec.approval.resolve` 的处理函数分别是"未实现"和直接回 `ok` 的桩（`src/pkg/gateway/handlers/exec_approvals.go:41-48`、`handlers/stubs.go:93-97`）。另一条 `approvals.list` / `approve` 通道面向 `security.ApprovalQueue`（`handlers/approvals.go:157-284`），但执行链没有调用 `Request` 写入记录（检索范围：`src/**/*.go` 中 `GetApprovalQueue`、`NewApprovalQueue`、`q.Approve` 的全部引用）。同时，中断事件以 `chat` 事件的 `state: "interrupted"` 下发（`chat.go:3240-3250`），而前端事件联合类型与处理函数都没有这一分支，也没有 `chat.resume` 的调用方（检索范围：`ui/src` 全量）。结果是：审批相关的数据结构与 UI 都在，端到端路径在本次快照中没有接通；实际可见的批准方式仍是模型在对话里询问、用户回"确认"。

**工具能力面。** 内置工具覆盖文件读写、shell、网页抓取、浏览器、会话与定时任务等（`src/pkg/agent/tools` 目录），文件写路径只做相对路径归一到工作区、Windows 盘根文件重定向，不强制阻止绝对路径写出工作区（`src/pkg/agent/eino/localbackend/paths.go:15-59`）；附件提取则显式校验目标位于工作区内（`src/pkg/agent/tools/deliverable_files.go:292-329`）。

## 8. 持久化、恢复、分享与导出

**转录是唯一消息事实源。** 每轮助手消息以一行 JSON 追加到会话 JSONL，含内容块、耗时、token 与 stop reason（`chat.go:1042-1055`）；读取时按候选路径回退，遇到超大行导致的截断会保留已解析部分而不是清空历史（`chat.go:1592-1610`）。

**交付物以 base64 内联。** 可预览文件在落库时被读成 `source.data` 的 base64 内容块（`src/pkg/agent/tools/deliverable_files.go:202-245`），因此转录文件会随附件体积膨胀；大小上限按类型分别是文本 2 MiB、HTML/PDF 2 MiB、图片 5 MiB（`deliverable_files.go:34-36`）。

**另一个产物通道。** 模型在回复里提到的工作区路径会被正则扫描并补成附件块（`deliverable_files.go:491-530`、`:531-553`），以及历史遗留的 `@@OPENOCTA_ATTACHMENTS@@` 标记解析（`ui/src/ui/chat/openocta-attachments.ts:1-70`）。

**恢复与重放。** 面板的 processor 不持久化，靠消息数组重建；`needsFullReplay` 在首处理、消息数变少、首条消息变化时整体重放，否则只追加新消息（`chat-a2ui-panel.ts:222-237`）。

**导出与分享。** 可见的导出只有：复制消息为 Markdown（`ui/src/ui/chat/copy-as-markdown.ts`）、下载附件、把会话提炼成 SKILL.md 后下载（`handlers/chat_extract_skill.go:37`、`ui/src/ui/controllers/chat-extract-skill.ts:44-52`）。会话"分享链接"只是带 `session` 查询参数的本地 URL（`ui/src/ui/app-render.ts:261-266`），不是对象级分享。

**定时任务结果。** cron 会话的结果以文本文件写到状态目录 `cron/runs`，供运行历史页读取（`chat.go:1169-1209`），是可回看的运行记录，不是可继续操作的对象。

## 9. 模型回流、对象感知与持续维护

**回流方式一：动作即消息。** A2UI 动作被序列化为用户消息，因此模型只需理解文本；它无法按 surfaceId 查询或定点修改已有表面。

**回流方式二：转录重放。** 新回合从转录重建模型历史，`assistantTranscriptToSchema` 只识别 text、thinking 与 toolcall 三类内容块（`src/pkg/agent/eino/transcript_history.go:301-327`）。由于助手文本轮在落库时已被剥成纯 A2UI（见第 2 节），这类消息在重建历史时不会产生任何模型消息（函数在 text 为空且无 toolcall 时返回 nil，`transcript_history.go:322-326`）。这是静态代码可直接推出的事实：模型在跨回合时看不到自己上一轮以 A2UI 形式保存的自然语言回复。对对话质量的实际影响未运行验证；同回合内的工具结果回流不受影响，因为工具消息本身是 text 块。

**对象身份不跨回合。** surfaceId 等于会话 ID，且每次回合结束都会 `Reset` 本文本流（`src/pkg/agent/eino/event_bridge.go:195-197`），所以不存在"上一轮的某个表面"这一可寻址概念，也就没有"查询 → 读取源码 → 定向修改"的闭环。

## 10. 生命周期、资源治理与性能

**前端限额。** 工具流最多保留 50 条、300 毫秒合批、单条输出截断到 12 万字符（`ui/src/ui/app-tool-stream.ts:4-6`、`:90-95`、`:120-129`、`:145-157`）。A2UI 面板对消息做 JSON 指纹比较与去重，避免重复处理（`a2ui-bridge.ts:319-379`、`chat-a2ui-panel.ts:216-238`）。

**潜在成本。** 每个文本增量都携带全文，服务端每轮做一次同路径替换、前端每帧做一次去重与指纹计算。按实现结构推断，长回复的传输与字符串比较量随文本长度平方增长（未做基准测试，未作定性结论）。

**卸载与释放。** 面板没有 iframe、worker、定时器或媒体资源；面板销毁即释放 processor。文件预览浮层是固定定位的独立元素，关闭即从模板移除（`chat-file-preview.ts:246-269`）。没有"不可见对象暂停"的需要，因为没有常驻运行实例。

## 11. 测试、已确认边界与未验证事项

**测试覆盖（静态可见）。** Go 侧为协议与展示修复写了单元测试：解析、流式行缓冲、消息合并、参数解包、纯文本表面、确认按钮剥离、文本排版修复（`src/pkg/a2ui/*_test.go`）。前端有 a2ui 桥接、附件块提取与会话事件处理测试（`ui/src/ui/chat/a2ui-bridge.test.ts`、`file-blocks.a2ui.test.ts`、`ui/src/ui/controllers/chat.test.ts`），跑在 Playwright 的 Chromium 无头浏览器里（`ui/vitest.config.ts:4-14`）。本次未运行任何测试。

**已确认边界。**

- 没有对象级 ID、版本、diff、接受/拒绝或沙箱执行；只有会话消息、工具结果与工作区文件。
- A2UI 生产端只有文本包装，富组件的生产者本次未找到。
- 本机命令名校验只匹配整条命令首词；完整分段求值器没有生产调用，allow、ask 与默认策略未进入遗留校验路径。审批开关启用后统一拦截 `execute`，和规则求值分开。
- 审批的 UI 通道与后端实现未接通，对话文本确认与 Eino 中断批准是两条不同路径。

**未验证事项。** 富交互组件的实际渲染效果（当前无生产者可供触发）、`iframe` 载入 data URL 时的脚本与同源行为、A2UI 文本表面在超长回复下的流式性能、`chat.resume` 恢复后的界面表现、Windows 与 macOS 下 shell 输出的实际差异。未实际执行复合命令，也未联调命令规则与审批中断；上述接线与匹配范围来自静态调用链。

## 关键源码索引

- `src/pkg/a2ui/`：协议消息、流式包装、修复与合并（`message.go`、`stream.go`、`parser.go`、`repair.go`、`dedupe.go`、`confirmation_strip.go`）
- `src/pkg/agent/eino/event_bridge.go`、`a2ui_emit.go`：模型增量到 A2UI 事件的桥接
- `src/pkg/gateway/handlers/chat.go`：广播、落库、A2UI 动作、`chat.resume`、cron 结果
- `src/pkg/gateway/handlers/exec_approvals.go`、`stubs.go`、`approvals.go`：审批 RPC 与队列
- [runtime.go:104–114](<../../openocta/src/pkg/agent/runtime/runtime.go#L104-L114>)、[command_policy.go:307–326](<../../openocta/src/pkg/agent/runtime/command_policy.go#L307-L326>)、[command_validation.go:15–74](<../../openocta/src/pkg/agent/runtime/command_validation.go#L15-L74>)：实际命令校验链
- [approval_middleware.go:45–123](<../../openocta/src/pkg/agent/eino/approval_middleware.go#L45-L123>)、[shell_windows.go:35–85](<../../openocta/src/pkg/agent/eino/localbackend/shell_windows.go#L35-L85>)：工具名中断与本机执行
- `src/pkg/agent/tools/deliverable_files.go`：工具输出到附件块
- `src/pkg/agent/eino/transcript_history.go`：转录到模型历史
- `ui/src/ui/chat/a2ui-bridge.ts`、`grouped-render.ts`、`components/chat-a2ui-panel.ts`：前端渲染与重放
- `ui/src/ui/components/chat-file-preview.ts`、`chat-deliverable-attachments.ts`：交付物预览

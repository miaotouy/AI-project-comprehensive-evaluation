# Dify 已调查能力汇总

> 汇总对象：`https://github.com/langgenius/dify`
>
> 汇总更新日期：2026-08-28
>
> 依据：本轮 Chat、会话与消息、对话请求、Chat UI、消息渲染、Agent 工具、LLM 渠道、生成式输出、外部协作与独特功能调查笔记；代码快照以各来源笔记所列 `a9319c86ee9468f6e1a56b3f22945a63b95c282f` 为准
>
> 汇总方法：按应用发布、运行记录、公开交互、资源解析与外部接入合并来源结论；保留来源中的静态证据状态与未验证边界
>
> 汇总范围：应用发布、聊天与 workflow 运行、会话、公开 UI、工具、模型渠道、消息投影、输出对象、RAG/知识库、Prompt IDE、LLMOps、Agent v2、插件安装、DSL 可移植性与外部协作；文件存储、控制台 workflow 编辑器、触发器与商业托管未作全面调查
>
> 文档定位：按项目检索已调查能力摘要，不作为横向比较或整改依据

## 项目概览

Dify 的产品中心是租户工作区中**可发布的应用定义**。作者在控制台配置应用、模型、工具、知识和 workflow，终端用户或业务系统通过发布后的 WebChat/Chatbot、嵌入组件或 service API 触发它。后端再以应用模式为分界，将一次调用导向 chat、Agent Chat、advanced chat、workflow、Agent 或 completion 的专属生成器。其核心不是某一套聊天 UI，而是“定义一次，按多个调用面运行”的应用平台。

```text
工作区成员配置应用与资源
  -> 发布为公开 Web/嵌入/API 可调用面
  -> 终端用户或外部系统提交输入
  -> 应用生成服务按 mode 分派
  -> 消息型生成器或 workflow graph runtime 执行
  -> Conversation/Message、workflow run、task/event 成为服务端记录
  -> 公开 UI 或 API 响应消费结果
```

这个结构同时解释三项重要边界：第一，控制台、公开 Web 和 service API 不是同一权限/配置表面；第二，共享生成入口不保证每个 mode 共享会话、上下文或停止语义；第三，浏览器的聊天状态是事件投影，应用配置、模型凭据和持久化记录在 API/运行时侧。产品骨架的依据来自本汇总列出的 Chat、请求、运行时与渠道管理笔记。

## 已调查能力

### 发布应用的聊天与 workflow 调用

公开 `/chat/[token]`、`/chatbot/[token]` 和嵌入式 Chatbot 是已发布应用的运行入口，不是完整控制台。带历史页面和嵌入式页面均复用 `base/chat` 的共享 hook：用户提交 query、inputs、files、conversation ID 与父消息引用，浏览器先插入本地 question/answer 占位，再用 SSE 合并文本、Agent thought、文件、task 和 workflow 事件。服务端 `AppGenerateService` 依据应用 mode 选择 generator；workflow API 还能绕开聊天表面直接提供 streaming/blocking 调用与停止入口。

这套能力的产品意义是一个应用定义可面向终端用户和业务集成同时交付。已确认的限制是：公开页不让用户任意编辑租户模型、工具和知识配置，workflow run 也不能仅因显示文本就当作普通线性对话。详细主链见[Chat](../Chat/Dify-Chat调查笔记.md)和[对话请求与上下文](../对话请求与上下文/Dify-对话请求与上下文调查笔记.md)。

### 服务端会话、消息与运行记录

Conversation 与 Message 为已发布聊天提供数据库事实源；会话/消息服务按 application 与 user 限定归属，浏览器 React tree 只承担本轮流式投影。会话可能在首次真正发送时由生成器初始化，历史列表与消息读取采用基于最后 ID 的分页。消息还可关联文件、feedback、annotation、Agent thought 和 workflow run，因此可见回答不是单一 role/content 字符串。

重新生成会新建 Message，并将 `parent_message_id` 指向所选回答之前的有效回答；前端只在本地选择可见 sibling，服务端提示词辅助函数按 parent pointer 回溯一条上下文路径。`MessageChain` 仍会随会话删除清理，却不是当前 sibling 的写入权威。删除先软标会话，再异步删除消息、thought、文件、反馈、表单与变量，失败重试并由 sweep 补投。未确认跨标签并发、崩溃恢复、全文搜索、归档/回收站、导入导出。详见[会话与消息管理](../会话与消息管理/Dify-会话与消息管理调查笔记.md)。

### 面向终端用户的聊天工作台与内容投影

历史模式提供新建、切换、置顶、取消置顶、删除与重命名的会话入口；嵌入式模式在切换/新建前会先停止当前本地任务。Composer 由应用输入 schema 驱动，可提交文件和变量，但不是通用富文本编辑器，也不负责 Provider/工具选择。停止、重新生成、suggested questions、候选回答、引用、Agent thought、文件与 workflow 暂停输入均在共享组件树中进入用户视野。

UI 的状态所有权主要是 hook/context 中的 current conversation、responding、task ID、workflow subscription 与临时 tree；服务端 ID 回填和结束后的消息重取使其与持久化数据重新对齐。可确认组件中的 `aria` 属性与事件绑定，未在浏览器运行，因而没有对键盘、移动端、焦点、长会话性能或通知做实际体验结论。分别见[Chat UI](../Chat%20UI/Dify-ChatUI调查笔记.md)和[消息渲染器](../消息渲染器/Dify-消息渲染器调查笔记.md)。

### 租户级模型渠道与运行时选择

Provider、模型配置、Provider 级凭据、模型级凭据和负载均衡配置由服务端 tenant 作用域管理。`ProviderManager` 读取缓存/持久化配置，`ModelManager.get_model_instance` 再按 tenant、Provider、模型类型和模型名解析可调用实例；默认实例路径不长期缓存凭据，显式启用凭据缓存时才可能取得旧配置。公开 WebChat 因此提交的是应用输入和选择引用，不是原始 API Key。

候选凭据经当前 plugin validate 后按 tenant 加密保存，读取时脱敏；模型目录由已安装 Provider plugin 组装，调用时 Dify 把解密凭据与统一请求交给 Plugin Daemon，再把规整结果的 usage、延迟写进消息/工作流并投递 trace。已确认同模型多 Key 的 round-robin 与限流/授权/连接异常冷却，但不能把它写成跨 Provider failover。厂商 HTTP、连接测试真实动作、备份/日志脱敏、usage/成本精度和 trace 实际交付未运行。详见[LLM 渠道管理](../LLM渠道管理/Dify-LLM渠道管理调查笔记.md)。

### 工具、MCP、插件与 workflow-as-tool

Dify 的工具不是一种单一实现：内置工具、API 工具、插件工具、MCP 工具和 workflow 工具共享 Provider/Tool 管理表面，但最后进入不同的 controller、执行域和错误路径。MCP 配置及 headers/OAuth 处理在服务端管理器中完成；workflow 可以在兼容性检查后登记为 tenant 下的工具 Provider，含 human-input 节点的 workflow 被排除。传统 Agent 节点与 Agent v2 又有不同的 runtime request builder/工具交接。

传统 function-calling Agent 已确认把原生 tool calls 逐个串行执行，持久化 thought/observation 后按 `tool_call_id` 回注下一轮模型，默认/最高循环上限为 10/99。Agent v2 另在 dify-agent runtime 中循环，核心工具经内部 API 回到 Dify 做 tenant 校验后执行，插件工具则进入 daemon；`ask_human` 是可恢复的 deferred tool，不是通用逐调用审批。真实模型、Plugin Daemon/MCP、工具预算和端到端授权未运行；没有找到 Dify Tool/MCP/API 通用逐调用批准令牌。详见[Agent 工具](../Agent工具/Dify-Agent工具调查笔记.md)。

媒体创作也可作为这条 Agent 编排的一个方向：传统 `agent-chat` 能配置 DALL-E、Stable Diffusion 等媒体工具；“SVG Logo Design”模板声明了 DALL-E 3 图片生成与 Vectorizer SVG 转换的连续流程。工具结果中的图片或链接会转换为 Dify 工具文件并随消息回流，因而支持“需求 -> Agent 调用媒体工具 -> 结果交付”的会话链。不过 Dify 本体尚未确认有独立的媒体任务历史、编辑版本或资产复用工作台，不能将其写成完整的内置媒体创作平台；模板的跨工具传递和实际外部执行也尚未运行验证，详见[Agent 角色配置](../Agent角色/Dify-Agent角色配置调查笔记.md)。

### Workflow 作为可发布、可再复用的运行单元

workflow 应用把输入校验、图定义、workflow run、节点事件、流/阻塞响应和停止连接成独立交付单元；它既可以被已发布应用或 service API 调用，也可在限制条件下作为另一个 Agent 的工具。WorkflowRun/节点执行保存状态、outputs、错误、耗时和 token，较大节点数据可 offload 到对象存储，后续能从 API、聊天/控制台日志或归档读取。该组合跨越应用发布、图运行、工具和外部调用，不能由单一“有 workflow”或“有工具”栏目完整说明。

workflow run 是可寻址、可回读和可归档的执行记录，不是已确认的可编辑 Artifact 或持续工作区；未找到在同一 outputs 上的版本、patch 或模型回流路径。Prompt IDE、LLMOps 注解回复、Agent v2 和 Marketplace 安装也已补到静态 `主链确认`，但 Trigger Provider 仍只有 `入口确认`。真实模型、外部 callback、worker 交付与跨租户行为都没有运行验证。详见[独特功能](../独特功能/Dify-独特功能调查笔记.md)和[生成式输出与运行时](../生成式输出与运行时/Dify-生成式输出与运行时调查笔记.md)。

### 知识资产与 RAG Pipeline

Dify 将 Dataset、Document、分段、处理规则、索引状态和检索设置作为 tenant 下可长期维护的知识资产。上传文件、Notion 页面或网页来源写入 Document 后，会通过异步任务索引；聊天/completion 应用的 runner 和 workflow 的 Knowledge Retrieval 节点都能消费检索结果，后者将来源列表作为图变量并记录用量元数据。因此知识库既不是用户本轮上传的附件，也不是只存在于某一个 Chatbot 配置中的静态提示词。

数据集还可以进入独立 RAG Pipeline：控制台提供创建、编辑、节点试跑与 Pipeline 路由，后端维护草稿和已发布 workflow、运行及节点执行记录，并支持 DSL 导入导出。当前是静态 `主链确认`，未运行数据源授权、解析器、向量库、reranking 或实际召回，不能推断检索质量、吞吐、费用、删除一致性和权限效果。详见[独特功能](../独特功能/Dify-独特功能调查笔记.md)。

### Prompt IDE 与配置发布

基础 App 的 configuration 页面将 prompt、变量、上下文数据集、外部数据、模型参数和相邻 Debug/发布表面组合为一份可执行应用定义。Debug 可把未发布配置作为覆盖参数送进实际 chat/completion 运行时；多模型模式将同一输入并排发给最多四个不同模型。发布会新建 `AppModelConfig` 并把 App 的 active config 指向它，正式 service API 改由这份 active config 运行。

未找到独立、可恢复的 Prompt 草稿或实验实体：未发布状态仍在前端，模型比较是客户端并排独立调用。调试消息会落库，但生产统计排除 `DEBUGGER` 来源。传统应用的提示词配置与 Agent v2 的版本化 roster 并非统一角色库，详见[独特功能](../独特功能/Dify-独特功能调查笔记.md)和[Agent 角色配置](../Agent角色/Dify-Agent角色配置调查笔记.md)。

### LLMOps：记录、Trace 与人工注解回复

生产 workflow 调用会留下可查询的 `WorkflowAppLog`，但 debug、trigger 和部分 pipeline/validation 调用不写该记录。应用还可配置外部 Trace provider，服务端加密保存配置，将 trace 批量入队并由 worker 投递。更直接影响运行结果的是注解回复：人工修订的问答异步索引后，Advanced Chat 会在图运行前检索，命中时返回人工答案、记录 hit history 并终止后续 Graph。

本轮未找到从日志自动生成注解，或自动调整 prompt、知识库、模型的执行器；外部 Trace 接收和索引质量均未运行。详见[独特功能](../独特功能/Dify-独特功能调查笔记.md)。

### Agent v2 与受管插件生态

Agent v2 将 roster Agent、workflow inline Agent、编辑 draft、build draft 和不可变发布 snapshot 区分建模。会话或 build draft 拥有 execution workspace binding，运行时保存 session snapshot 和待处理表单/工具状态；后续请求校验 binding 的 tenant、owner 和配置 generation，退役后再请求 Agent Runtime 做物理清理。它是版本化 Agent 的执行环境，而不只是新的配置界面。

Plugin Marketplace 则由 Dify 处理权限、来源策略、下载/缓存、异步安装/升级任务、卸载后的关联清理和运行时发现；真正的包安装、记录、隔离与物理删除在独立 Plugin Daemon。两条链都已静态走通 Dify 侧，尚未启动对应外部 runtime。详见[独特功能](../独特功能/Dify-独特功能调查笔记.md)。

### DSL 分发与迁移边界

应用 DSL 把导入导出、推荐应用、Marketplace 模板和应用复制归到同一发布链。导入会进行 YAML/版本校验、十分钟的 tenant/account 绑定确认、依赖检查，并为目标 tenant 清理不能迁移的知识库、触发器和订阅引用；Agent package 也会移除凭据和敏感资源引用。默认导出不含 secret，但同工作区 Copy App 为原子复制而使用含已解密 workflow secret 的受权限保护路径，不能把这两种场景混成同一安全结论。

DSL 不是另一个独立产品运行工作流，故不计入特色贡献；URL 拉取、导入确认、依赖安装和导出文件后续保管都没有运行验证。详见[独特功能](../独特功能/Dify-独特功能调查笔记.md)。

### 外部协作与扩展的现有结论

service API、SDK、插件/MCP/触发器说明 Dify 有多个对外接入点，但它们不能统一称为“外部执行体与应用协作”。业务系统可调用已发布应用；MCP/插件让 Dify 主动调用外部工具；Webhook、schedule 与 Plugin Trigger 已可从外部事件或订阅走到已发布 workflow、触发型 End User、异步 workflow run 和 trigger log。Webhook 的同步响应由节点配置决定，异步 workflow 的最终结果仍留在 Dify 的运行记录中。

普通 MCP tools/list/tools/call、API 或单向 webhook 仍不满足持续身份、双向回流和接管治理的完整准入条件。独立外部 Agent、业务账号 installation、外部读取最终 workflow 输出，以及签名/重试/幂等的实际效果尚未走通。详见[外部执行体与应用协作](../外部执行体与应用协作/Dify-外部执行体与应用协作调查笔记.md)。

## 已确认的结构取舍

- **应用定义和运行实例分离**：发布配置、公开 UI 与单次 conversation/workflow run 分属不同对象，便于同一应用提供多种调用面；代价是不同 mode 的运行语义不能简单统一。
- **统一入口而非统一运行器**：生成服务集中 mode 分派、权限/限流交接与响应协调，真正上下文、记录和执行仍由专属 generator/graph runtime 持有。
- **工作区资源晚绑定**：Provider、模型凭据、工具与外部连接先按 tenant 配置，实际运行再解析需要的引用；这隔离了公开调用者与凭据，但要求按具体应用/节点追踪“本次实际可见什么”。
- **事件型前端投影**：公开 UI 通过 SSE 合并临时状态并以服务端回填/重取收口，支持文本之外的 thought、文件和 workflow 生命周期；断线、乱序、并发与长期性能仍需运行检验。

## 已知边界与未覆盖事项

本汇总只压缩静态调查结论。没有运行 Docker、真实模型、真实 Provider/MCP/插件或浏览器端到端场景，因此不对可靠性、性能、费用、权限效果、外部平台兼容或生产安全作项目级结论。存在测试目录只说明仓库有测试资产，不等于本轮运行过测试。

RAG、Prompt IDE、注解回复、Agent v2 与 Dify 侧插件安装已补入主链；文件存储和引用访问、控制台 workflow 编辑器、触发器交付、外部 Trace 的实际可见性、Plugin Daemon/Agent Runtime 的物理执行和 SDK 具体协议仍未形成完整专项。对话导出与分享已补充专项，但当前只确认管理员留存 JSONL.GZ 命令，未确认终端用户分享主链。没有找到某入口也只能说明本轮调查范围内未确认，不能用作整个项目“不支持”的绝对结论。

## 来源笔记索引

- [Chat](../Chat/Dify-Chat调查笔记.md)
- [会话与消息管理](../会话与消息管理/Dify-会话与消息管理调查笔记.md)
- [对话请求与上下文](../对话请求与上下文/Dify-对话请求与上下文调查笔记.md)
- [Chat UI](../Chat%20UI/Dify-ChatUI调查笔记.md)
- [消息渲染器](../消息渲染器/Dify-消息渲染器调查笔记.md)
- [Agent 工具](../Agent工具/Dify-Agent工具调查笔记.md)
- [LLM 渠道管理](../LLM渠道管理/Dify-LLM渠道管理调查笔记.md)
- [生成式输出与运行时](../生成式输出与运行时/Dify-生成式输出与运行时调查笔记.md)
- [外部执行体与应用协作](../外部执行体与应用协作/Dify-外部执行体与应用协作调查笔记.md)
- [独特功能](../独特功能/Dify-独特功能调查笔记.md)
- [产品结构与设计基因](../产品结构与设计基因/Dify-产品结构与设计基因调查笔记.md)
- [对话导出与分享](../对话导出与分享/Dify-对话导出与分享调查笔记.md)
- [应用界面基础设施](../应用界面基础设施/Dify-应用界面基础设施调查笔记.md)
- [Agent 角色配置](../Agent角色/Dify-Agent角色配置调查笔记.md)

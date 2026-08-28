# Dify 独特功能调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态阅读 README、应用生成器、workflow 图运行时、workflow-as-tool、知识库/RAG Pipeline、Prompt IDE、LLMOps、Agent v2、插件/MCP/触发器入口与 DSL 导入导出；未连接外部服务或运行部署
>
> 调查范围：寻找不能由普通 Chat、工具或 Provider 单独解释的完整产品工作流；补查知识库摄取、检索与 RAG Pipeline、Prompt IDE、LLMOps、Agent v2、Marketplace 生命周期和应用 DSL 可移植性；不把常规流式聊天、单条工具调用或普通模型配置重复计为特色
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

本轮将“可发布的 workflow 应用及其再复用”列为 Dify 的一项 `主链确认` 特色能力：它把图定义、输入校验、运行记录、流/阻塞响应、停止与日志连接为可由终端用户和外部 API 调用的产品单元，并允许一部分 workflow 再以工具 Provider 方式被 Agent 选择。这个能力横跨应用发布、图运行、工具与外部调用，不应只记成“有 workflow 节点”或“支持工具”。

知识库与可发布 RAG Pipeline 也达到静态 `主链确认`：它将文件、Notion 或网页来源转为 tenant 下可管理的知识资产，异步索引后既可被聊天应用和 workflow 检索节点消费，也可通过独立 Pipeline 维护摄取图的草稿、发布和运行记录。它不是普通“上传附件”功能，且现有目录没有能完整承接其摄取、检索和编排链的通用类目。

基础 App 的 Prompt IDE、LLMOps 注解回复、受管插件 Marketplace 和 Agent v2 工作区均已补到静态 `主链确认`。前两者分别把未发布配置送入真实调试运行后发布为正式配置，以及把人工修订回答索引为下一次请求可命中的答案；后二者则分别覆盖租户插件安装治理和 Agent 的版本化执行环境。它们都不是对普通聊天、单个工具调用或模型渠道的重复描述。

Trigger Provider 仍只有 `入口确认`，因为外部事件已能启动异步 workflow，却尚未确认最终用户结果和投递保证；MCP 作为工具调用能力仍归并到相邻专项。Marketplace 和 Agent v2 虽已形成 Dify 侧主链，其 Plugin Daemon、Dify Agent Runtime 等外部执行域仍未运行验证。

## 介绍声明与候选盘点

README 将 LLM application、agentic workflow 和 RAG pipeline 并列为平台核心能力，并另列 Prompt IDE、LLMOps 和 Backend-as-a-Service。按本类目准入条件，本轮已调查可发布 workflow 应用与 workflow-as-tool、知识库/RAG Pipeline、基础 App Prompt IDE、LLMOps 注解回复、Agent v2 工作区和 Marketplace 安装生命周期；触发器仍保留待补边界。

普通 Chat、Agent Chat、模型 Provider 与单个工具不进入本篇：它们已有对应通用类目，或尚未组成与其他项目不可替代的独立产品工作流。知识库不再按“已有类目”排除：现有笔记目录没有 RAG/数据集专项，且 RAG Pipeline 的对象和生命周期不能由对话上下文或单个工具笔记完整解释。workflow-as-tool 与可发布 workflow 共享同一用户目标和运行对象，因此合并为一张能力卡，而不把“可执行 workflow”和“workflow 被调用”拆成两项贡献。

| 候选能力 | 证据状态 | 本轮处理 | 原因 |
| --- | --- | --- | --- |
| 可发布 workflow 应用及 workflow-as-tool | `主链确认`（静态） | 纳入一项特色能力 | 已确认应用/API 输入到图运行、run/event/stop，以及受限 workflow 的工具化路径 |
| 知识库与可发布 RAG Pipeline | `主链确认`（静态） | 纳入一项特色能力 | 已确认数据源到异步索引、应用/节点检索消费，以及 Pipeline 草稿、发布、试跑和运行记录 |
| 基础 App Prompt IDE | `主链确认`（静态） | 纳入一项特色能力 | 配置可进入真实 debug、多模型并排比较，发布后切换正式 active config |
| LLMOps 注解回复 | `主链确认`（静态） | 纳入一项特色能力 | 人工修订被异步索引，命中后在应用运行时短路为回答并记录命中 |
| Agent v2 工作区 | `主链确认`（静态） | 纳入一项特色能力 | roster/草稿/发布快照与 workspace binding、会话快照、人工输入续接和退役链已连通 |
| 插件 Marketplace 与受管安装 | `主链确认`（静态，Dify 侧） | 纳入一项特色能力 | 发现、策略、安装任务、升级、卸载、缓存失效与运行时发现已连通；daemon 是外部执行域 |
| 应用/Agent DSL 导入导出 | `归并已有类目` | 作为发布链支撑 | 迁移、模板、复制与依赖检查复用同一导入链，不形成新的独立运行工作流 |
| MCP 扩展 | `归并已有类目` | 回链 Agent 工具 | 主要事实已由工具 Provider、发现、凭据和调用边界解释 |
| Webhook、schedule 与 Plugin Trigger 工作流 | `入口确认` | 暂不计入 | 外部事件可校验、映射至已发布 workflow，并创建异步 run 与 trigger log；最终用户结果、签名与投递保证未确认 |

## 已确认的独特能力

### 可发布的 workflow 应用与二次编排

**标签：协同工作流、外部应用调用、Agent 工具。证据状态：`主链确认`（静态）。**

**用户目标与事实对象。** Dify 的目标不只是让用户在聊天中看见一段模型回答，而是把带输入字段、节点图和运行记录的 workflow 发布成应用能力。核心对象至少包括 application/workflow definition、单次 workflow run、node execution 和面向调用者的 task/event；当 workflow 被工具化时，还会多出 tenant 下的 workflow tool provider 配置。这些对象让同一图可作为服务 API 的调用目标，也可在受限条件下成为另一个 Agent 的可发现能力。

**完整主链。** 外部程序调用 workflow API 或已发布应用提交 inputs/files 后，`AppGenerateService` 按 `AppMode.WORKFLOW` 或 advanced chat 分派给 workflow generator。生成器以 `WorkflowAppConfigManager` 取得并转换应用配置，验证输入和文件，创建运行 repository 后交给 graph engine。执行产生 workflow run、节点生命周期、文本 chunk、人工输入或完成事件；streaming 调用由 `MessageBasedAppGenerator.retrieve_events` 回收并转换为事件流，blocking 调用则走相应的最终响应转换。service API 还提供以 task ID 停止 streaming workflow 的路径。这条“调用 -> 运行对象 -> 图执行 -> 可消费事件/结果 -> 停止或日志”的主链足以确认其为可独立交付的运行单元，而非仅存在编辑画布。

**再复用与边界。** `api/core/tools/workflow_as_tool/` 与 `WorkflowToolsManageService` 会把符合条件的 workflow 保存为某 tenant 的工具 Provider，并在创建/更新时检查兼容性；已有实现明确排除含 human-input 节点的 workflow。这个限制很关键：workflow-as-tool 不是任意图的无条件嵌套，也不证明被调用图的人工暂停、访问控制和错误语义可自动传给 Agent。工具目录、schema 注入和 Agent 循环见[Agent 工具](../Agent工具/Dify-Agent工具调查笔记.md)。

**持续性、控制与执行域。** workflow 定义和工具 Provider 是服务端持久化配置；每次调用的 run/节点事件由后端运行时与 repository 承接，公开 WebChat 仅订阅/投影事件。停止 API 同时保留旧 queue stop flag 和 GraphEngineManager 命令通道，表明实现有兼容层，但本轮未运行，不能确认停止是否到达所有节点、插件 HTTP 调用或异步 worker。执行发生在 Dify 服务端和其配置的模型/工具连接中，不在终端用户浏览器中执行图。

**为什么属于独特功能。** 单看 workflow，是生成式输出/运行时；单看 API，是外部应用调用；单看 workflow-as-tool，是 Agent 工具。Dify 将这些对象安排为同一发布单元，并让其既可对人类/业务系统交付、又可有限地重新进入 Agent 目录，才形成完整产品语义。与普通“聊天里触发一个工具”相比，它拥有明确图定义、运行记录、发布调用面和二次复用方向。

**证据强度与未验证。** 已静态走通主要调用、对象、事件与停止入口。未创建 workflow、未调用 API、未运行图，也未验证 workflow 编辑发布、运行日志保留、并发、版本迁移、节点失败、重试、人工输入和跨租户隔离的实际表现。

### 知识库与可发布 RAG Pipeline

**标签：知识资产、可配置摄取、RAG 编排。证据状态：`主链确认`（静态）。**

**用户目标与事实对象。** Dify 把知识库作为 tenant 下可持续维护的 Dataset，而不是一次请求附带的文件。Dataset 关联 Document、分段、处理规则、索引状态与检索设置；其来源可为上传文件、Notion 页面或网页抓取。RAG Pipeline 则在 Dataset 之上维护独立的 pipeline、草稿/已发布 workflow、节点执行与 workflow run，使作者可以把数据源处理和检索配置作为可编辑、可回看的图，而不是只接受默认切块与向量化。

**摄取、索引与恢复链。** 控制台数据集页面提供新建、来源、文档、命中测试、设置、访问控制和 Pipeline 路由。提交来源后，`DatasetService` 在事务中写入 Document 及其来源信息，再把新文档交给 `DocumentIndexingTaskProxy`；后台任务负责索引，并在分段可用后继续生成摘要索引。文档状态操作会在提交后再投递索引或删除任务，并以 Redis 锁/短期索引标记防止并发修改。这确认了“作者选择来源 -> Dataset/Document 持久化 -> 异步索引 -> 可管理的完成或失败状态”的服务端主链，但没有运行实际解析器、向量数据库或失败恢复。

**检索如何进入应用运行。** 已发布 chat/completion 应用的 runner 会由 `DatasetRetrieval` 按应用的 retrieval resource 取得上下文和引用文件；workflow 的 Knowledge Retrieval 节点则从变量池读取 query 或附件，调用同一检索服务，将排序后的 Source 列表作为 `result` 输出，并把 token/价格写入节点元数据。检索并非无条件拼接：节点可选择单数据集或多数据集策略，并带 metadata filter、重排序或关键词/向量权重等配置。这样，知识资产既可服务传统应用配置，也能成为图中下一节点可消费的明确输出。

**RAG Pipeline 的编排和持续性。** 数据集路由另有 create-from-pipeline、Pipeline 编辑和节点试跑表面；后端为每个 Pipeline 读取或同步 draft workflow、发布 workflow、执行数据源或草稿节点，并保存 run 与 node execution 供后续读取。Pipeline DSL 还提供导入导出接口。这一链将摄取规则和检索资产从“应用配置中的一个引用”提升为带草稿、发布、试跑和运行历史的对象，因此应和普通对话上下文、文件上传或单次检索区分。

**边界与证据强度。** 本轮静态确认了文件、Notion 与网页三个来源分支，但未接入任何外部授权、爬虫、解析器、向量库或 reranking 模型；不能据此判断实际解析质量、召回、费用、吞吐、删除一致性、权限效果或索引重试。外部知识库连接、服务 API 的数据集 CRUD、具体访问控制与命中测试 UI 也尚未走通。RAG Pipeline 是否应在未来形成独立稀疏类目，取决于是否在至少两个项目中确认同样的“可发布摄取图 + 知识资产生命周期”产品语义；目前保留为 Dify 的能力卡。

### 基础 App Prompt IDE：编排、真运行、比较与发布

**标签：上下文语言、应用编排、模型比较。证据状态：`主链确认`（静态）。**

**用户目标与事实对象。** 对基础 Chatbot/文本生成应用，Prompt IDE 让作者在同一控制台编辑提示词、变量、上下文数据集、外部数据、模型参数和部分多媒体/文件功能，并立即查看这些配置实际运行后的回答。这里的事实对象是编辑中的配置与已发布的 `AppModelConfig`；后者保存 prompt 类型、simple/advanced prompt、变量、数据集和功能设置，应用本身只持有当前 active config 指针。它因此不同于“给模型填一段 system prompt”，但也不等同于有完整实验管理系统。

**编辑到真实调试。** configuration 页面将配置编辑器、Debug 和发布控制放在一个应用工作面；advanced prompt 编辑器还可插入变量、history/query、context dataset 与外部数据等块。单模型调试把当前未发布的完整配置作为覆盖参数发送到 chat 或 completion 运行入口，服务端只对 `DEBUGGER` 调用接受该覆盖配置，随后照常转换为 AppConfig、组织 prompt/上下文并调用模型。因而页面右侧不是 mock preview，编辑中的内容会进入真实运行时，但本轮没有接入任何模型。

**比较、记录和发布。** 多模型面把同一输入广播给各个 Debug Item，最多四个并排；每栏带相同应用配置、但可选择不同 model/provider/参数。运行会创建 Conversation/Message，并记录 `DEBUGGER` 来源和 override config。作者发布时，控制台验证 payload、新增一条 `AppModelConfig` 并把应用 active 指针切到它；正式 service API 不接收该调试覆盖，改从当前 active config 生成。这形成“编排 -> 带覆盖运行 -> 横向比较 -> 正式交付”的闭环。

**边界与独特性。** 未找到独立、可恢复的 Prompt draft/version 实体：未发布配置保留在前端状态，重置只回到当前 published config；每次发布会产生新配置行，却未在本轮证实版本浏览或回滚。多模型比较也是客户端发起的独立请求，选择配置只写 localStorage，未找到持久化实验、统一评分或自动评测。调试消息会落库，但统计接口会排除 `DEBUGGER`，不能把它称作完整生产指标。其特色在于同一应用定义同时是可编辑上下文、可执行调试输入和可发布 runtime 配置，而不是单独的 textarea、模型选择器或聊天页。

### LLMOps：运行记录、外部 Trace 与人工注解回复

**标签：可观测性、人工反馈、运行时回流。证据状态：`主链确认`（静态）。**

**可检索的生产记录。** 非调试的 service/openapi/installed/web app workflow 调用收尾时会创建 `WorkflowAppLog`，关联 workflow run、调用来源和创建者；控制台按应用、时间、状态、关键字和用户分页查询，并可取得关联 run 的输入/输出。debug、trigger、published pipeline 与 validation 并不写这张表，故不能称其覆盖所有执行。应用 overview 还允许有权限的成员配置 Arize、Phoenix、LangSmith、Langfuse 等追踪 provider；后端验证并加密保存配置，运行时把 trace 批量落对象存储并交 Celery 投递给 provider。

**人工修订如何影响下一次回答。** 控制台允许从 message 创建注解，或直接新增/编辑/删除/批量导入问答；注解设置保存匹配阈值与 annotation collection。提交后服务端异步把 question 和 annotation ID 写到向量集合。Advanced Chat workflow 在初始化图之前读取已启用设置，以 top-1 和阈值检索；命中时会记录 hit history、发出 annotation event、流式返回人工答案并以 `ANNOTATION_REPLY` 收口，后续 Graph 不再执行。Easy UI 管线也会将该内容覆盖到保存消息。因此“人工修订 -> 索引 -> 后续请求直接回复 -> 命中记录”在本仓库内是一条完整静态主链。

**边界与独特性。** README 所称“根据生产数据与 annotations 持续改 prompts/datasets/models”在本轮只确证了人工可利用的数据和注解回复；未找到从日志审阅自动生成注解，或自动修改 prompt、知识库、模型的执行器。外部 Trace 的接收可见性、provider 数据完整性、保留、RBAC 效果、投递重试后的最终结果和索引失败修复均未运行。独特性不在于“有日志”，而在于同一应用可把人工批准的回答治理成带命中历史的运行时短路答案。

### Agent v2：版本化 roster 与可恢复执行工作区

**标签：Agent 工作区、活对象、版本化执行。证据状态：`主链确认`（静态）。**

**对象与编排。** Agent v2 将可复用 roster Agent、仅属于 workflow 的 inline Agent、普通编辑 draft、每位编辑者的 build draft 与不可变 config snapshot 区分建模。控制台支持 roster、配置、预览、版本、访问、日志与监控入口；发布把可编辑 Agent Soul 转为 snapshot/revision，已存在版本也可回写为新的正常 draft。这样同一 Agent 可被工作流引用，同时区分尚未发布的编辑态和运行所绑定的版本。

**运行、续接与清理。** Agent App 生成器在新会话为当前 generation 建立 binding，已有会话则按 binding 固定到原有 immutable generation。`AgentAppWorkspaceStore` 以 conversation 或 build draft 为 workspace owner，在 Dify Agent backend 创建 execution binding，并把 binding ID 回写到调用者；后续调用会校验 tenant、owner、Agent、home snapshot 和配置版本一致性。运行中保存 compositor session snapshot、pending form/tool ID；human-input 表单提交后由后台恢复回合并把答案持久化，断线的实时流不在恢复范围。binding/workspace 先标记 retired，提交后再请求 backend 物理清理，失败留待后续收集。这证实它已不只是“新版 Agent 配置 UI”。

**边界与独特性。** 本轮没有启动独立的 Dify Agent Runtime，因此 workspace/binding 的物理创建、session 的实际恢复、工具环境和销毁幂等性仍是静态结论；服务端注释也明确承认跨系统创建成功后事务失败可能留下孤儿资源。其产品语义是“版本化 Agent 配置 + 会话/调试草稿拥有的可回收执行环境”，而不是传统 Agent 节点的单次模型工具循环。

### 插件 Marketplace 与受管安装生命周期

**标签：生态治理、受管扩展、租户隔离。证据状态：`主链确认`（静态，Dify 侧）。**

**从目录到安装任务。** Marketplace 页面从配置的外部目录读取候选，失败时前端仅显示空结果；用户安装或升级时调用 Dify Console API。该 API 先经过登录、租户与 `PLUGIN_INSTALL` 权限检查，按官方/合作伙伴/全部来源策略处理 identifier；服务端优先询问 Plugin Daemon 是否已有缓存 manifest，未命中才从 Marketplace 下载 `.difypkg` 并上传 daemon。随后它把 identifier 交给 daemon 的安装管理接口，前端以五秒间隔轮询 pending/running/success/failed 任务，完成后刷新已安装插件。

**更新、卸载和运行时发现。** 已安装插件对象含 tenant、安装来源、包标识、版本、checksum、manifest 和 installation ID。Marketplace 来源可经定时任务检查全局 manifest 后按租户发起自动升级；新租户默认插件也复用异步安装服务。卸载先由 daemon 处理，成功后 Dify 才清理该插件命名空间的模型偏好、凭据和关联，并失效缓存；替换路径可保留凭据。ToolManager 随后能从 daemon 查询该租户已安装的 tool provider，插件工具把凭据、参数和上下文流式派发到 daemon，因此安装结果会成为应用运行时可发现的能力，而非只停在商城 UI。

**执行域与边界。** 包解压、安装记录、任务执行、依赖/进程隔离及物理删除由独立 `dify-plugin-daemon` 镜像、数据库和存储卷持有，Dify 源码只能确认管理协议和清理交接；尚未运行验证任务重试、失败清理、升级时版本并存、卸载彻底性或跨类别插件的回收。Compose 默认要求 daemon 强制验签，但信任根和验签实现也属于镜像边界。外部目录、下载 URL、全局 manifest 与安装统计不在本仓库保证范围，因此不对 SLA、审计、包可得性或统计送达作结论。

## 已归并到现有类目的能力

### 工具、MCP 与插件生态

内置/API/插件/MCP/workflow 五类工具来源，以及 MCP 的远端调用、加密 header 与 OAuth 交接，属于“模型可发现和调用能力”的通用问题，已由[Agent 工具](../Agent工具/Dify-Agent工具调查笔记.md)承接。本篇 Marketplace 卡只记录插件从发现到受管安装、清理和运行时发现的生态治理，不重复描述各工具的模型调用语义。插件或 MCP 的存在也不能单独证明持续的外部应用协作：账号 installation、资源映射、双向事件与治理链仍需在[外部执行体与应用协作](../外部执行体与应用协作/Dify-外部执行体与应用协作调查笔记.md)继续确认。

### 应用与 Agent DSL 的可移植性

应用 DSL 是可发布 workflow、RAG Pipeline、Prompt IDE、Marketplace 模板和推荐应用共用的包装与迁移机制，而不是另一种可独立交付的运行单元。Console import 先校验 YAML 内容或 URL、10MB 限制和 DSL 版本，再创建目标工作区 App 或覆盖 workflow/advanced-chat 草稿；版本过新或 major 不兼容时，把绑定 tenant/account 的内容暂存 Redis 十分钟，等待确认。推荐应用和 Marketplace 模板都取得不含 secret 的 export data，再复用这条导入链；导入后还会报告缺失插件依赖。

默认导出不携带 secret：workflow 环境变量留空、工具/Agent credential reference 被移除，Agent package 还会置空 credential、secret、password、token、file ID 和联系人等敏感/源工作区字段。知识库 ID 在跨租户不可解密时被过滤，触发器的 schedule/webhook/debug URL 和 plugin subscription ID 也会重置；运行时再按目标 tenant 限定检索。相反，同工作区 Copy App 为保持原子复制而显式 `include_secret=true`，会将已解密的 workflow secret 交给同权限路径导入。因此它不能被笼统描述为“安全导出”，也不能把同工作区复制等同于可分享的跨环境迁移。具体导入/导出和密钥边界见 `api/services/app_dsl_service.py:111-1057`、`api/models/workflow.py:594-708`、`api/services/agent/dsl_service.py:192-664`。

### 发布后的 WebChat、流式消息与人工输入展示

公开 Chat、Chatbot、嵌入式组件、SSE、引用、Agent thought 和 workflow 暂停表单分别进入 Chat、Chat UI、请求、消息渲染器专项。它们对 workflow 应用的重要性在于提供调用与观察表面，但本身是可横向比较的通用运行界面，不重复计入特色。

## 入口确认、外部依赖与暂缓项

### Webhook、schedule 与 Plugin Trigger 工作流

Webhook 已发布入口会加载 webhook trigger、发布 workflow 和节点配置，校验请求数据后投递执行；plugin trigger 则从订阅事件找到已发布 workflow、创建触发型 End User、保留配额，再调用异步 workflow service。两条路径都会以 workflow run 和 `WorkflowTriggerLog` 保存关联、队列与完成/失败状态；schedule 是同一异步运行面的另一种事件来源（`api/controllers/trigger/webhook.py`、`api/tasks/trigger_processing_tasks.py`、`api/models/trigger.py`）。这确认了“外部事件 -> 服务端状态 -> 图运行 -> 记录”的入口和执行链，但尚不足以确认用户最终得到的结果。

这项能力的产品语义是把图定义作为被动 API 之外的事件驱动自动化单元。webhook 的同步响应由节点配置决定，不能代表异步 workflow 的最终输出；签名、OAuth、重试、幂等、外部结果回传和人工接管未运行验证。因此暂不进入特色统计，也不应被描述为已确认的双向外部执行体平台。

## 对特色贡献统计的影响

本轮建议为 Dify 记入六项主贡献：**可发布 workflow 应用及有限 workflow-as-tool 再复用**、**知识库与可发布 RAG Pipeline**、**基础 App Prompt IDE**、**LLMOps 注解回复**、**Agent v2 版本化工作区**和**插件 Marketplace 的受管安装生命周期**；均为静态 `主链确认`，其中 Marketplace 只覆盖 Dify 侧。Trigger Provider 仍不计数；MCP 与普通 Chat 均归并既有类目。该计数表达的是已贯通的用户工作流数，不是模块数、节点数或产品成熟度评分。

## 未验证事项

- 未运行 Docker、真实模型、插件、MCP server 或 webhook，外部依赖只确认了代码入口。
- 未验证 workflow 发布版本与草稿、权限、日志留存、恢复、取消、超时、并发和重试。
- 未运行 Dataset 的文件/Notion/网页摄取、索引任务、向量库、reranking、命中测试或删除恢复；外部知识库和服务 API 的数据集表面尚未逐路径确认。
- 未运行 RAG Pipeline 的草稿保存、节点试跑、发布、DSL 导入导出、历史回看和数据源授权；不对解析质量、召回、费用或吞吐作结论。
- 未运行 Prompt IDE 的真实模型、各 Provider/TTS/STT/知识能力、发布授权、多人协作冲突、版本恢复或调试会话的保留；多模型比较与生产评测的关系也未确认。
- 未运行注解的向量检索、索引失败恢复、阈值效果、实际命中/回退，以及外部 Trace 的投递、保留、provider 可见性和成本；未找到自动调优执行器。
- 未启动 Dify Agent Runtime 或 Plugin Daemon，因而未确认 Agent v2 的实际 workspace/session/工具/HITL 生命周期，也未确认插件安装任务、包验签、隔离、升级、失败清理和卸载的物理效果。
- 未运行 DSL 的 URL 拉取、版本确认、依赖检查、跨工作区导入或同工作区 secret copy；缺失数据集被静默过滤、依赖是否自动安装和导出文件的二次保管仍需运行与部署边界验证。
- 未确认 Trigger Provider 的签名/OAuth、投递保证、最终结果回传和用户可见控制表面。

## 关键源码索引

- `api/services/app_generate_service.py:88-318`：应用模式分派、workflow/advanced chat 事件回收。
- `api/core/app/apps/workflow/app_generator.py`、`api/core/app/apps/advanced_chat/`：应用输入、运行 repository 与图执行交接。
- `api/core/app/apps/message_based_app_generator.py`、`api/core/app/entities/task_entities.py`：workflow 事件与消息型应用的转换契约。
- `api/core/workflow/`、`api/core/workflow/graph_engine_manager.py`：图执行和停止命令边界。
- `api/core/tools/workflow_as_tool/`、`api/services/tools/workflow_tools_manage_service.py`：workflow 作为工具的配置与兼容性检查。
- `api/services/dataset_service.py:2326-2505`、`api/tasks/document_indexing_task.py`：知识来源持久化、索引任务投递和异步索引边界。
- `api/core/rag/retrieval/dataset_retrieval.py:378-470`、`api/core/workflow/nodes/knowledge_retrieval/knowledge_retrieval_node.py:101-301`：应用与 workflow 的检索消费、节点输出和用量元数据。
- `web/app/(commonLayout)/datasets/`、`api/controllers/console/datasets/rag_pipeline/rag_pipeline_workflow.py`：数据集/RAG Pipeline 的控制台路由、草稿/发布、节点试跑和运行记录接口。
- `web/app/components/app/configuration-view/`、`api/controllers/console/app/model_config.py:77-220`、`api/core/app/apps/chat/app_generator.py:115-168`：Prompt IDE 的编辑、debug 覆盖和 active config 发布。
- `api/services/annotation_service.py:144-358`、`api/tasks/annotation/`、`api/core/app/features/annotation_reply/annotation_reply.py:18-96`、`api/core/app/apps/advanced_chat/app_runner.py:180-350`：人工注解索引、检索命中与运行时短路回复。
- `api/controllers/console/app/workflow_app_log.py:170-247`、`api/core/ops/ops_trace_manager.py:505-558,1512-1616`、`api/tasks/ops_trace_task.py:41-141`：workflow log 与外部 Trace 配置、队列和投递。
- `web/features/agent-v2/`、`api/services/agent/composer_service.py:523-1016`、`api/core/app/apps/agent_app/session_store.py`、`api/services/agent/workspace_service.py`：Agent v2 的 roster/draft/snapshot 与 workspace session 生命周期。
- `api/controllers/console/workspace/plugin.py:858,1061`、`api/core/plugin/plugin_service.py:658,1197,1246`、`api/core/plugin/impl/plugin.py:157`：Marketplace 策略、安装/卸载及 daemon 异步任务交接。
- `api/controllers/console/app/app_import.py:74-196`、`api/services/app_dsl_service.py:111-1057`、`api/models/workflow.py:594-708`、`api/services/agent/dsl_service.py:192-664`：DSL 导入导出、版本/依赖、跨租户清理与 Agent 包脱敏。
- `api/core/trigger/`：触发器候选的订阅、验证与日志入口。

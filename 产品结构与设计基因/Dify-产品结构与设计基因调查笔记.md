# Dify 产品结构与设计基因调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态核对 README、顶层目录、Web 路由、API 服务边界、现有 Dify 专项笔记与浅克隆可见提交；未运行服务、插件运行时或 Agent Runtime
>
> 调查范围：当前产品表面、调用者、能力组织单位和跨模块模式；历史只限本地浅克隆可见范围，不把当前结构倒推为完整演变史
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 是让应用作者在租户工作区定义、调试和发布 LLM 应用的平台，不是以个人对话为中心的通用客户端。其控制台将 Chatbot、Agent Chat、文本生成、工作流、RAG Pipeline 与 Agent v2 的编辑面组织为不同的配置或图定义；发布后的 WebChat、Chatbot、嵌入组件、service API 与触发器再消费这些定义。最终用户看到的聊天页因此是已发布应用的调用表面，而不是模型、工具和知识库的配置中心。

当前最稳定的组织骨架是“租户下的可发布定义 -> 按应用模式选择运行器 -> 可寻址的消息或 workflow run”。模型、凭据、插件、工具和数据集均以租户资源方式接入定义；插件和 Agent v2 runtime 又把一部分执行责任移交给独立进程。这个模式解释了 API、嵌入页、公开聊天和异步触发器为何可复用同一应用，但不能据此推断每一种模式都有相同的会话、停止或结果语义。

## 证据口径与产品演变

README 将 Dify 定位为开源 LLM 应用开发平台，并把 Workflow、模型接入、Prompt IDE、RAG Pipeline、Agent、LLMOps 和 Backend-as-a-Service 并列为核心功能（`README.md` 的 “Key features”）。这是当前作者自述；控制台路由、API 应用模式分派和发布后 Web 入口共同构成当前结构确认。

本地仓库是浅克隆，`git log --reverse` 无法提供项目早期提交和主要阶段的可靠时间线。因此本篇只记录当前结构，不能声称某个产品表面先于另一个出现。Agent v2、RAG Pipeline 与 Plugin Daemon 的独立目录或服务边界仅可证明它们在当前快照中是独立能力域，不是其历史加入顺序。

## 与 VCP 早期中间层形态的结构相似

**跨项目归纳，不涉及来源关系。** Dify 的 Backend-as-a-Service 和 service API 形成“外部调用面 -> 平台统一执行层 -> 模型、工具和数据资源”的服务端汇聚方式；VCP 的白皮书则将 V2 概括为部署在“AI 模型 API 与前端应用之间的中间层服务器”。两者都把凭据、模型接入、上下文或工具能力置于调用方之后的统一服务层，使多个前端或业务调用者无需分别直连模型。

它们的职责并不相同：Dify 的 API 先以应用 token 定位已发布的应用定义，再由 `AppGenerateService.generate` 按 App mode 运行 chat、workflow 等专属运行器；调用者消费的是受租户和应用边界约束的结果。VCPToolBox 的早期核心则由单一 `API_URL + API_Key` 接收兼容请求，在转发前后插入上下文、插件、RAG、协议转换和模型路由，更接近请求路径上的增强中间件。

本次讨论补充确认 VCP 的真实前身独立于 Dify；现有 VCPToolBox 仓库、白皮书和可见提交中也未找到 Dify 的署名引用、代码复用或设计说明。因此这里只记录二者在网关中间件思路上的相似与独立收敛，不延伸为产品来源关系。

## 当前产品边界与入口地图

| 调用者或入口 | 主要对象 | 作用与边界 |
|---|---|---|
| 应用作者的 Console | App、AppModelConfig、workflow、dataset、Agent v2 draft/revision | 创建、调试、发布和治理定义；不直接代表终端用户的运行界面 |
| 终端用户 WebChat、Chatbot、嵌入组件 | 发布应用、End User、Conversation、Message | 提交变量和文件、接收事件与答案；模型、工具和知识配置由作者预设 |
| 业务系统 service API / SDK | 已发布 App、workflow run 或消息型调用 | 以应用 token 调用同一运行配置；调用 API 不等于可编辑定义 |
| 外部事件 | 发布 workflow、trigger log、workflow run | Webhook、schedule、Plugin Trigger 可发起异步图运行；最终交付、签名与重试未运行验证 |
| Agent / 模型 | Tool Provider、tool、workflow-as-tool | 工具和兼容的工作流可被模型发现并调用；审批、daemon 和 MCP 的执行细节见工具专项 |
| 独立运行时 | Plugin Daemon、Dify Agent Runtime | 分别承接插件安装/调用和 Agent v2 workspace；主仓库只确认交接协议与清理意图 |

这张地图的内部服务主要是模型管理、应用生成、工作流、数据集、权限和存储服务。它们没有独立终端用户表面，不能同公开 WebChat 并列成“产品入口”。对话导出与分享目前也不是已确认的终端用户表面，详见对应专项。

## 能力组织骨架

应用模式是 Dify 将多种表面收敛到同一产品框架的第一层。`api/services/app_generate_service.py` 按应用模式把调用交给 chat、advanced chat、workflow、Agent 或 completion 的生成器；`api/core/app/apps/` 再负责各自的输入、事件和收尾。应用作者发布或切换 active config 后，公开页面和 service API 都通过该模式取得运行配置。详情见[Chat](../Chat/Dify-Chat调查笔记.md)与[对话请求与上下文](../对话请求与上下文/Dify-对话请求与上下文调查笔记.md)。

第二层是资源所有权。应用、模型凭据、插件安装、工具、数据集、workflow 与 Agent v2 配置均带 tenant/workspace 边界；公开请求不提交原始 Provider 凭据，而由服务端按租户解析并交给 Plugin Daemon。这使“发布”成为从作者配置到受限调用面的转换，不是把整个工作区暴露给访客。

## 已确认的设计基因

### 可发布定义与多调用面

**模式和证据：当前结构确认。** Dify 将应用配置、workflow 或 Agent 版本作为可发布的作者资产，再允许 Web、嵌入、API 和部分事件入口消费。普通 Chat、advanced chat 与 workflow 虽共享“发布应用”的入口概念，但分别产生消息链或图运行对象。`api/services/app_generate_service.py` 与 `api/core/app/apps/` 是模式分派和专属运行器的主要交接处。

**产品作用。** 作者可在一个定义上设置模型、提示词、工具、知识和表单，再向不同调用者交付；终端用户的可操作范围则被收缩为已发布输入契约。例外是控制台调试调用可带未发布覆盖配置，不能把调试面当作生产 API 的权限模型。

### 图运行与消息运行并存

**模式和证据：当前结构确认。** 工作流具有独立 workflow run、node execution、变量与事件流，消息型应用则以 conversation/message 和父消息链组织历史。advanced chat 会把这两层连接起来，但不会抹平对象差异；`api/core/workflow/`、`api/core/app/apps/message_based_app_generator.py` 和 workflow app generator 分别保留运行记录与消息投影。

**产品作用和张力。** 这使图运行可被 API、日志、节点详情和归档消费，也让工作流输出能够回到聊天。它不意味着所有工作流天然拥有线性历史、同样的重新生成语义或可编辑 Artifact；这些能力必须按应用模式确认。

### 受管扩展与执行域外移

**模式和证据：当前结构确认。** Plugin Marketplace 在 Dify 服务端完成租户权限、来源策略、安装任务跟踪、配置清理和工具发现，而插件包安装和实际执行交给 Plugin Daemon。Agent v2 同样把会话工作区交给独立 Agent Runtime，再由 API 保存 binding、版本和清理状态（`api/core/plugin/`、`api/services/agent/workspace_service.py`）。

**产品作用和边界。** 这让平台可统一治理扩展的身份、配置和运行时可见性，却把依赖隔离、物理删除、网络行为和实际执行成功交给外部运行域。未启动两个 runtime，不能将这条静态链写成已验证的隔离、恢复或清理效果。

## 张力、例外与覆盖缺口

基础 Chatbot 的 prompt 是 AppModelConfig 中的一部分，传统 Agent Chat 则还包含 agent mode 与工具配置；Agent v2 才有可复用 roster、草稿与不可变 revision。因此“应用定义”是统一的发布骨架，但不是单一、完全同构的角色或运行配置模型。

RAG Pipeline 与数据集是长期维护的知识资产，workflow run 是一次执行记录，消息则是会话投影。这些对象都可在控制台被查看，却不能互相替代为一个泛化的“项目文件”或“工作区”。对话导出、分享、角色配置与界面基础设施的专项覆盖已补齐；媒体创作未建立 Dify 专项，因为本轮只确认到附件和可由工具/插件提供的媒体调用，未找到媒体工作站所需的任务历史、资产身份和继续创作闭环。

## 与专项笔记的交接

- 发布后聊天、会话、上下文与渲染：[Chat](../Chat/Dify-Chat调查笔记.md)、[会话与消息管理](../会话与消息管理/Dify-会话与消息管理调查笔记.md)、[对话请求与上下文](../对话请求与上下文/Dify-对话请求与上下文调查笔记.md)。
- 应用 Prompt 与 Agent 角色边界：[Agent 角色配置](../Agent角色/Dify-Agent角色配置调查笔记.md)。
- Plugin、RAG Pipeline、Agent v2、LLMOps 与 DSL：[独特功能](../独特功能/Dify-独特功能调查笔记.md)。
- 公开应用与外部系统的调用边界：[外部执行体与应用协作](../外部执行体与应用协作/Dify-外部执行体与应用协作调查笔记.md)。

## 未验证事项

- 完整的产品演变、各表面首次加入时间和已废弃路线，受本地浅克隆历史限制未确认。
- Cloud、Enterprise 与自托管版本的功能差异、权限和运营表面未运行核对。
- Plugin Daemon、Agent Runtime、模型 Provider、外部触发器与第三方系统的端到端行为未运行验证。

## 关键依据

- `README.md`：当前产品定位与核心功能作者自述。
- `web/app/(commonLayout)/`、`web/app/(shareLayout)/`：控制台与公开应用的路由分层。
- `api/services/app_generate_service.py`、`api/core/app/apps/`：应用模式分派及专属生成器。
- `api/core/workflow/`：图运行、节点记录和事件边界。
- `api/core/plugin/`、`api/services/agent/workspace_service.py`：独立 Plugin/Agent runtime 的管理交接。
- [VCP 全景技术白皮书](../../VCPToolBox/docs/vcp白皮书V3.md)、[VCP 初期上游配置](../../VCPToolBox/config.env.example)、[VCP 请求入口](../../VCPToolBox/server.js)：VCP 中间层定位及单上游请求链的跨项目对照依据。

# Dify 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`e568478f8f2b95efc189b698c2f4386a7dbe1c3e`（分支：`main`）
>
> 调查方式：静态阅读 service API、App Deployment 环境与文件 grant、Web API、SDK 目录、MCP/插件工具与触发器管理代码；核对 webhook、schedule、plugin trigger 的日志、认证、幂等、重试和结果边界；未连接外部服务
>
> 调查范围：外部调用应用、App Deployment 环境、平台调用外部能力与外部事件触发；按本类目准入门槛判断是否存在持续外部协作，不把单向 API、部署入口、普通 MCP 或 webhook 误列为主链；不审计第三方协议端实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 有四种对外接入边界：业务系统经 service API 调用已发布应用；App Deployment 环境运行选定版本；运行中的 Agent/workflow 经工具、插件或 MCP 调用外部能力；外部事件经 webhook、schedule 或 plugin trigger 创建异步 workflow run。它们都提供了可调查的协议与运行入口，但按本类目要求，当前代码快照中尚未确认拥有持续身份、双向回流、状态映射和接管治理的外部协作主链。不能把“支持 MCP”、部署到环境或“能被 webhook 触发”泛化为外部执行体协作。快照中新增的 IM 人机协同通道与 KnowledgeFS 外部知识服务分别补齐了“外部渠道回传”和“协议外置依赖”两种形态，但都仍是 Dify 单方持有运行状态。

## 1. 外部调用已发布应用

service API 按应用能力提供 workflow、conversation、message、file 与 site 路由；公开 Web API 也有 workflow run/stop 入口。`/files/upload`、`/site`、`/workflows/run` 等接口共同构成应用调用面的配套资源（`controllers/service_api/app/{file,site,workflow}.py`）。workflow 运行可选择 blocking 或 SSE streaming，run/task ID 继续用于详情和停止。

这些路由先验证应用 token 并解析终端用户，再进入 `AppGenerateService.generate`；调用方无法直接越过应用边界取得租户的模型或工具配置。`sdks/` 中有 Node/PHP 客户端，但本次只确认目录和 API 边界，未验证 SDK 版本覆盖或端到端兼容性。

App Deployment v2 将具体发布版本部署到 environment，并为环境 WebApp 与 service API 建立独立访问点；当前前端将 MCP 和 trigger 明确标为环境不支持。环境执行所需文件不复用 Enterprise control plane 的主密钥：受信内网入口先为 app/end-user 签发短期 grant，公开文件端点再按 upload、resolve、produce scope 接收上传、远程抓取、产物写入或重新签名，内容读取使用单文件 token（`api/controllers/inner_api/app/file_grants.py:117-205`；`api/controllers/files/appdeploy_files.py:1-298`）。grant 接口还有独立错误类型与上限模型，用于拒绝非法请求、过期时间过长、非法 subject 与不存在的 app，说明该交接带显式约束而非仅靠内网信任。这形成“外部部署控制面 -> Dify 运行文件面”的受限能力交接，但控制面身份、环境生命周期和实际部署由 Enterprise 边界持有，尚不能升级为本仓库独立掌握的外部协作主链。

## 2. 平台调用外部工具与 MCP

工具 Provider 管理允许把内置、API、插件、workflow 和 MCP 能力纳入 tenant 工作区。MCP 的 Provider payload 包含 server URL、server identifier、配置、headers、authentication 与 identity mode（`api/controllers/console/workspace/tool_providers.py`）；运行时 MCPTool 调用远端 server，服务端管理器负责加密 headers、OAuth token 和远端工具发现（`api/core/tools/mcp_tool/tool.py:311`）。

identity forwarding 的 API 层与运行时都受 Enterprise 部署门控。这是一项具体版本边界，不能以 MCP 配置存在推断社区版会转发身份。真实 OAuth、动态注册、超时、SSE 读取和重连均未运行验证。

快照还新增了另一条明确的外部能力边界：KnowledgeFS 由独立部署的知识服务承担，Dify 通过仓内固定的 OpenAPI、能力操作清单与 Capability v2 认证 profile 与它交互，认证使用签名密钥与 kid，且 CI 只校验契约哈希而不克隆该服务（`api/knowledge-fs-contract/README.md`、`api/services/knowledge_fs/feature_service.py:1-37`）。这是本仓库中少见的“协议先行、实现外置”的外部依赖形态，但仍属于 Dify 主动调用外部能力，没有外部执行体持有 Dify 运行状态或反向接管。

## 3. 外部事件与触发器

`core/trigger/` 和 `api/controllers/console/workspace/trigger_providers.py` 管理 trigger provider、订阅 builder、验证、更新、删除、请求日志及 OAuth 回调。Webhook 的已发布入口接收多种 HTTP method，先按 webhook ID 取得 trigger、已发布 workflow 与节点配置，再提取并校验 method、headers、query、body 和 files；校验通过后投递执行，并立即返回节点配置的 HTTP 响应（`api/controllers/trigger/webhook.py:61-140`）。快照中这段逻辑已从控制器移入独立 webhook 服务，服务负责取 trigger 与 workflow、抽取并校验数据、限制 content length、清洗键名与准备触发型终端用户（`api/services/trigger/webhook_service.py:84-300`）。这个响应是 webhook 协议的同步回执，不是 workflow 的最终输出；另有调试入口 `/webhook-debug/<id>`，不产生正式触发。

plugin trigger 的内部执行链可静态贯通：后台任务从缓存取原始请求和 payload，按 tenant、subscription 和 event 找订阅者，再只选择已发布 workflow；它为每个 app 创建 `EndUserType.TRIGGER` 终端用户、预留 trigger 配额，并将事件交给异步 workflow service（`api/tasks/trigger_processing_tasks.py:242-470`）。异步服务先创建 `WorkflowTriggerLog` 并入队，执行后由 trigger post layer 写回成功、失败、中止或暂停状态、run ID、outputs、错误、耗时和 token；schedule 也复用该服务。这确认了 Dify 内部的“事件 -> 入队 -> workflow -> 结果日志”，却不能补齐本类目需要的外部回流。

普通 webhook 的配置只包含 method/content type/headers/params/body/静态响应和 timeout；未发现 secret、HMAC、timestamp 或 event-id/idempotency 字段。它在提交异步任务后立即回复节点配置的静态内容，该响应不能代表 workflow 最终结果。schedule poller 有数据库锁与启停控制，但其任务明确不重试失败执行；plugin trigger 可把 provider-specific signature 校验委托给 daemon/plugin，却没有 Dify 统一验签、delivery-id 去重、最终回调或对外 run 查询协议。因此 Trigger Provider 在本类目只能记为 `入口确认`，不能以内部日志链替代双向持续协作。

## 4. 接入角色、状态映射与准入判断

已发布应用的 service API 是外部业务系统调用 Dify 的稳定表面：调用者提交 inputs/files 或消息输入，Dify 在服务端创建应用运行记录并以流/阻塞结果返回。它满足“外部应用调用宿主”的一部分链路，但本轮没有追到外部系统的持久账号、资源 installation 或双向任务接管，因此不把普通 API 调用升级为外部执行体协作。

MCP 与插件表现为 Dify 主动调用外部工具的机制。已确认 MCP Provider 配置、远端工具发现/调用、headers/OAuth 交接与工具结果进入 Agent/workflow；没有确认外部系统身份如何与本地会话/资源持续映射、断线后如何恢复或用户如何接管。Trigger Provider 与 webhook/schedule trigger 确实把外部事件映射为发布 workflow、触发型 End User、workflow run 与 trigger log，但同步 webhook 响应和异步 run 的结果面分离。当前没有确认外部系统接收最终 workflow 输出、取消正在执行的 run 或按关联 ID 恢复消费，故属于 `入口确认`，而不是本类目的静态 `主链确认`。

快照中最接近“双向外部通道”的是人机协同表单 v2 的 IM 集成：Dify 把待办表单投递到 Slack、飞书/Lark、钉钉、企业微信或 Microsoft Teams，收件人在渠道内提交后经 webhook 回流，再由工作流恢复执行。该链具备租户级渠道凭据、联系人绑定与同步、入站消息 inbox 处理和幂等记录，比普通 webhook 更完整（`api/services/human_input_v2/im_channel_service.py`、`api/services/human_input_v2/im_contact_sync/`、`api/services/human_input_v2/im_message_inbox/`、`api/controllers/web/human_input_v2_im_webhook.py`）。但通道另一端是人，平台适配在 Dify 侧，外部系统不持有运行状态也不承接接管，因此它仍未构成本类目要求的外部执行体协作。

## 5. 结果回流与边界

外部应用调用的结果以 JSON/SSE、message 或 workflow run 形式返回；工具调用结果以 Agent/节点事件进入后续模型或可见消息；触发器以 workflow run、workflow app log 和 trigger log 承接异步结果，webhook 调用方只得到预配置的同步 HTTP 响应。外部 API、MCP/插件和 trigger 的凭据均由服务端 tenant/workspace 层管理，但完整脱敏、审计和备份策略未覆盖。

## 6. 未验证事项

- service API key、End User、文件上传及 run 查询的真实授权与限流。
- SDK 请求序列化、流重连、错误兼容性和版本契约。
- App Deployment 环境的控制面身份、版本部署、访问控制、grant TTL、文件所有权和撤销效果。
- MCP OAuth/identity forwarding、远端失败、结果大小和网络中断。
- trigger 的签名验证、重试、幂等、事件顺序、多实例投递，以及外部系统获取最终 workflow 输出的协议。
- schedule 的单次失败处理、Celery 发布与数据库提交之间的崩溃窗口、plugin provider 的签名/事件 ID 契约、原始请求日志的保留和敏感数据边界。
- webhook 接入已移入独立服务并新增 content length 与调试入口，但其防重放、超时、并发与错误回执未运行验证。
- IM 人机协同通道的渠道凭据加密、联系人绑定、入站验签/幂等、送达重试与表单过期行为未运行验证。
- KnowledgeFS 外部服务的可用性、签名轮换、契约版本兼容与错误处理未运行验证，服务端实现不在本仓库。

## 7. 关键源码索引

- `api/controllers/service_api/app/`：已发布应用 API
- `api/controllers/web/workflow.py:44-148`：公开 Web workflow 调用与停止
- `sdks/`：Node/PHP 客户端边界
- `api/core/tools/mcp_tool/`、`api/services/tools/mcp_tools_manage_service.py:79-692`：MCP 客户端和配置
- `api/core/trigger/`、`api/controllers/console/workspace/trigger_providers.py`、`api/services/trigger/webhook_service.py`：触发器订阅、webhook 接入与管理
- `api/controllers/console/workspace/tool_providers.py`：外部工具 Provider 管理
- `api/controllers/inner_api/app/file_grants.py:117-205`、`api/controllers/files/appdeploy_files.py`：部署环境文件 grant 与公开文件端点
- `api/services/human_input_v2/`、`api/controllers/web/human_input_v2_im_webhook.py`：IM 渠道投递、联系人绑定与入站回传
- `api/services/knowledge_fs/`、`api/knowledge-fs-contract/`：KnowledgeFS 外部知识服务的客户端与契约

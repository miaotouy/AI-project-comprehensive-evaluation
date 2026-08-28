# Dify 外部执行体与应用协作调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态阅读 service API、Web API、SDK 目录、MCP/插件工具与触发器管理代码；补查 webhook、schedule、plugin trigger 的日志、认证、幂等、重试和结果边界；未连接外部服务
>
> 调查范围：外部调用应用、平台调用外部能力、外部事件触发三条协作边界；按本类目准入门槛判断是否存在持续外部协作，不把单向 API、普通 MCP 或 webhook 误列为主链；不审计第三方协议端实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 有三种对外接入边界：业务系统经 service API 调用已发布应用；运行中的 Agent/workflow 经工具、插件或 MCP 调用外部能力；外部事件经 webhook、schedule 或 plugin trigger 创建异步 workflow run。它们都提供了可调查的协议与运行入口，但按本类目要求，当前代码快照中尚未确认拥有持续身份、双向回流、状态映射和接管治理的外部协作主链。不能把“支持 MCP”或“能被 webhook 触发”泛化为外部执行体协作。

## 1. 外部调用已发布应用

service API 按应用能力提供 workflow、conversation、message、file 与 site 路由；公开 Web API 也有 workflow run/stop 入口。`/files/upload`、`/site`、`/workflows/run` 等接口共同构成应用调用面的配套资源（`controllers/service_api/app/{file,site,workflow}.py`）。workflow 运行可选择 blocking 或 SSE streaming，run/task ID 继续用于详情和停止。

这些路由先验证应用 token 并解析终端用户，再进入 `AppGenerateService.generate`；调用方无法直接越过应用边界取得租户的模型或工具配置。`sdks/` 中有 Node/PHP 客户端，但本次只确认目录和 API 边界，未验证 SDK 版本覆盖或端到端兼容性。

## 2. 平台调用外部工具与 MCP

工具 Provider 管理允许把内置、API、插件、workflow 和 MCP 能力纳入 tenant 工作区。MCP 的 Provider payload 包含 server URL、server identifier、配置、headers、authentication 与 identity mode（`tool_providers.py:259-310,387-397`）；运行时 MCPTool 调用远端 server，服务端管理器负责加密 headers、OAuth token 和远端工具发现。

identity forwarding 的 API 层与运行时都受 Enterprise 部署门控（281-295 行）。这是一项具体版本边界，不能以 MCP 配置存在推断社区版会转发身份。真实 OAuth、动态注册、超时、SSE 读取和重连均未运行验证。

## 3. 外部事件与触发器

`core/trigger/` 和 `controllers/console/workspace/trigger_providers.py` 管理 trigger provider、订阅 builder、验证、更新、删除、请求日志及 OAuth 回调。Webhook 的已发布入口接收多种 HTTP method，先按 webhook ID 取得 trigger、已发布 workflow 与节点配置，再提取并校验 method、headers、query、body 和 files；校验通过后由 `WebhookService.trigger_workflow_execution` 投递执行，并立即返回节点配置的 HTTP 响应（`controllers/trigger/webhook.py:32-86`）。这个响应是 webhook 协议的同步回执，不是 workflow 的最终输出。

plugin trigger 的内部执行链可静态贯通：后台任务从缓存取原始请求和 payload，按 tenant、subscription 和 event 找订阅者，再只选择已发布 workflow；它为每个 app 创建 `EndUserType.TRIGGER` 终端用户、预留 trigger 配额，并将事件交给异步 workflow service（`tasks/trigger_processing_tasks.py:373-520`）。异步服务先创建 `WorkflowTriggerLog` 并入队，执行后由 trigger post layer 写回成功、失败、中止或暂停状态、run ID、outputs、错误、耗时和 token；schedule 也复用该服务。这确认了 Dify 内部的“事件 -> 入队 -> workflow -> 结果日志”，却不能补齐本类目需要的外部回流。

普通 webhook 的配置只包含 method/content type/headers/params/body/静态响应和 timeout；未发现 secret、HMAC、timestamp 或 event-id/idempotency 字段。它在提交异步任务后立即回复节点配置的静态内容，该响应不能代表 workflow 最终结果。schedule poller 有数据库锁与启停控制，但其任务明确不重试失败执行；plugin trigger 可把 provider-specific signature 校验委托给 daemon/plugin，却没有 Dify 统一验签、delivery-id 去重、最终回调或对外 run 查询协议。因此 Trigger Provider 在本类目只能记为 `入口确认`，不能以内部日志链替代双向持续协作。

## 接入角色、状态映射与准入判断

已发布应用的 service API 是外部业务系统调用 Dify 的稳定表面：调用者提交 inputs/files 或消息输入，Dify 在服务端创建应用运行记录并以流/阻塞结果返回。它满足“外部应用调用宿主”的一部分链路，但本轮没有追到外部系统的持久账号、资源 installation 或双向任务接管，因此不把普通 API 调用升级为外部执行体协作。

MCP 与插件表现为 Dify 主动调用外部工具的机制。已确认 MCP Provider 配置、远端工具发现/调用、headers/OAuth 交接与工具结果进入 Agent/workflow；没有确认外部系统身份如何与本地会话/资源持续映射、断线后如何恢复或用户如何接管。Trigger Provider 与 webhook/schedule trigger 确实把外部事件映射为发布 workflow、触发型 End User、workflow run 与 trigger log，但同步 webhook 响应和异步 run 的结果面分离。当前没有确认外部系统接收最终 workflow 输出、取消正在执行的 run 或按关联 ID 恢复消费，故属于 `入口确认`，而不是本类目的静态 `主链确认`。

## 结果回流与边界

外部应用调用的结果以 JSON/SSE、message 或 workflow run 形式返回；工具调用结果以 Agent/节点事件进入后续模型或可见消息；触发器以 workflow run、workflow app log 和 trigger log 承接异步结果，webhook 调用方只得到预配置的同步 HTTP 响应。外部 API、MCP/插件和 trigger 的凭据均由服务端 tenant/workspace 层管理，但完整脱敏、审计和备份策略未覆盖。

## 未验证事项

- service API key、End User、文件上传及 run 查询的真实授权与限流。
- SDK 请求序列化、流重连、错误兼容性和版本契约。
- MCP OAuth/identity forwarding、远端失败、结果大小和网络中断。
- trigger 的签名验证、重试、幂等、事件顺序、多实例投递，以及外部系统获取最终 workflow 输出的协议。
- schedule 的单次失败处理、Celery 发布与数据库提交之间的崩溃窗口、plugin provider 的签名/事件 ID 契约、原始请求日志的保留和敏感数据边界。

## 关键源码索引

- `api/controllers/service_api/app/`：已发布应用 API
- `api/controllers/web/workflow.py:41-116`：公开 Web workflow 调用与停止
- `sdks/`：Node/PHP 客户端边界
- `api/core/mcp/`、`api/services/tools/mcp_tools_manage_service.py`：MCP 客户端和配置
- `api/core/trigger/`、`api/controllers/console/workspace/trigger_providers.py`：触发器订阅和管理
- `api/controllers/console/workspace/tool_providers.py`：外部工具 Provider 管理

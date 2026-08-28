# Dify LLM 渠道管理调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态阅读 Provider/Model 管理器、控制台 API、凭据加密、Plugin Runtime、模型调用与 usage/trace 持久化；未配置真实凭据、daemon 或访问厂商
>
> 调查范围：租户级 Provider、模型凭据、实例解析、负载均衡和运行时边界；控制台页面交互未运行验证
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 的渠道管理单元是租户作用域下的 Provider 配置、模型配置、模型凭据与负载均衡配置，而不是浏览器直接保存的一组 API Key。主仓库负责凭据的租户隔离、加密/脱敏、实例选择、同模型多 Key 调度、统一结果和 usage/trace 交接；已安装的 Provider 插件与 Plugin Daemon 再持有厂商 HTTP 协议和上游行为。`ModelManager` 每次运行按 tenant、Provider、模型类型和模型名解析实例，故“模型渠道”是服务端加密配置到 plugin runtime 的完整交接链，而非前端设置页。

## 总体调用链

```text
控制台/插件安装写入租户 Provider 与模型配置
  -> 验证候选凭据并以 tenant 作用域加密保存，回显时脱敏
  -> ProviderManager/PluginModelAssembly 按已安装插件与 tenant 配置生成 ProviderModelBundle
  -> ModelManager.get_model_instance(tenant, provider, type, model)
  -> 应用生成器或 workflow LLM/Agent 节点调用统一 wrapper
  -> PluginModelClient 把解密 credentials、messages、参数与 tools 交给 Plugin Daemon
  -> 统一结果回到应用/图运行，usage、延迟和 trace 进入消息/工作流记录与异步队列
```

应用请求只携带所选应用的配置引用和输入；真实 Provider/模型凭据在后端管理器中解析。因此公开 WebChat 不能直接读取或编辑租户的原始模型凭据。

## 1. Provider、模型与凭据数据层

ProviderCredential 以 `(tenant_id, provider_name)` 区分，ProviderModelCredential 还分 `model_name/model_type`；两者都可有命名多份记录，模型选择一份 active credential，负载均衡则管理同模型的候选集合。ProviderManager 的缓存来源也明确区分 preferred provider、model setting、provider-model credential、provider credential 与 provider load-balancing config（`api/models/provider.py:35-365`、`api/core/provider_manager.py:80-85,543-1175`）。这表明“Provider 凭据”和“某一模型的凭据”可独立配置，且负载均衡是另一个配置层，而不是一份 Provider API Key 的别名。

控制台 API 已覆盖 Provider/模型凭据的创建、更新、删除、切换和验证，模型的启停/默认选择及负载均衡验证；创建/管理操作分别经过 tenant 注入与 credential/plugin preference 权限。保存前先把候选 credential 交给当前 Provider plugin 验证，成功后按 secret schema 用 tenant 作用域的 encrypter 写入 `encrypted_config`。读取特定 credential 时会解密后用 `obfuscated_token` 回显，编辑提交的 `[__HIDDEN__]` 则从同 tenant 的原记录取回再验证，因此浏览器不需回传 secret。该证据只说明数据库字段加密和 API 脱敏，不覆盖备份、日志、daemon 内存或异常文本。

## 2. 运行时实例与凭据缓存

ModelManager 的默认 `enable_credentials_cache=False`；默认每次 `get_model_instance` 都从当前 Provider 配置读取凭据。若显式打开缓存，键为 `(tenant_id, provider, model_type, model)`，配置变更后可能得到过期凭据，代码注释建议 manager 不跨请求或 workflow run 长期复用（823-847、933-945 行）。这是“配置保存后何时生效”的关键边界：默认路径倾向于按运行解析，不等同于所有长驻组件立刻刷新。

模型目录不是主仓库硬编码的 OpenAI/Anthropic 表。每次服务组装会按 tenant/user 创建 `PluginModelAssembly`，由 Plugin Service 发现已安装的 model-provider 并按其 schema 构建 LLM、embedding、rerank、STT、moderation 和 TTS wrapper。`ModelManager.get_model_instance` 取得 tenant bundle、检查 system model access 后构造 ModelInstance；调用 `invoke_llm` 时，plugin runtime 将 plugin ID、解密 credentials、messages、parameters、tools、stop、stream 和可选 app ID 交给 daemon 的 `dispatch/llm/invoke`，流/非流结果再规整为统一 graphon 结果（`api/core/plugin/impl/model_runtime_factory.py:24-137`、`api/core/plugin/impl/model_runtime.py:106-362`、`api/core/plugin/impl/model.py:170-218`）。

因此可确认 Dify 到 Plugin Daemon 的调用边界，却不能从主仓库断言厂商的 Base URL/Header、兼容字段、真正的 HTTP 请求、上游重试或插件内部脱敏。连接验证也走另一个 `validate_provider_credentials`/`validate_model_credentials` RPC，不等同于 `llm/invoke` 的正式生成请求；验证成功不能单独证明聊天可用、余额充足或正式运行参数兼容。

## 3. 多 Key、限流与失败处理

当模型有 load balancing manager 时，`_round_robin_invoke` 循环取得下一份配置。只对 `InvokeRateLimitError` 冷却 60 秒、对授权或连接错误冷却 10 秒后换下一 credential；其他异常立即上抛（`api/core/model_manager.py:429-480`）。这确认多凭据选择既不是纯静态轮转，也不只发生在控制台保存时。

该路径只能证明本模型实例的凭据级调度。它不等同于跨 Provider fallback，也不能证明冷却状态跨进程持久化。workflow generator 的另一条专用路径最多重试一次连接/503/限流等 transient 异常，永久授权和 bad request 不重试，且注释承认重试可能额外消耗 quota；它也不能外推为全平台的重试或不重复计费保证。

## 4. 凭据边界与可观测性

Provider cache entry 有 encrypted configuration 字段，MCP/插件服务也使用加密帮助器；但本次没有穿透数据库密钥管理、日志、备份、导出与所有 HTTP 适配器。因此仅能确认凭据由服务端 tenant 配置层拥有，不能断言全链路加密、脱敏或零泄漏。

普通 Chat/Completion 收尾会把 prompt/completion token、单价、总价、currency 和计算出的 response latency 写入 Message/metadata，再投递 `MESSAGE_TRACE`；advanced chat/workflow 同样将 graph runtime 的 `llm_usage` 写入消息，workflow persistence 另投递带 session/parent context 的 `WORKFLOW_TRACE`。这确认统一模型结果已抵达应用记录和 trace 队列，但没有运行验证厂商 usage 的准确性、trace 实际送达、成本汇总展示、保留或 RBAC。

## 5. 配置生命周期与管理入口

这里的 Provider 是租户下的提供方配置，模型是 Provider 所暴露的某种模型类型/名称，凭据可位于 Provider 或具体模型层，Endpoint、Base URL 与协议细节由相应 provider/plugin 配置承担。它们不是公开聊天页面的一组浏览器设置。`ProviderManager` 的缓存项同时包含 preferred provider、model setting、provider-model credential、provider credential 和 load-balancing config，说明这些层级可以独立存在，而非一条“模型行”保存全部状态。

控制台和 plugin/provider 管理 API 是配置生命周期的主要入口；运行时由 `ModelManager` 重新解析实例。控制台模型 Provider 页会按已配置/未配置状态分组，支持名称搜索，并显示文本生成、embedding、rerank、语音转文字和 TTS 的系统默认模型状态；Provider 设置入口受 `canSetPluginPreferences` 权限控制（`web/app/components/header/account-setting/model-provider-page/index.tsx:40-260`）。已安装 Provider 插件的卡片还按权限提供版本更新、详情检查和删除入口（`provider-added-card/provider-card-actions.tsx:44-220`）。

单模型配置可打开负载均衡对话框，读取当前 credential 与候选 credential，在保存时提交启用状态和配置列表；未改动的 secret 字段以 `[__HIDDEN__]` 占位后再提交，成功或失败均有 toast 反馈（`provider-added-card/model-load-balancing-modal.tsx:37-198`）。这确认 Web 控制台有 Provider 查找、默认模型、插件维护、凭据切换和负载均衡的静态入口，不证明凭据保存、删除、外部连接测试或刷新时序已在真实部署中成功。CLI、TUI、桌面端也未作为渠道管理入口完成调查。

| 维度 | 已确认结论 | 本轮未确认的部分 |
| --- | --- | --- |
| 配置范围 | Provider、模型设置、两层凭据和负载均衡按 tenant 解析 | 多工作区迁移、删除后运行中任务的处理 |
| 保存与生效 | 先 plugin validate，再按 tenant 加密写入；回显脱敏，默认实例每次解析凭据 | 控制台保存失败、缓存失效的真实时序 |
| Endpoint/协议 | Plugin Runtime 向 daemon `llm/invoke` 交付统一请求 | 各厂商 Base URL、Header、兼容字段和上游 HTTP |
| 模型目录 | 已安装 model-provider 的 schema 组装 tenant runtime | daemon/插件目录刷新、价格/能力元数据和用户自定义模型 UI |
| 诊断与观测 | validate RPC 与正式 invoke 分离；usage/latency 写入消息，trace 入队 | 验证动作、trace 送达、成本准确性/展示/保留/RBAC |

## 6. 路由、故障与平台边界

调用者给出应用所选模型引用后，生成器或 workflow LLM/Agent 节点向 `ModelManager` 请求 tenant、Provider、model type、model 的实例；真实协议请求在实例/Provider 实现中完成。负载均衡循环对限流、授权和连接类可恢复异常尝试下一份配置，并对限流项施加冷却。这是“同一模型的多凭据选择”，不是按价格、延迟或语义的智能路由，也不是跨 Provider 的 failover。

浏览器只将公开应用输入交给 API；Provider 凭据、请求组装和上游网络访问位于服务端。Dify 部署是否把 API、worker、插件 runtime 分到不同进程/容器，以及它们如何共享缓存和日志，本轮未运行 Docker，故未作部署拓扑结论。

## 已确认边界与未验证事项

- Provider/模型/凭据/负载均衡为独立的 tenant-scope 配置层。
- 默认模型实例不缓存凭据；显式缓存可能陈旧，推荐按请求或 workflow run 使用。
- 运行时对限流、授权、连接异常存在负载均衡选择与冷却路径；跨 Provider failover 未确认。
- 已确认 Web/API 的 Provider/模型凭据生命周期、tenant 加密保存和脱敏回显；未验证数据库/日志/daemon 内存的安全效果。
- 已确认主仓库到 Plugin Daemon 的统一模型调用、结果归一化以及 usage/trace 落库/入队；未验证厂商 HTTP、插件内部重试、usage/成本精度和 trace 最终送达。
- 已确认连接测试与正式 invoke 分路、同模型多 Key 的有限冷却调度；跨 Provider failover、跨进程冷却一致性、重试幂等和计费语义未确认。

## 关键源码索引

- `api/models/provider.py:35-365`、`api/controllers/console/workspace/model_providers.py:201-357`、`api/controllers/console/workspace/models.py:205-611`：tenant 凭据实体、控制台生命周期与模型选择。
- `api/core/entities/provider_configuration.py:301-675,990-1195,1491-1532`：候选验证、加密保存、脱敏回显和多 Key 负载均衡约束。
- `api/core/model_manager.py:190-220,429-480,822-974`：实例解析、缓存、调用和 credential 冷却。
- `api/core/plugin/impl/model_runtime_factory.py:24-137`、`api/core/plugin/impl/model_runtime.py:106-362`、`api/core/plugin/impl/model.py:99-218`：插件目录组装、validate/invoke RPC 与统一结果。
- `api/core/app/task_pipeline/easy_ui_based_generate_task_pipeline.py:425-499`、`api/core/app/workflow/layers/persistence.py:476-501`：usage/latency 持久化和 trace 投递。

# VCPMobile LLM 渠道管理调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`cecdbe432feda57821938bba7625a272113d21c1`（分支：`main`）
>
> 调查方式：只读静态源码核对，覆盖设置、模型目录、聊天请求、连接测试与模型选择界面；未启动 Android 应用或连接 VCP 服务
>
> 调查范围：移动端对 VCP 网关的地址、凭据、模型目录、请求路由与测试能力；不调查 VCPChat/VCPToolBox 服务端内部的 Provider 管理
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 没有本地 Provider、Endpoint 或 Profile 实体。它保存一套全局 VCP 网关 URL 与 API Key；每个 Agent 只保存裸模型 ID 和生成参数。发送时，前端从全局设置取 URL/Key，Rust 端将 Agent 的模型配置和已装配消息发给该网关。因此，多上游协议、模型路由、Key 轮换和跨 Provider 容灾若存在，只能属于网关或其后端，不能归因于该移动端。

模型目录来自同一网关的 `/v1/models`，只保留 ID、对象类型、创建时间和 `owned_by`。目录会写入 SQLite 设置表作缓存；收藏和使用次数也仅按模型 ID 保存，用于本地排序。没有本地模型能力、价格、上下文上限或模态元数据目录。

## 总体调用链

```text
设置页的全局 VCP URL / API Key
  -> SQLite settings.global（JSON）和内存缓存
  -> 聊天发送时前端带入 AgentChatPayload
  -> Agent 配置给出 model、token 限制、stream 与可选 temperature
  -> VcpRequestPayload
  -> 普通 /v1/chat/completions，或启用网关工具注入时 /v1/chatvcp/completions
  -> Bearer 鉴权 HTTP/SSE 请求
```

聊天入口明确把全局设置的 `vcpServerUrl` 和 `vcpApiKey` 放入 Agent 或群组请求载荷；Agent 服务随后读取该 Agent 配置并构造模型参数。`src/core/stores/chatHistoryStore.ts:354-398`，`src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:59-163`。

## 1. 渠道实体、配置与凭据

全局 `Settings` 只有一组 `vcp_server_url` 和 `vcp_api_key`，另有用于日志/信息 WebSocket 的另一组 URL/Key；这些不是多个可管理的 LLM 渠道。设置页允许编辑 VCP URL 和 API Key，并提供验证按钮。`src-tauri/src/vcp_modules/infra/settings_manager.rs:18-91`，`src/features/settings/components/VcpCoreSettingsSection.vue:18-65`。

设置以 JSON 字符串写入本地 SQLite 的 `settings` 表中键名为 `global` 的记录，并有进程内缓存和串行更新锁。当前代码没有看到应用层加密、凭据专用存储、导入/导出、多个 Key 或代理字段；因此只能确认密钥随设置 JSON 落库，未验证 Android 系统层的磁盘保护、备份范围和日志是否完整脱敏。`src-tauri/src/vcp_modules/infra/settings_manager.rs:171-201,271-351`。

## 2. 模型目录与本地管理

刷新会从全局 URL 推导 origin，再以 Bearer Key 请求 `/v1/models`，成功后将模型数组同时写入内存和 `settings.cached_models`。前端先读缓存，再按五分钟窗口做后台刷新；手动刷新显示结果。`src-tauri/src/vcp_modules/infra/model_manager.rs:63-174`，`src/core/stores/modelStore.ts:61-134`。

模型选择器可以按 `owned_by`、收藏和使用次数筛选排序。收藏与热门是本地 UI 统计，不是网关健康或路由信号；不同网关复用同一模型 ID 时也没有命名空间隔离。`src/components/ModelSelector.vue:34-70`，`src-tauri/src/vcp_modules/infra/model_manager.rs:177-287`。

## 3. 协议、请求组装与运行时选择

请求端先根据设置中的 `enableVcpToolInjection` 选择专用 `chatvcp` 路径，否则通过 URL 规范化使用 Chat Completions 路径；随后补齐空 system 消息、加入请求 ID 和时间戳扩展，并用 `Authorization: Bearer` 发出流式或非流式 HTTP 请求。代码是单一 VCP/OpenAI-compatible 网关适配，并未实现 Anthropic、Gemini 等客户端 Adapter。`src-tauri/src/vcp_modules/infra/vcp_client.rs:375-478`。

运行时模型选择完全由 Agent 的 `model` 字段决定；其 `max_output_tokens`、上下文限制、流式开关和按需 temperature 直接进入请求体。网关 URL/Key 不可由 Agent 覆盖。`src-tauri/src/vcp_modules/agent/agent_types.rs:8-51`，`src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:97-139`。

## 4. 连接检测、失败处理与可观测性

设置页的“验证连接”请求 `/v1/models`，十秒超时；模型面板另可对一个模型发送 `ping` 聊天请求，单次超时六十秒，并可按每批五个、总数最多二百个并发测试。后者更接近真实推理路径，但两条测试路径都未实际运行验证。`src-tauri/src/vcp_modules/infra/vcp_client.rs:1663-1714`，`src-tauri/src/vcp_modules/infra/model_manager.rs:290-380,392-502`。

模型测试将延迟和错误回传 UI；普通聊天链路有请求 ID 与用户中断租约，便于避免同 ID 重入，但本次检查范围内未找到普通聊天的自动重试、模型 fallback、Key 轮询、限流冷却、跨网关 failover、成本统计或结构化请求追踪。请求失败会返回错误到调用方。`src-tauri/src/vcp_modules/infra/vcp_client.rs:140-223,375-478`。

## 5. 已确认边界与未验证事项

- 渠道粒度是单全局 VCP 网关，不支持客户端侧多个 Provider/Endpoint/Profile 的 CRUD、复制、启停或负载均衡。
- `enableVcpToolInjection` 只是切换网关路径；不表示 VCPMobile 自己实现了工具目录或工具循环。
- 未启动应用，也未连接真实服务，未验证 URL 拼接、SSE 兼容性、测试结论、凭据在平台备份中的可见性及服务端路由行为。

## 关键源码索引

- `src-tauri/src/vcp_modules/infra/settings_manager.rs`：全局设置结构、SQLite 持久化与运行时重连。
- `src-tauri/src/vcp_modules/infra/model_manager.rs`：模型列表缓存、刷新、收藏、使用次数和连通性测试。
- `src-tauri/src/vcp_modules/infra/vcp_client.rs`：请求路径选择、Bearer 请求、流式处理和中断登记。
- `src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs`：Agent 模型参数到网关请求的交接。

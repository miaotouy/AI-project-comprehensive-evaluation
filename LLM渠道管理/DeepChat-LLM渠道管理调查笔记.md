# DeepChat LLM 渠道管理调查笔记

> 调查对象：`E:\works\git\deepchat`（重点 `src/shared/types/provider.ts`、`src/main/provider/`、`src/main/provider/aiSdk/`、`src/main/provider/managers/`）
>
> 调查更新日期：2026-08-06
>
> 代码快照：`dc4177c2ac80905ebac985554a9f957aaca31ab8`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改 DeepChat 仓库
>
> 调查范围：Provider 数据模型、默认渠道、模型能力配置、AI SDK 路由、请求运行时、模型状态和限流
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的渠道管理把“Provider 身份”“模型目录/能力”和“请求执行 runtime”分开：

1. Provider 记录保存 id、apiType、apiKey、baseUrl、模型列表、customModels、启停状态和 rate limit；ModelConfig 单独保存上下文、生成参数、vision/function-call/reasoning、媒体和 endpoint 能力。
2. `DEFAULT_PROVIDERS` 覆盖 OpenAI-compatible、Anthropic、Gemini、Vertex、Ollama、Bedrock、GitHub Copilot、ACP 等多类 apiType；`providerRegistry` 再把 provider id/apiType 映射到 AI SDK runtime behavior preset 和 credential/route 策略。
3. `ProviderSettings` 负责默认初始化、用户 Provider CRUD/排序、模型启停、custom model、模型 config、能力快照、Provider DB 刷新和旧配置迁移；设置写入 SQLite-backed store，并保留兼容迁移路径。
4. AI SDK runtime 统一消息映射、原生/legacy tool、reasoning、图片/视频/TTS、embedding、trace、timeout/abort；ACP 的 `apiType: acp` 仍由 AgentManager 的 ACP backend 处理，不等同于普通聊天 Provider。
5. 每个 Provider 可启用 QPS 限流。`RateLimitManager` 以 Provider 为单位维护队列、估算等待时间和状态事件；源码未显示跨 Provider 自动 failover 或健康权重路由。

## 1. Provider 与模型数据

`LLM_PROVIDER`（`src/shared/types/provider.ts:74-106`）包含：

```text
id / capabilityProviderId / name / apiType
apiKey / oauthToken / baseUrl
models / customModels / enabledModels / disabledModels
enable / custom / websites
rateLimit / rateLimitConfig
```

`ModelConfig`（`src/shared/types/provider.ts:370-398`）把模型有效能力归一化为 `maxTokens`、`contextLength`、`timeout`、temperature/topP、vision、speech recognition、function call、reasoning、thinking/reasoning effort、endpoint type，以及 search、image/video generation、TTS 等字段。用户覆盖和 Provider/system 能力通过 `IModelConfig.source` 区分（`:404-413`）。

## 2. 默认渠道与注册表

`src/main/provider/defaults.ts:3-25` 起定义默认 Provider，后续条目覆盖大量 OpenAI-compatible 渠道，并明确列出 OpenAI Responses、OpenAI Codex、ACP、Gemini、Vertex AI、Anthropic、GitHub Copilot、Azure OpenAI、AWS Bedrock 等（`:209-239`、`:284-344`、`:569-570`、`:978-1011`）。默认 Provider 会在 `ProviderSettings` 构造阶段与已存在配置合并（`src/main/provider/settings.ts:379-411`）。

`providerRegistry.ts:50-67` 的 `AiSdkProviderDefinition` 将渠道映射到：runtime kind、behavior preset、模型来源、连通性检查、credential strategy、route strategy、embedding strategy 和默认 headers。解析优先匹配 provider id，再匹配 apiType（`:684-690`）。同一个 OpenAI-compatible apiType 可以因此复用统一 runtime，同时保留 Provider 自己的 endpoint/key。

## 3. ProviderSettings 生命周期

`ProviderSettings`（`src/main/provider/settings.ts:322-412`）组合四类 helper：Provider CRUD、模型状态、模型 config 和 custom model。初始化过程中：

1. 连接 settings store 与 SQLite provider database；
2. 初始化 provider models 目录与聚合 Provider DB loader；
3. 读取旧版本并执行迁移、清理 deprecated Provider；
4. 将新增默认 Provider 追加到现有列表。

模型配置通过 `getModelConfig` 解析 route config、Provider model facts、capability identity 和 `ModelConfigHelper`（`:1261-1329`）。用户可按 provider/model 写入、重置、导出和导入模型配置（`:1332-1399`）。模型启停和 custom model 由独立 helper 维护，Provider 列表变化通过 event publisher 通知 renderer。

## 4. 请求运行时

聊天请求在 `src/main/provider/aiSdk/runtime.ts:1178-1224` 组装：

```text
Provider + model config + capability snapshot
  -> mapMessagesToModelMessages
  -> resolve native tool support
  -> mcpToolsToAISDKTools（支持原生时）
  -> provider options / system message split
  -> AI SDK stream/generate
```

请求 signal 由 caller signal 和模型 timeout 合并（`:1286-1291`）；runtime 还统一处理 reasoning、图片/视频生成和 TTS（`:716-803`、`:1357-1519`），embedding 路径在 `:1587-1766`。`requestTrace` 记录 provider id、model id、endpoint、headers/body 摘要和 logical round，具体是否落盘由调用方控制。

原生 tool stream 与 `<function_call>` legacy 兼容由 `streamAdapter.ts:57-124`、`toolProtocol.ts:38-150` 负责；这使渠道差异集中在 capability snapshot 和 provider definition，而上层 Agent loop 仍消费统一 core stream event。

## 5. 模型目录和能力快照

`BaseLLMProvider`（`src/main/provider/baseProvider.ts:31-320`）封装 Provider 初始化、模型列表获取、缓存和 custom model CRUD。ProviderSettings 的 capability route 会把 Provider DB/model facts、endpoint type、ownedBy 和 API type 交给 ModelConfigHelper；最终 `functionCall`、vision、reasoning 等是“有效配置”，不是只由模型名称推测。

本次确认的渠道身份是 `provider.id + modelId` 组合：同名模型可在不同 Provider 下有不同 apiKey、baseUrl、capability 和 route config。ACP 通过独立 Agent backend 解析，不能用普通 Provider 的模型能力字段替代。

## 6. 限流、队列与状态

`RateLimitManager`（`src/main/provider/managers/rateLimitManager.ts:24-80`）默认关闭限流，启用时持久化 `enabled/qpsLimit`。`executeWithRateLimit`（`:122-190`）允许立即执行，否则把请求放入 Provider 队列并支持 Abort；队列处理按 `1/qpsLimit` 间隔依次释放（`:284-325`）。状态 API 返回 config、currentQps、queueLength、lastRequestTime（`:82-119`），排队和执行会发出 provider event。

`ProviderInstanceManager` 与 `ModelManager` 维护 Provider runtime 实例和模型启停状态；本次未发现根据失败率、成本或延迟在多个 Provider 之间自动选择的路由器。

## 7. 边界与未验证事项

- API key、OAuth token 和 baseUrl 属于 Provider 配置对象；本次未运行凭据存储、导入导出和数据库加密流程。
- Provider DB 是外部聚合 JSON 加本地默认值的双来源；未验证离线、隐私模式或版本升级时的最终合并结果。
- `apiType` 的 runtime strategy 覆盖多个渠道，但各渠道对 reasoning、tool、媒体和 embedding 的实际兼容性未逐一实测。
- 限流按 Provider 维护内存队列；未验证应用重启、Provider 删除、多个 session 竞争和跨进程并发。
- 未运行项目测试、构建或真实 API 请求；结论来自静态源码。

## 8. 关键源码索引

- Provider/ModelConfig 类型：`src/shared/types/provider.ts:74-106`、`:370-413`
- 默认渠道：`src/main/provider/defaults.ts:3-25`、`:209-344`、`:569-570`、`:978-1011`
- AI SDK Provider registry：`src/main/provider/providerRegistry.ts:50-80`、`:684-690`
- ProviderSettings 初始化/迁移：`src/main/provider/settings.ts:322-412`
- 有效模型配置与导入导出：`src/main/provider/settings.ts:1261-1399`
- Provider 基类模型目录：`src/main/provider/baseProvider.ts:31-320`
- AI SDK runtime：`src/main/provider/aiSdk/runtime.ts:1178-1350`、`:1357-1766`
- 原生/legacy stream：`src/main/provider/aiSdk/streamAdapter.ts:57-124`、`src/main/provider/aiSdk/toolProtocol.ts:38-150`
- Provider QPS 队列：`src/main/provider/managers/rateLimitManager.ts:24-190`、`:284-385`


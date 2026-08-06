# NextChat LLM 渠道管理调查笔记

> 调查对象：`E:\works\git\NextChat`（重点 `app/constant.ts`、`app/client/`、`app/store/access.ts`、`app/config/server.ts`、`app/api/`）
>
> 调查更新日期：2026-08-06
>
> 代码快照：`706a18b95b714ab29b2a4842d3b9ff4f887935d5`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 NextChat 仓库
>
> 调查范围：关注 Provider/模型目录、用户与服务端凭据、Web 代理和实际请求路由；不把 TTS/分享等外围 API 当作 LLM 渠道
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的渠道管理采用“Provider 枚举 + 协议 adapter + 客户端配置 store + Next.js 代理”的组合，而不是数据库化的渠道实体：

1. `ServiceProvider` 声明 OpenAI、Azure、Google、Anthropic、Baidu、ByteDance、Alibaba、Tencent、Moonshot、Stability、Iflytek、XAI、ChatGLM、DeepSeek、SiliconFlow 和 302.AI；`ClientApi` 再把内部 `ModelProvider` 映射到各个平台 adapter（`app/constant.ts:120-164`、`app/client/api.ts:136-183`）。
2. 所有聊天 adapter 共享 `LLMApi` 接口：`chat`、`speech`、`usage`、`models`。OpenAI/Azure 以兼容协议实现，其他渠道在 `app/client/platforms/` 中有独立请求格式；Stability 图片生成由 `app/store/sd.ts` 单独处理，不通过普通 `getClientApi`。
3. Web 模式默认把请求发往 Next.js `/api/...` 代理，桌面 App/导出模式根据 Provider 直接访问官方 endpoint。代理会做认证注入、Azure 路径调整、自定义模型限制和超时转发。
4. 用户 API key、endpoint、模型覆盖和 provider 选择存在 `useAccessStore`，通过统一的 IndexedDB 持久化。服务端环境变量通过 `/api/config` 暴露能力与模型控制项；服务端可从逗号分隔的 key 中随机选择一项。
5. 模型表以 `modelName@providerId` 区分同名模型，合并内置模型、服务端 `CUSTOM_MODELS` 和用户自定义模型。没有发现跨 Provider 自动 failover、健康熔断或基于成本/延迟的路由闭环。

## 1. Provider、ModelProvider 和 adapter

### 1.1 两层枚举

`ServiceProvider`（`app/constant.ts:120-137`）是配置和会话中保存的显示名称；`ModelProvider`（`app/constant.ts:148-164`）是 `ClientApi` 工厂使用的内部实现标识。`getClientApi(provider)`（`app/client/api.ts:368-398`）把前者映射到后者：

```text
Google -> GeminiProApi
Anthropic -> ClaudeApi
Baidu -> ErnieApi
ByteDance -> DoubaoApi
Alibaba -> QwenApi
Tencent -> HunyuanApi
Moonshot -> MoonshotApi
Iflytek -> SparkApi
DeepSeek -> DeepSeekApi
XAI -> XAIApi
ChatGLM -> ChatGLMApi
SiliconFlow -> SiliconflowApi
302.AI -> Ai302Api
default/OpenAI/Azure -> ChatGPTApi
```

`ClientApi` 的构造函数把所有 adapter 统一暴露为 `public llm: LLMApi`（`app/client/api.ts:108-183`）。Azure 不是独立的 `ClientApi` 类，而是在 OpenAI adapter 内根据 provider、模型表和路径选择 Azure endpoint。

### 1.2 Stability 的例外

`ServiceProvider.Stability` 存在于枚举，但 `getClientApi` 没有 Stability 分支；图片生成由 `app/store/sd.ts:58-135` 读取 Stability URL/key 并调用图片接口。这里的“渠道”与普通对话 Provider 有同名配置概念，但执行链是独立的。

## 2. 模型目录和自定义模型

### 2.1 内置目录

`DEFAULT_MODELS` 在 `app/constant.ts:746` 开始，以 provider 元数据包裹各平台模型，字段包括 `name`、`available`、`sorted` 和 `provider.id/providerName/providerType`。启动时 `Home.useLoadData` 还会通过当前 adapter 的 `models()` 拉取动态模型并合并到 config（`app/components/home.tsx:223-235`）。

### 2.2 `model@provider` 身份

`collectModelTable`（`app/utils/model.ts:51-135`）使用 `${model.name}@${provider.id}` 作为完整 key。这样同名模型可以同时存在于 OpenAI、Azure、Google 等渠道。UI 选择器也以 `model@providerName` 保存当前选择（`app/components/chat.tsx:682-714`）。

### 2.3 自定义模型语法

`CUSTOM_MODELS` 和用户 `customModels` 使用逗号分隔条目：

```text
model                       启用或新增模型
-model                      禁用模型
+model                      显式启用模型
model=display name         修改显示名
model@Provider=display     指定 provider 后修改
all / -all                 批量启用或禁用
```

解析逻辑在 `app/utils/model.ts:76-133`：先修改已有模型的 `available`/displayName，找不到时创建 `providerType: "custom"` 的虚拟 Provider。`useAllModels` 将服务端和用户字符串拼接后统一收集（`app/utils/hooks.ts:5-21`）。

## 3. 用户渠道配置

### 3.1 Access store

`useAccessStore` 的默认状态（`app/store/access.ts:65-154`）按 Provider 保存 URL、API key、API version/secret 等字段，典型包括：

- OpenAI：`openaiUrl`、`openaiApiKey`；
- Azure：`azureUrl`、`azureApiKey`、`azureApiVersion`；
- Google：`googleUrl`、`googleApiKey`、安全阈值；
- Anthropic、Baidu、ByteDance、Alibaba、Tencent、Moonshot、Iflytek、DeepSeek、XAI、ChatGLM、SiliconFlow、302.AI：各自 endpoint 与凭据；
- 服务端下发的 `customModels`、`defaultModel`、`visionModels`、`needCode`、`hideUserApiKey` 等能力。

Settings 页直接把输入值写回该 store，例如 OpenAI/Google key 和自定义模型在 `app/components/settings.tsx:722-778`、`864-907`、`1822-1915`。Store 通过 `createPersistStore` 持久化到客户端；源码未见凭据加密。

### 3.2 Web 与 App 的默认 endpoint

`app/store/access.ts:31-63` 根据 `getClientConfig().buildMode === "export"` 选择默认 URL：

- Web：默认是 `/api/openai`、`/api/google` 等 Next.js API path；
- App/export：默认是 Provider 官方 base URL。

用户启用 custom config 后，adapter 从 access store 读取 provider URL/key；否则使用编译配置和服务端下发的默认值。

## 4. 请求路由和认证

### 4.1 客户端请求

`getHeaders`（`app/client/api.ts:244-365`）根据当前 session 的 provider 选择 API key 和认证头：

- OpenAI/大多数兼容渠道使用 `Authorization: Bearer ...`；
- Azure 使用 `api-key`；
- Anthropic 使用 `x-api-key`；
- Google 使用 `x-goog-api-key`；
- Iflytek 把 key/secret 拼接；
- 没有用户 key 且启用了 access control 时，使用 `ACCESS_CODE_PREFIX + accessCode`。

OpenAI adapter 的聊天路径在 `app/client/platforms/openai.ts:186-305` 选择，Web 模式通过 `ApiPath.OpenAI` 进入 Next.js，App 模式直接走 `OpenaiPath`/自定义 base URL。Azure 额外把 deployment 和 `api-version` 放入路径（`app/client/platforms/openai.ts:270-305`）。

### 4.2 服务端认证和系统 key

`app/api/auth.ts:17-129` 解析 Authorization：

1. 以 `ACCESS_CODE_PREFIX` 区分 access code 和用户 API key；
2. `CODE` 通过 MD5 后与服务端允许集合比较；
3. `HIDE_USER_API_KEY` 可拒绝用户自带 key；
4. 用户没有 key 时，根据 `ModelProvider` 注入服务端系统 key 到请求头。

`app/config/server.ts:103-129` 的 `getApiKey` 支持逗号分隔 key，并在每次读取配置时随机选择一个。当前实现还把“使用第几个 key”和 key 值写入日志（`app/config/server.ts:121-126`），生产部署应注意日志泄密。

### 4.3 Next.js 代理

OpenAI/Azure 代理在 `app/api/common.ts:9-186`：

- 从请求路径恢复目标 provider path；
- 规范化 `BASE_URL`/`AZURE_URL`；
- 转发 Authorization、OpenAI-Organization 和请求 body；
- 读取 body 检查 `CUSTOM_MODELS` 是否禁止当前模型；
- 十分钟 abort 后原样返回流响应。

通用自定义插件/endpoint 代理在 `app/api/proxy.ts:4-89`：读取 `X-Base-URL` 和路径，过滤连接、cookie、origin 等请求头；对 OpenAI 官方 base URL 使用服务端 API key 覆盖 Authorization。插件因此可以在 Web 模式避免浏览器直接跨域访问。

## 5. 服务端模型控制项

`app/config/server.ts:20-30` 和 `132-277` 支持：

- `CUSTOM_MODELS`：增加、显示或禁用模型；
- `DEFAULT_MODEL`：新会话默认模型；
- `VISION_MODELS`：服务端声明视觉模型；
- `DISABLE_GPT4`：自动把 GPT-4 模型加入禁用列表并清空不合适的默认模型；
- `HIDE_USER_API_KEY`：隐藏/拒绝用户自带 key；
- Provider-specific URL/key 环境变量；
- `ENABLE_MCP`、Stability、Cloudflare KV 等外围能力。

Access store 的 `fetch()` 通过 `/api/config` 获取这些值并合并进客户端（`app/store/access.ts:252-283`）。服务端配置是能力和策略来源，客户端仍可在未被隐藏时修改自己的 URL、key 和 custom model 列表。

## 6. 渠道选择、重试和可观测性边界

当前聊天请求的路由由 session 中固定的 `model` + `providerName` 决定；没有发现：

- 跨 Provider 自动 failover；
- 失败后换 key 的重试策略；
- 渠道健康检查结果参与路由；
- 成本、延迟、配额或权重路由；
- 每个渠道独立的断路器、成功率和请求计量。

客户端有请求超时和 AbortController；工具循环有递归重发，但那是同一 Provider 的 tool loop，不是渠道 failover。`rg` 检索 `app/client`、`app/api`、`app/store` 未发现通用 retry/failover 实现。

## 7. 风险、边界和未验证事项

1. **客户端凭据持久化**：API key 与 endpoint 随 Access store 进入 IndexedDB/localStorage，源码未见加密或按设备隔离。
2. **服务端日志泄密**：`getApiKey` 当前日志包含随机选择的 key 值，部署时需要确认日志访问策略或在后续版本修正。
3. **自定义 endpoint 信任模型宽**：`X-Base-URL`/用户 URL 可改变请求目标；通用 proxy 只过滤部分头，不是 SSRF/endpoint allowlist。
4. **模型可用性是声明式的**：`available`、`CUSTOM_MODELS` 和 `VISION_MODELS` 主要控制 UI/代理策略，不代表真实 quota 或 API 健康。
5. **Provider 能力差异**：`LLMApi` 接口统一了方法名，但 streaming、vision、tool call、reasoning 参数在各 adapter 中并不等价；本次未逐一实测所有 Provider。
6. **Stability 分支独立**：普通渠道横向比较不应把 Stability 的图片生成调用当作同一对话 adapter。

## 8. 关键源码索引

- Provider/ModelProvider 枚举：`app/constant.ts:120-164`
- 内置模型目录：`app/constant.ts:746-805`
- LLM 接口与 ClientApi 工厂：`app/client/api.ts:54-183`
- Provider 映射：`app/client/api.ts:368-398`
- OpenAI/Azure 请求 adapter：`app/client/platforms/openai.ts:186-425`
- 模型聚合和 custom model 语法：`app/utils/model.ts:46-161`
- 所有模型 hook：`app/utils/hooks.ts:5-21`
- 用户渠道配置：`app/store/access.ts:65-154`、`252-303`
- 设置页渠道字段：`app/components/settings.tsx:722-778`、`1822-1915`
- 服务端环境变量和多 key：`app/config/server.ts:103-277`
- 认证和系统 key 注入：`app/api/auth.ts:27-129`
- OpenAI/Azure 代理：`app/api/common.ts:9-186`
- 通用自定义代理：`app/api/proxy.ts:4-89`
- Stability 独立链路：`app/store/sd.ts:58-135`

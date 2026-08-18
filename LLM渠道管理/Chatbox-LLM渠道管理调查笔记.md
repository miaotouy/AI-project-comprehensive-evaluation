# Chatbox LLM 渠道管理调查笔记

> 调查对象：`https://github.com/chatboxai/chatbox`
>
> 调查更新日期：2026-08-18
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：只读检查源码、测试与仓库文档；未修改目标仓库，也未启动应用进行界面或真实网络验证
>
> 调查范围：Provider/渠道数据模型、配置文件、桌面端与 Web 管理入口、虚拟 CLI、TUI、模型目录、凭据、协议适配、连接测试、重试与备份；移动端仅记录与本次渠道管理直接相关的共用界面边界
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 把渠道拆成两层：代码注册的内置 Provider，以及由用户设置创建的自定义 Provider 实例。内置 Provider 通过注册表提供默认配置和模型工厂；用户设置通过 `providers[providerId]` 保存每个 Provider 的运行配置，自定义 Provider 的身份信息另存于 `customProviders[]`。因此，同一个内置 ID 只有一个用户端点；若要配置多个 OpenAI 兼容中转，需要创建多个自定义 Provider ID。

渠道管理的完整入口是 renderer 中的 Provider 设置页。桌面端和 Web 构建共用该页面：可以查看内置与已创建的自定义渠道、创建自定义渠道、编辑配置、编辑模型、删除自定义渠道、从剪贴板或深链导入，以及按模型执行连接和能力测试。内置渠道没有删除入口；本次在 Provider schema、设置页和虚拟 CLI 中未找到渠道级启停、复制或单渠道导出操作。通用数据备份可以把整个 `settings` 导出为 ZIP 中的设置条目，再整体恢复，但它不是单渠道复制/导出 API。

配置文件和平台入口的边界如下：

| 入口 | 源码确认的能力 | 边界 |
|---|---|---|
| 桌面配置文件 | Electron Store 将 `settings` 写入 `<userData>/config.json`；可由应用自动复制为配置备份 | 文件是应用级配置，不是单独 Provider 文件；自动备份包含完整敏感字段 |
| Web | `settings` 通过 Web Platform 的 IndexedDB/localforage 存储；共用 Provider 设置页 | 没有桌面主进程文件或代理配置；本次未运行验证浏览器实际存储与下载行为 |
| 桌面/Web 设置页 | 查看、新增、编辑、模型管理、导入、删除自定义渠道、连接测试 | 视觉效果、保存时序和真实请求结果未运行验证 |
| 虚拟 CLI | 仅读取受限的普通设置；命令目录没有 Provider 管理命令 | `chatbox settings` 不读 Provider 凭据，也不支持设置修改 |
| TUI | 本次在仓库中未找到独立 TUI 入口或渠道管理实现 | 结论范围是当前源码搜索范围，不宣称项目所有历史版本均不存在 |

请求主链路是：会话保存 Provider ID 与模型 ID，`getModel()` 先查内置注册表，找不到时再查 `customProviders[]`，合并 Provider 默认设置、本地设置和共享 OAuth 凭据，富化模型元数据，解析有效凭据并创建协议模型类，最后经平台请求适配器发出请求。429 和 5xx 在同一模型实例内重试；没有客户端跨 Provider failover、Key 池或健康路由。

## 系统边界与总体调用链

### Provider、渠道、Endpoint、模型与凭据的定义

- **内置 Provider**：`defineProvider()` 注册的代码定义，包含 ID、名称、协议类型、默认 Host/Path、默认模型和 `createModel()` 工厂。它是系统能力注册项，同时对应一个设置 ID。
- **自定义 Provider**：`customProviders[]` 中的用户实例。创建时生成 `custom-provider-${uuid}`，拥有自己的名称、协议类型、图标和 URL 信息；同一协议可以创建多个实例。
- **渠道/Endpoint**：本笔记将一个 Provider ID 加上其 `providers[providerId]` 中的 Host、Path、凭据和模型列表视为一个可路由渠道。数据模型没有在一个 Provider ID 下保存多个 Endpoint 数组。
- **模型**：Provider 设置中的 `models[]` 条目，至少有 `modelId`，还可带 nickname、类型、能力、上下文窗口和最大输出等信息。
- **凭据**：Provider 设置中的 `apiKey`、OAuth credential、Azure 字段或 Bedrock AWS 字段。Header 主要由协议模型和 OAuth 包装器在请求时组装；未找到用户可编辑的通用 Header 字段。

主要链路如下：

```text
内置 definitions/* --defineProvider()--> Provider registry
customProviders[] ---------------------> 自定义 Provider 基础信息
providers[providerId] ------------------> Host / Path / Key / OAuth / models
SessionSettings { provider, modelId }
  -> getModel()
  -> 内置 definition 或 custom provider factory
  -> 合并默认设置、本地设置、共享 OAuth credential
  -> 模型目录合并与 models.dev 富化
  -> resolveEffectiveApiKey()
  -> AbstractAISDKModel / OpenAICompatible / 专用模型类
  -> platform request / proxy
```

内置注册表的副作用导入顺序也决定 Provider 列表顺序。当前 `src/shared/providers/index.ts` 导入的注册项包括 Chatbox AI、OpenAI、OpenAI Responses、Gemini、Claude、DeepSeek、Qwen、MiniMax、Moonshot、SiliconFlow、OpenRouter、Ollama、LM Studio、Azure、Groq、xAI、Mistral、Perplexity、Volcengine、ChatGLM、GitHub Copilot、Bedrock 和 Vercel AI Gateway 等；精确数量以该代码快照中的注册入口为准，仓库文档中的“30+”还包含其他服务或兼容 Provider 的口径。

## 1. Provider、渠道与 Endpoint 数据模型

### 内置与自定义的差异

内置 Provider 的定义由源码提供，设置页把 `SystemProviders()` 与用户设置合并后展示。修改内置 Provider 的 Host、Key 或模型列表会写入该内置 ID 的设置对象，不会创建新的内置实例。内置 Provider 的默认字段仍作为合并来源，用户保存的数组字段会替换默认数组，而不是逐项追加。

自定义 Provider 在新增时只先写入 `customProviders[]` 的基础信息，然后跳转到同一个详情页补充 Host、Path、Key 和模型。它不经过 `defineProvider()` 注册，而是在 `getModel()` 找不到内置 definition 时由 `createCustomProviderModel()` 按协议类型动态创建。当前手工新建支持四种模式：OpenAI Chat、OpenAI Responses、Claude 和 Google Gemini 兼容协议。

自定义 ID 必须不与任意内置 ID 冲突。导入时也会拒绝声明为自定义但使用内置 ID 的配置。该 ID 同时承担设置主键、运行时路由键和 OAuth 关联键的职责。

### 配置合并与迁移

`settingsStore` 用默认设置与持久化设置做深合并，数组采用持久化值替换默认数组，然后通过 `SettingsSchema` 解析。桌面端的 `settings`、`configs` 和配置版本走主进程文件存储；Web 端由 IndexedDB-backed Platform 存储。旧版本设置由 store 的版本迁移逻辑处理，此外还有独立的 legacy Provider 设置迁移模块。

运行时 Host、Path、认证和模型的主要优先级是：Provider 本地设置覆盖 definition 默认值；桌面 OAuth 在有效且启用时覆盖 API Key；本地模型列表优先进入结果，Provider API、后端 manifest 和 models.dev 再参与补充或富化。OAuth 模式对绑定官方端点的 Provider 会使用默认官方 Host，不允许拿官方 token 请求任意自定义中转地址。

## 2. 配置生命周期与管理入口

### 2.1 桌面端和 Web 设置页

桌面端与 Web 使用同一个 `src/renderer/routes/settings/provider/` 路由和组件。平台差异由 `platform` 适配器承担，Provider 表单本身没有分别实现一套桌面版和 Web 版。

| 操作 | 源码确认的实现 | 内置渠道 | 自定义渠道 |
|---|---|---|---|
| 查看 | Provider 列表合并系统定义、`customProviders[]` 和 `providers[id]`；详情页显示认证、Host、模型等 | 支持 | 支持 |
| 新增 | “Add”打开新增弹窗，生成 `custom-provider-${uuid}`，填写名称和 API Mode 后进入详情页 | 不适用；内置项由注册表提供 | 支持 |
| 编辑 | 详情页字段通过 `setProviderSettings()` 或 `setSettings()` 即时写入 store | 可编辑设置和模型；不能改变代码定义本身 | 可编辑名称、协议类型、Host、Path、代理选项、Key 和模型 |
| 复制 | 本次未在 Provider 组件、Provider schema 和配置工具中找到复制/克隆操作 | 未找到 | 未找到 |
| 启停 | ProviderSettingsSchema 没有 enabled 字段，详情页没有启停控件；`excludedModels` 是模型排除字段，不是渠道状态 | 未找到 | 未找到 |
| 删除 | 详情页只对 `isCustom` Provider 显示删除确认，并从 `customProviders[]` 移除后返回列表 | 不适用，未提供删除入口 | 支持 |
| 导入 | 剪贴板 JSON 或 `chatbox://provider/import?config=<base64>` 深链；弹窗确认后覆盖或新增 | 支持更新现有 `providers[id]` | 支持新增或覆盖 |
| 导出 | Provider 页面未找到单渠道导出；通用 Data Backup 可选择 Settings，将完整设置作为 ZIP 条目导出 | 只能随整个设置导出 | 只能随整个设置导出 |
| 连接测试 | 详情页先选模型，再复用 `getModel()` 和模型实例发送测试请求 | API Key/AWS 凭据满足条件时支持；OAuth 活跃时 API Key 检查按钮禁用 | 支持 |

表格中的“未找到”表示本次检查的当前源码范围内没有对应入口，不等于对未检查的外部脚本或历史版本作绝对否定。

### 2.2 新建渠道与已有渠道的可操作范围

新建流程只收集名称和 API Mode，随后与已有渠道共用详情页。因此，新渠道一旦写入基础信息，后续编辑范围与自定义已有渠道基本相同。已有自定义渠道可以改名、改协议类型、改 Host/Path、切换网络兼容代理、更新凭据和管理模型；内置渠道不能改名、改协议类型或删除，但可以修改允许暴露的设置字段。

已有渠道的导入行为有覆盖差异：导入 ID 已存在的内置 Provider 时只更新 `providers[id]`；导入 ID 已存在的自定义 Provider 时更新其基础信息并写入对应设置；全新自定义 ID 会同时追加 `customProviders[]` 和 `providers[id]`。导入的模型按 `modelId` 去重，且导入弹窗显示覆盖警告。

手工新建支持 Gemini 兼容模式，但当前 `provider-config.ts` 的导入 schema 只接受 `openai`、`openai-responses` 和 `anthropic` 三种自定义类型。本次静态代码确认了手工创建面与 JSON/深链导入面的协议覆盖不一致；这不是运行时 Gemini 模型类不存在，而是导入格式校验未覆盖该类型。

### 2.3 配置文件、导入、导出与恢复

桌面主进程初始化 Electron Store 时没有配置 `encryptionKey`。配置文件路径由 `app.getPath('userData')` 与 `config.json` 拼接得到，Store 中的 `settings` 包含 Provider 设置。主进程每约 10 分钟复制整个 `config.json` 到 `config-backup-*.json`，并按时间保留/清理；这些自动备份不是脱敏备份。

应用级 Data Backup 位于 General Settings，不是 Provider 页面。用户可以选择 Settings、API KEY & License、Chat History 和 My Copilots。选择 Settings 时，ZIP 的 `settings.json` 来自清洗后的设置；默认不包含 API Key、OAuth、AWS credential、Web Search Key 和 MCP 环境变量/Header，选择 API KEY & License 后才允许包含 Key。ZIP 导入会校验 manifest、条目大小和 checksum，设置条目存在时覆盖当前设置并在完成后重启或继续恢复流程。旧版 JSON 备份也有单独迁移路径。

Web 同样使用该通用备份页面，但导出结果通过浏览器下载或 Web Share；源码可确认下载/分享事件绑定，未运行验证不同浏览器的流式下载和权限行为。

深链导入只是 Base64 编码，不是加密。Electron 主进程把 `chatbox://provider/import` 转成设置页的 `import` 查询参数，renderer 解码后展示确认弹窗；若 URL 中带 API Key，凭据会存在 URL 文本和可能的系统 URL 记录中。

### 2.4 CLI 与 TUI

仓库中的 `chatbox_cli` 是模型工具可调用的受控应用内命令面，不是独立终端程序。命令域只有 `account`、`settings`、`chats` 和 `image`；`settings list/get` 只读取预先列出的主题、语言、字体、聊天显示等安全字段，并明确把设置修改引导到 Settings UI。Provider 凭据等 secret-bearing settings 不在 allowlist 中，命令目录也没有 Provider 查看、新增、编辑、复制、启停、删除、导入、导出或连接测试命令。

本次在仓库文件、package scripts、CLI 命令目录和源码搜索范围内未找到独立 TUI 或面向终端的渠道管理入口。因此 CLI/TUI 对渠道生命周期的结论分别是：虚拟 CLI **不适用/不支持写操作**；独立 TUI **本次未找到**。

## 3. 凭据、Header 与代理边界

Provider 设置 schema 支持单个 `apiKey`，没有 `apiKeys[]`、Key 权重或健康状态；OAuth credential 保存 access token、refresh token 和过期时间；Azure 使用 endpoint、deployment 和 API version 字段，Bedrock 使用 access key、secret key、session token 和 region。API Key 表单使用密码输入，OAuth 登录状态显示为已登录，但这属于 UI 脱敏/隐藏，不代表存储加密。

桌面端 API Key、OAuth token、Azure/AWS 字段最终作为普通 JSON 字段进入 Electron Store 的 `config.json`。OAuth 刷新成功后会写回设置；OpenAI 与 OpenAI Responses 可以共享 OAuth credential，但各自的 `activeAuthMode` 独立。Web 和 mobile 的 OAuth 请求解析会回退 API Key，OAuth IPC 和 callback/device-code 流程限定在 desktop。

协议模型负责组装请求 URL、协议请求体和 Header。OpenAI-compatible 模型通过统一模型类和 `apiRequest`/代理 fetch 发送；Claude、Gemini、OpenAI Responses 等由各自模型类或 AI SDK adapter 处理。Provider 设置没有通用自定义 Header 字段，因此本次未找到用户通过渠道管理页注入任意 Header 的能力。

代理有两层：全局代理由平台配置，部分自定义 OpenAI/Responses/Claude/Gemini 模型和 Ollama 读取 Provider 的 `useProxy`。不同 Provider 的模型类并不保证完全相同的代理路径。Web 平台的 `ensureProxyConfig()` 是空实现，浏览器的 CORS、代理和请求限制由 Web 环境承担；桌面端由主进程更新代理配置。

## 4. 模型目录与能力元数据

模型目录不是单一来源。设置页的合并逻辑依次考虑用户保存的模型、Chatbox 后端 manifest、Provider 的模型列表 API 和 models.dev registry。Provider API 成功时可以发现近期发布的新模型；Provider API 为空时，models.dev 只提供 Provider definition 策展模型的 fallback，避免直接暴露未经验证的完整目录。

模型条目可区分 chat、embedding、rerank 和 image，并带 vision、reasoning、tool_use 等能力、上下文窗口和最大输出。models.dev 在 Provider 映射成功时对能力、上下文和最大输出进行富化，nickname 和已有类型只在缺失时补齐。价格、family、发布日期和状态存在于 registry/snapshot 层，但当前 `ProviderModelInfo` 没有完整承载这些字段，源码中也未找到基于价格的账单计算或成本路由。

Provider 详情页的模型操作包括：手工新增、编辑、删除、恢复默认模型列表，以及 Fetch 远程模型列表后在弹窗中逐项加入或移除。模型列表项本身没有复制按钮；渠道级复制也未找到。连接测试成功时，若视觉或工具调用测试通过，会把对应能力追加到该模型的本地能力列表，但 models.dev 富化仍可能在运行时覆盖事实能力字段。

## 5. Adapter、协议与请求组装

内置 Provider 的 `ProviderDefinition.type` 区分 OpenAI、OpenAI Responses、Claude 和 Gemini 等协议族，并通过 `createModel()` 选择模型实现。用户自定义 Provider 的 `type` 由设置页选择，运行时工厂按类型分发到 Custom OpenAI、Custom OpenAI Responses、Custom Claude 或 Custom Gemini 模型类。

Host 和 Path 在进入模型类前按协议归一化。OpenAI Chat 和 Responses 有独立的 Host/Path 归一化函数；Claude、Gemini 和 Azure 有各自的路径规则。自定义 OpenAI Host 的 scheme 会被归一化，必要时补默认路径；这只解决 URL 解析，不会替用户验证 endpoint 是否可用。

上游通用上下文由会话的 Provider/Model 选择和全局/会话生成设置交给 `getModel()`，再由模型类把统一消息转换成目标协议。当前调查不展开历史消息、system prompt、工具和附件的完整构建，这些属于相邻的对话请求与上下文类别；本类目只确认渠道选择、凭据和协议适配的交接点。

## 6. 运行时选择、绑定与路由

会话设置保存 `{ provider, modelId }`。新会话复制全局默认，之后全局默认的变化不会改写已有会话；会话内切换 Provider/Model 会把组合写回当前会话。`getModel()` 按 Provider ID 查找，不会因为模型名相同而跨 Provider 搜索。

聊天、命名、搜索词构造、OCR、Embedding 和 Rerank 等用途分别保存自己的默认 Provider/Model 二元组。收藏模型也保存 Provider 与模型二元组，因此同名模型在不同自定义渠道中不会覆盖。路由依据是显式 Provider ID、模型 ID 和对应设置，不是模型语义、成本、延迟或健康分数。

## 7. 多 Key、限流、重试与故障转移

本次源码检查未找到 Provider 内部多 Key 池、Key 轮询、Key 冷却、熔断、健康评分或持久化健康状态。每个 Provider 设置只有单个 API Key；OAuth 是另一种认证模式，不是多 Key 池。

聊天流式和非流式请求由 `AbstractAISDKModel` 外层重试包装器处理：429 与 500-599 可按指数退避重试，最多 5 次，初始等待约 1 秒，AI SDK 内层通用 retry 被设为 0，避免重复叠加。网络错误默认不自动重试，因为连接断开不能证明服务端没有处理计费请求；图片等明确计费操作也禁用网络级自动重试。

流中途已经产生内容的错误不会静默重试，以避免重复回复或重复计费；在首个内容之前到达的普通 API 错误仍可能进入 HTTP 状态重试。所有这些重试都复用同一个 Provider、Host/Path、凭据和 modelId。没有客户端跨 Provider、跨模型或跨 Key failover。Anthropic 上游返回的 fallback 内容块是服务端行为，不是 Chatbox 的渠道路由策略。

## 8. 连接检测、日志与可观测性

Provider 设置页的 Check 操作要求 API Key 和至少一个模型，AWS Bedrock 还要求 access key 和 secret key；OAuth 活跃时 API Key 检查按钮禁用。用户选择模型后，`testModelCapabilities()` 调用与真实运行相同的 `getModel()` 入口创建模型实例，并依次执行：

1. 基础文本请求，内容为简短的 `Hi`；
2. 若基础请求成功，发送带一张内置 1×1 图片的视觉请求；
3. 若基础请求成功，发送带天气工具定义的工具调用请求。

测试结果在弹窗中区分文本、视觉和工具调用；视觉或工具测试成功时会把能力追加到模型本地配置。源码确认测试复用模型创建和请求链路，但未运行验证各协议的实际 HTTP 请求、计费行为、流式处理或 OAuth 回调。

模型目录 Fetch 不是连接测试：它刷新 models.dev（若有映射）并合并模型目录，可能只执行列表请求，不代表聊天 POST 成功。请求错误会通过模型错误归一化和 UI 状态回调显示；本次未找到 Provider 管理页上的按渠道请求日志、成本统计、延迟面板或健康历史。应用有通用日志和设置导出能力，但不应据此推断存在专用 Provider 可观测性。

## 9. 设计取舍与已确认边界

- 注册表把内置 Provider 的 ID、协议、默认设置和模型工厂集中到一个 definition，设置页和运行时使用同一份注册信息；自定义 Provider 以设置数据动态创建，支持同协议多实例。
- Provider ID 既是设置主键又是运行时路由键，因而禁止内置/自定义 ID 冲突，也没有在同一个内置 ID 下维护多 Endpoint 的结构。
- 设置页直接更新 Zustand 持久化 store，未设置单独的保存按钮或提交事务；静态代码只能确认事件绑定和写入调用，不能确认真实存储成功时序。
- 模型目录采用本地配置、Provider API、后端 manifest 和 models.dev 的合并，以兼顾用户自定义模型和远端发现；能力富化不是动态试调用自动探测的结果。
- 连接检查覆盖文本、视觉和工具调用，但它是一次主动测试请求，不是持续健康探针，也不会建立跨渠道 failover。
- 安全边界不一致：用户主动导出的通用备份默认清除 Provider 凭据，桌面自动配置备份则直接复制完整配置；Provider 深链导入的 Base64 也不提供加密。

## 10. 未验证事项

1. 未启动桌面、Web 或移动端，未实测设置页保存、删除后的引用行为、浏览器 IndexedDB、CORS、下载、Web Share、代理和 OAuth 回调。
2. 未对任一实际 Provider 执行真实 API 调用，因此无法确认不同服务商的 Host/Path 归一化、错误映射、计费和流式细节。
3. 未找到独立 TUI；该结论仅覆盖当前仓库源码、package scripts、虚拟 CLI 命令目录和相关命名搜索范围。
4. 未找到 Provider 复制、渠道级启停、渠道级导出和通用自定义 Header 的当前入口；通用设置备份能整体携带渠道配置，但不等同于这些单渠道操作。
5. Electron Store 未配置应用层 `encryptionKey`；本次未检查操作系统对 userData 目录的账户 ACL、磁盘加密或备份文件访问权限。
6. Chatbox AI 服务端的供应商冗余、限流、额度和故障转移不在本仓库中；客户端的单一 Provider 表示不能推断服务端内部没有容灾。

## 11. 关键源码索引

- Provider 注册与运行时路由：[`src/shared/providers/registry.ts`](../../chatbox/src/shared/providers/registry.ts)、[`src/shared/providers/index.ts`](../../chatbox/src/shared/providers/index.ts)、[`src/shared/providers/utils.ts`](../../chatbox/src/shared/providers/utils.ts)
- Provider 与设置 schema：[`src/shared/types/settings.ts`](../../chatbox/src/shared/types/settings.ts)、[`src/shared/types/provider.ts`](../../chatbox/src/shared/types/provider.ts)
- 设置持久化与 Provider 局部更新：[`src/renderer/stores/settingsStore.ts`](../../chatbox/src/renderer/stores/settingsStore.ts)、[`src/renderer/stores/providerSettings.ts`](../../chatbox/src/renderer/stores/providerSettings.ts)
- Provider 列表与新增/导入入口：[`src/renderer/routes/settings/provider/route.tsx`](../../chatbox/src/renderer/routes/settings/provider/route.tsx)、[`src/renderer/components/settings/provider/ProviderList.tsx`](../../chatbox/src/renderer/components/settings/provider/ProviderList.tsx)、[`src/renderer/components/settings/provider/AddProviderModal.tsx`](../../chatbox/src/renderer/components/settings/provider/AddProviderModal.tsx)、[`src/renderer/components/settings/provider/ImportProviderModal.tsx`](../../chatbox/src/renderer/components/settings/provider/ImportProviderModal.tsx)
- Provider 详情、模型管理、删除和连接测试：[`src/renderer/routes/settings/provider/$providerId.tsx`](../../chatbox/src/renderer/routes/settings/provider/$providerId.tsx)、[`src/renderer/components/ModelList.tsx`](../../chatbox/src/renderer/components/ModelList.tsx)、[`src/renderer/utils/model-tester.ts`](../../chatbox/src/renderer/utils/model-tester.ts)
- JSON/深链导入：[`src/renderer/utils/provider-config.ts`](../../chatbox/src/renderer/utils/provider-config.ts)、[`src/renderer/components/settings/provider/importProviderState.ts`](../../chatbox/src/renderer/components/settings/provider/importProviderState.ts)、[`src/main/deeplinks.ts`](../../chatbox/src/main/deeplinks.ts)
- 桌面配置文件和自动备份：[`src/main/store-node.ts`](../../chatbox/src/main/store-node.ts)、[`src/renderer/platform/desktop_platform.ts`](../../chatbox/src/renderer/platform/desktop_platform.ts)
- Web 存储和平台边界：[`src/renderer/platform/web_platform.ts`](../../chatbox/src/renderer/platform/web_platform.ts)、[`src/renderer/platform/index.ts`](../../chatbox/src/renderer/platform/index.ts)
- 通用备份脱敏、导出和导入：[`src/shared/utils/backup.ts`](../../chatbox/src/shared/utils/backup.ts)、[`src/renderer/routes/settings/general.tsx`](../../chatbox/src/renderer/routes/settings/general.tsx)、[`src/renderer/packages/backup/export-backup.ts`](../../chatbox/src/renderer/packages/backup/export-backup.ts)、[`src/renderer/packages/backup/import-backup.ts`](../../chatbox/src/renderer/packages/backup/import-backup.ts)
- 虚拟 CLI：[`docs/technical/chatbox-virtual-cli.md`](../../chatbox/docs/technical/chatbox-virtual-cli.md)、[`src/renderer/packages/chatbox-cli/catalog.ts`](../../chatbox/src/renderer/packages/chatbox-cli/catalog.ts)、[`src/renderer/packages/chatbox-cli/settings.ts`](../../chatbox/src/renderer/packages/chatbox-cli/settings.ts)
- Provider 架构与模型目录文档：[`docs/technical/ai-providers.md`](../../chatbox/docs/technical/ai-providers.md)、[`docs/adding-new-provider.md`](../../chatbox/docs/adding-new-provider.md)

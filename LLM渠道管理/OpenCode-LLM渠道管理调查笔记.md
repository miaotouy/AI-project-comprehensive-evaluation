# OpenCode LLM 渠道管理调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：只读源码静态梳理 Integration/Credential/Provider 三类对象、认证方法、模型目录、协议实现与请求链路；未运行构建与真实请求
>
> 调查范围：渠道与凭据数据模型、连接与认证流程、模型目录、协议适配与请求组装、运行时路由、多凭据/重试/失败转移、管理入口与可观测性；不覆盖 opencode zen 控制台前端
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 2.x 把"渠道"拆成三层：Integration 是渠道定义与可用认证方法（key、OAuth、外部凭据、命令行、环境变量），Credential 是落库的认证材料（可按渠道保存多份并选出 active 一份），Provider 是运行时聚合出的可路由模型目录。凭据从旧版 `auth.json` 迁移进 SQLite `credential` 表，启动时有一次导入迁移。

模型请求不再依赖 AI SDK：`@opencode/ai` 直接实现各家协议（chat/messages/responses/images/speech/transcription 等），Core 只负责把会话上下文转成请求并消费统一 LLM 事件。模型目录仍来自远端 models.dev 快照（磁盘缓存 + 构建期快照 + 网络，5 分钟 TTL）。

## 总体调用链

```text
渠道定义与认证方法（Integration）
  -> 连接流程：key / OAuth attempt / 命令行 attempt / 外部凭据 / 环境变量
  -> Credential 落库并设为 active（credential 表）
  -> Provider 目录聚合（models.dev + 各 provider 插件）
  -> 会话/Agent 指定模型引用（provider/model[/variant]）
  -> session/runner/model.ts 解析 -> session/model-request.ts 组装
  -> @opencode/ai 协议实现发起流式请求
  -> LLM 事件 -> durable 会话事件 -> usage/cost 累加
```

## 1. 数据模型

- **Integration**（`packages/schema/src/integration.ts:74-100`）：id、名称、metadata、认证方法列表、连接列表。方法是带类型的联合：OAuth（表单 + 授权跳转）、命令行（可执行命令 + 轮询状态）、API Key（表单）、External（引用外部管理的凭据）、Env（环境变量名列表）。
- **连接尝试**：OAuth 与命令行各有 attempt 对象，带创建/过期时间与 pending/complete/failed/expired 状态；OAuth 还区分自动与验证码两种模式。
- **Credential**（`packages/schema/src/credential.ts`）：id、所属渠道、标签、值、连接器/方法 id、active 标记。值有三种形态：OAuth（refresh/access/expires/metadata）、Key（密钥字符串）、External（只存方法 id 与 metadata，密钥由外部管理）。
- **Provider 与模型**：Provider 由目录与插件聚合得出，模型带成本、上下文与输出限额、能力、状态等元数据；模型引用形如 `provider/model`，可带变体（`provider/model/variant`）。
- **存储**：凭据在 SQLite 的 `credential` 表（`packages/core/src/credential/sql.ts`）；旧版 `auth.json` 经数据库迁移脚本一次性导入（`packages/core/src/database/migration/` 下的 legacy credentials 迁移）。

## 2. 连接、认证与凭据生命周期

- **API Key**：客户端提交 key 到渠道的 key 连接端点，服务端保存为 Credential 并激活。
- **OAuth**：服务端创建 attempt 返回授权链接与说明，客户端轮询状态；完成后写入 OAuth 凭据（含过期时间），可取消或等待过期。
- **命令行**：部分渠道通过本地命令完成登录（如云厂商 CLI），服务端启动命令并轮询其状态。
- **外部凭据**：只记录引用，实际密钥与续期由外部系统负责，避免把短期令牌复制进库。
- **环境变量**：渠道可声明从哪些环境变量读取密钥，运行时探测命中即视为已连接。
- **多凭据**：同一渠道可保存多份凭据，通过激活接口切换当前使用的一份；切换发布会话无关的凭据变更事件供客户端刷新。
- **断开**：删除凭据或删除渠道连接；删除后 Provider 目录中该渠道的模型不再可用。

## 3. 模型目录与能力元数据

- **models.dev 快照**：`packages/core/src/models-dev.ts` 从 `https://models.opencode.ai` 拉取目录，磁盘缓存，TTL 5 分钟并按该间隔定时刷新；网络不可用时可回退到构建期快照（`models-dev/snapshot.txt`）。
- **Provider 插件**：每个厂商在 `packages/core/src/plugin/provider/` 有对应插件，负责凭据注入、模型覆盖、请求修正与特殊目录（本地 Ollama、LM Studio、vLLM、自定义 OpenAI 兼容端点等）。
- **能力面**：模型元数据包含成本分档、上下文/输出限额、文本/图片/音频等能力与状态；协议层据此决定请求形态。
- **默认模型**：会话自己的模型优先，其次 Agent 绑定，最后取默认模型；Provider 列表接口返回默认与已连接信息供客户端使用。

## 4. 协议适配与请求链路

- **协议实现**：`packages/ai/src/providers/` 按厂商提供 `chat`/`messages`/`responses`/`images`/`decisions`/`speech`/`transcription` 等入口，底层由 `packages/ai/src/protocols/` 的具体协议编解码器实现（如 OpenAI chat/responses、Anthropic messages、Gemini、Bedrock Converse、Cohere chat 等）。
- **统一入口**：`@opencode/ai` 暴露 `generate`、`stream`、`loop`、`compact` 等函数（`packages/ai/src/llm.ts`），Core 通过 `LLMClient` 调用并消费统一事件。
- **请求组装**：`packages/core/src/session/model-request.ts` 把系统提示、历史、工具定义与输出上限转成协议请求；`model-transport.ts` 处理传输与错误归一。
- **特殊适配**：prompt caching、思考/推理参数、上下文上限修正、缓存 key 等由 Provider 插件按厂商注入。
- **usage 与成本**：`packages/core/src/session/usage.ts` 以模型成本表计算 token 费用并累加进会话统计，同时发布 usage 事件。

## 5. 管理入口

| 入口 | 查看 | 连接/编辑 | 断开/删除 | 备注 |
|---|---|---|---|---|
| HTTP | 渠道列表、渠道详情、凭据列表、模型列表 | 连接 key/OAuth/命令行/外部凭据，凭据创建与激活 | 删除凭据、取消授权尝试 | `packages/protocol/src/groups/{integration,credential,provider,model}.ts` |
| App | 设置页与连接对话框列出渠道、方法与状态 | 表单连接、OAuth 等待、自定义渠道接入 | 断开与移除凭据 | `packages/app/src/providers/{catalog,connect}/`、`settings/` |
| CLI | `auth list`、`models` | `auth login`、`auth import`、`auth export`、`auth switch` | `auth logout` | `packages/cli/src/commands/handlers/auth/`、`models.ts` |
| TUI | 模型选择对话框显示已连接渠道 | 连接流程复用 HTTP 端点 | 本次未找到独立的 TUI 凭据管理界面 | `packages/tui/src/component/dialog-model.tsx`、`use-connected.tsx` |
| 桌面 | 复用 App 页面 | 复用 App 连接流程 | 复用 App | Electron 只承担部署与服务连接 |

## 6. 多凭据、限流、重试与失败转移

- **多凭据**：同一渠道可存多份并可切换活动凭据，因此"多 Key"以多凭据形式存在；未找到按请求轮询或负载均衡多凭据的实现。
- **重试**：`packages/core/src/session/runner/retry.ts` 依据错误类型与尝试次数决定是否重试及退避，重试状态写入 assistant 消息。
- **上下文溢出**：溢出错误触发压缩后重跑，而不是跨模型切换。
- **失败转移**：本次未找到跨 Provider 自动切换；模型不存在直接报错并给出候选建议。
- **限流信息**：错误归一化会保留状态码与重试提示，客户端据此显示等待。

## 7. 可观测性与安全边界

- **用量**：会话表保存成本与五类 token 计数，usage 事件供客户端展示。
- **日志与脱敏**：请求日志只记渠道与模型标识；CLI 保留 `debug redact` 处理器。
- **凭据保护**：凭据存 SQLite，文件权限与数据目录隔离是主要保护；本次未找到系统 keyring 集成。
- **浏览器不直连模型服务**：OAuth 授权由服务端发起，浏览器只打开授权链接并等待服务端轮询结果。

## 8. 设计取舍与已确认边界

- **三层拆分**（Integration / Credential / Provider）让"渠道可发现、凭据可切换、模型可路由"彼此独立，代价是连接状态要跨三层聚合。
- **原生协议实现**替代 AI SDK 后，厂商差异集中在 `packages/ai/src/providers/` 与 `protocols/`，升级与排障都在仓库内完成。
- **凭据可多份但单活**：支持多账号并存，但同一时刻每个渠道只有一份生效。
- **边界**：本次未找到请求级多凭据负载均衡、跨渠道自动故障转移、系统级密钥库接入、保存后的通用连接测试。

## 9. 未验证事项

1. 未运行真实认证与请求：OAuth、命令行登录、外部凭据续期均未实测。
2. 各厂商协议实现的请求头、流式解码与错误映射未逐项验证。
3. models.dev 拉取失败时构建期快照的实际覆盖度未验证。
4. 多凭据切换在并发会话中的时序未实测。
5. 桌面端与 TUI 的模型选择在断连/重连场景的行为未验证。

## 10. 关键源码索引

- `packages/schema/src/integration.ts`、`credential.ts`：渠道与凭据契约
- `packages/core/src/integration.ts`、`credential.ts`：服务实现
- `packages/core/src/credential/sql.ts`：凭据表
- `packages/core/src/plugin/provider/`：各厂商 Provider 插件
- `packages/core/src/models-dev.ts`：模型目录
- `packages/ai/src/providers/`、`packages/ai/src/protocols/`：协议与厂商实现
- `packages/ai/src/llm.ts`：统一请求入口
- `packages/core/src/session/{model-request.ts,model-transport.ts,usage.ts}`：请求组装与用量
- `packages/core/src/session/runner/retry.ts`：重试策略
- `packages/protocol/src/groups/{integration,credential,provider,model}.ts`：HTTP 契约
- `packages/app/src/providers/`：客户端连接与目录
- `packages/cli/src/commands/handlers/auth/`：CLI 凭据管理

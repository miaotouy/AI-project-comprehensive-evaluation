# VCPMobile Agent 角色配置调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`cecdbe432feda57821938bba7625a272113d21c1`（分支：`main`）
>
> 调查方式：只读静态源码核对，覆盖 Agent SQLite 服务、创建/编辑界面及请求装配；未运行移动端和同步服务
>
> 调查范围：单 Agent 的配置、存储、绑定和请求生效链；群组编排、会话历史与 Tavern 规则细节留给相邻类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 的角色实体是 SQLite `agents` 表中的 Agent，不是短生命周期的会话预设。唯一标识是由名称可用字符和创建时间组成的 `agent_id`；新建 Agent 同时获得一个锁定的“主要对话”话题。角色配置包含名称、双层系统提示词、模型与生成参数，头像则以独立资产记录关联。没有角色版本号、角色卡导入/导出、Provider 绑定、知识库/记忆/工具开关或子 Agent 字段。

最重要的覆盖规则是：移动端专用提示词非空时优先，空时才退回同步来的系统提示词。模型和参数完全是 Agent 级别，网关凭据仍是全局设置。每次发送会重新读取该 Agent 配置、装配历史和 Tavern 上下文，再发到 VCP 网关；历史消息不携带角色快照。

## 总体生效链路

```text
创建/同步的 agents 表记录
  -> AgentConfigState 缓存与按 Agent 互斥读取
  -> 当前会话选中 agent_id
  -> 发送前读取配置和消息历史
  -> mobile_system_prompt 非空则覆盖 system_prompt
  -> 上下文装配器 + Agent 模型参数
  -> VCP 请求
```

`handle_agent_chat_message` 在每次请求时读取完整配置，先决定有效提示词，再将它交给上下文装配器；模型参数与 `agentId/topicId/agentName` 一同进入请求载荷。`src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:59-139`。

## 1. 数据模型、存储与删除

`AgentConfig` 定义了 ID、名称、同步系统提示词、仅本机的移动系统提示词、模型、温度、上下文/输出 token 限制、流式开关和 temperature 是否入请求；读取时还派生头像主色和该 Agent 的话题列表。`src-tauri/src/vcp_modules/agent/agent_types.rs:8-51`，`src-tauri/src/vcp_modules/agent/agent_service.rs:136-191`。

配置通过事务 upsert 到 `agents` 表，并计算同步哈希；头像存于独立的 `avatars` 表。服务为每个 Agent 使用互斥锁与缓存代际，避免并发读写回填过期对象。删除采用软删除，并级联软删除该 Agent 的话题、消息和头像，同时清理活动生成记录。`src-tauri/src/vcp_modules/agent/agent_service.rs:328-476,479-581`。

前端可读配置接口会清空同步系统提示词；保存时服务端会从缓存或数据库补回该字段，防止移动端编辑界面将其擦除。这意味着移动端设置页实际编辑的是本机覆盖提示词，而不是完整同步提示词。`src-tauri/src/vcp_modules/agent/agent_service.rs:93-109,201-228`，`src/features/agent/AgentSettingsView.vue:279-292`。

## 2. 创建、选择与会话绑定

创建入口只要求用户填写名称。默认配置创建一个带提示词的 Agent、一个主要话题和默认模型/参数，然后在同一事务写入。创建 UI 随后选择这个 Agent、加载其话题并打开设置页。`src-tauri/src/vcp_modules/agent/agent_service.rs:584-688`，`src/features/agent/AgentsCreator.vue:16-52`。

角色与对话的绑定粒度是 Agent 拥有多个话题，而不是角色快照写进每条消息。发送输入是当前 `ownerId/topicId`，服务端通过 `agent_id` 获取实时配置；因此后续发送会使用更新后的配置，但本次没有验证历史重放或重新生成时是否保存了完整的角色/参数快照。`src/core/stores/chatHistoryStore.ts:354-398`，`src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:53-113`。

## 3. 提示词、模型与生成参数

提示词优先级只有两层：`mobile_system_prompt` 优先于 `system_prompt`。有效提示词先交给 `orchestrate_chat_context`，与消息历史和 Tavern 规则共同形成请求消息；Tavern 规则的具体字段和排序属于对话上下文类目。`src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:87-124`。

每个 Agent 可选一个网关返回的模型，并设置 token 上限、流式和 temperature；关闭 `use_temperature` 时 temperature 不会进入请求。设置界面在关闭时按变更保存，模型选择器复用全局模型目录。`src/features/agent/AgentSettingsView.vue:111-185,288-381`，`src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs:115-124`。

## 4. 资产、外部能力与兼容边界

头像可在移动端选择、裁切并保存，随后由 Agent ID 关联；名称和模型会同步更新侧边栏的轻量列表。`src/features/agent/AgentSettingsView.vue:67-109`，`src/core/stores/assistant.ts:226-253,284-306`。

本次检查 Agent 配置结构和设置界面，未找到工具、MCP、Skill、知识库、长期记忆、世界书、开场白、快捷回复、变量字典或 Provider/Endpoint 字段。工具和检索可以由远端 VCP 生态提供，但并不由该 Agent 配置授权。也未找到角色导入、导出、复制、版本历史或冲突合并入口。

## 5. 未验证事项

- 未运行 SQLite 同步流程，未验证手机专用提示词在跨端同步冲突中的实际结果。
- 未连接网关，未验证 Agent 选择后模型参数是否被远端完整接受。
- 群组配置存在独立实现，本笔记未把它与单 Agent 角色字段混为一谈。

## 关键源码索引

- `src-tauri/src/vcp_modules/agent/agent_types.rs`：Agent 配置契约和默认值。
- `src-tauri/src/vcp_modules/agent/agent_service.rs`：读取、写入、创建、删除、缓存和同步哈希。
- `src-tauri/src/vcp_modules/agent/agent_chat_application_service.rs`：角色配置进入实际请求的主链。
- `src/features/agent/AgentSettingsView.vue`：移动端可编辑字段与保存时机。

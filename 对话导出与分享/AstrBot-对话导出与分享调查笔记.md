# AstrBot 对话导出与分享调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`8ea8ce613a0bee4ddb48b21490afe23418277c75`（分支：`master`）
>
> 调查方式：静态阅读 dashboard 对话 API、服务层、OpenAPI 前端调用与全量备份导出实现；未启动 AstrBot、未发起已鉴权请求或导出文件
>
> 调查范围：Dashboard 批量会话 JSONL 导出主链及其内容口径、鉴权和交付语义；明确区分全量备份 ZIP；不覆盖消息现场复制、图片/PDF/HTML 生成、远端公开分享和导入恢复
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 在 Dashboard 提供 E1 数据交换型的批量会话导出：经 `POST /api/v1/conversations/export` 提交一组 UMO 用户标识与会话 ID，服务逐项重新读取持久化会话历史，生成一行一会话的 UTF-8 JSONL，并作为下载响应交付。导出源不是当前聊天页面 DOM、模型请求 Payload 或平台原始消息事件，而是 Conversation Manager 保存的 `conversation.history` JSON；每条记录同时携带会话、平台、角色与创建/更新时间元数据（`astrbot/dashboard/services/conversation_service.py:184-243`）。

此链路按会话粒度工作，不提供单消息、范围、分支或字段开关。成功项目按请求顺序写入，单项读取或 JSON 解析失败会记入内部失败列表并跳过；只要至少一项成功，接口仍返回文件，因此调用方不会在响应中取得部分失败明细。前端 API 将响应作为 Blob 接收（`dashboard/src/api/v1.ts:1759-1764`）。

本次未找到对话 JSONL 的导入、预览编辑、图片或文档排版、剪贴板交付、持久化生成历史、分享 URL、访问撤销或敏感字段过滤。仓库另有包含数据库、附件、插件和配置的全量备份 ZIP，属于迁移/备份通道，不能与面向会话交换的 JSONL 混同（`astrbot/core/backup/exporter.py:39-104`）。

## 系统边界与完整主链

```text
Dashboard 选定多个会话（user_id + cid）
  -> ConversationExportRequest
  -> POST /api/v1/conversations/export（data scope 鉴权）
  -> ConversationService 逐项从 Conversation Manager 读取持久化会话
  -> 解析 conversation.history 并组装 JSONL record
  -> 内存 BytesIO 编码为 UTF-8
  -> StreamingResponse + Content-Disposition 下载文件
  -> Dashboard 以 Blob 接收
```

新版路由由 API v1 聚合器挂载，旧 Dashboard 路由也复用同一服务导出函数；两者的鉴权依赖不同，但内容生产路径相同（`astrbot/dashboard/api/router.py:37-59`；`astrbot/dashboard/api/conversations.py:63-84,139-145,287-293`）。

## 1. 入口、导出源与内容口径

导出请求的 schema 只接受 `conversations: list[ConversationRef]`，其中每项必须包含 `user_id` 和 `cid`，没有格式、范围或包含字段参数（`astrbot/dashboard/schemas.py:401-424`）。v1 入口要求 data scope；因此下载不是匿名公开链接，而是一次受 Dashboard 权限保护的请求（`astrbot/dashboard/api/conversations.py:113-145`）。

服务按请求数组顺序查询 Conversation Manager。每条成功记录的 `content` 来自将 `conversation.history` 反序列化后的对象，并附带 `cid`、`user_id`、`platform_id`、标题、`persona_id` 与时间字段。该口径保留持久化历史中已有的结构和内容，但服务不解释或筛选其中的 system、reasoning、工具、错误、附件引用或平台专有字段（`conversation_service.py:184-225`）。

JSONL 的会话顺序即调用方提供的引用顺序；单一会话内部消息顺序由已保存的 `conversation.history` 决定，导出层不重排。AstrBot 的会话模型在本次范围内呈现为线性 history JSON，未在此导出实现中找到分支树字段或活动分支选择。

## 2. 格式、附件与往返能力

交付物 MIME 类型为 `application/jsonl`，文件名固定前缀 `astrbot_conversations_export_` 加本地时间戳，正文由 JSON 对象以换行连接构成；服务使用 `ensure_ascii=False`，可保留 Unicode 文本而不转义为 ASCII（`conversation_service.py:19-24,213-243`）。文件没有 schema 名称、格式版本、校验和、导出请求元数据或逐行失败标记。

附件是否可离线使用取决于历史内容中的既有表示。导出器没有复制附件文件、下载远端 URL、打包资源或重写本地路径的逻辑；因此 JSONL 本身是结构化文本而非自包含交付物。项目全量备份器才会处理附件、知识库多媒体、配置和插件目录，但该 ZIP 用于整体数据恢复，不是本 JSONL 的伴随资源包（`astrbot/core/backup/exporter.py:39-55`）。

本次在 dashboard 对话 API、schema 和服务目录内未找到 JSONL 导入路由或消费者，故不能把该格式称为已确认的往返格式。服务的 `update_history` 允许已授权调用方写入 history，但它接收指定会话的 JSON 数据，未构成对导出 JSONL 的解析、验证和重建闭环（`conversation_service.py:159-182,332-344`）。

## 3. 分享稿、交付与访问语义

该能力直接从存储记录生成下载流，没有独立分享稿对象、编辑器、预览 DOM、主题或水印配置。Dashboard TypeScript 封装只将 HTTP 响应声明为 Blob；下载按钮、浏览器保存行为和用户可见错误反馈属于前端页面层，本次没有追踪到对应调用表面（`dashboard/src/api/v1.ts:1759-1764`）。

交付物只存在于当前 HTTP 响应与客户端后续保存位置。服务不写入导出目录、不返回分享 token、不创建站内快照，也没有更新、撤销、过期、克隆或访问日志语义。文件名中的时间戳仅用于区分下载名，不表示可查询的生成历史。

## 4. 隐私、失败与已确认边界

导出前需要 data scope，且每条会话读取以请求中的 UMO 和会话 ID 为键；这是本链已确认的访问门槛。服务随后完整写出自身取得的持久化 history，未见针对密钥、提示词、工具输出、个人信息、文件路径或附件引用的专用脱敏与确认步骤（`astrbot/dashboard/api/conversations.py:139-145`；`conversation_service.py:203-225`）。

空列表直接报错。某条缺少标识、会话不存在或处理异常时，服务记录失败并继续其余项目；若全部失败则报错，若部分成功则只输出成功记录。`failed_items` 没有进入 `ConversationExport` 或 HTTP 响应，调用方无法从下载结果判断遗漏项（`conversation_service.py:184-243`）。文件内容先整体积累为字符串和 `BytesIO`，再以 8192 字节块传输；这降低了网络响应的逐块发送粒度，但没有避免导出阶段的全量内存占用（`astrbot/dashboard/api/conversations.py:63-74`）。

## 5. 设计取舍与已确认边界

- JSONL 将每个会话独立成行，适合批量后续处理，也允许消费者逐行读取；但当前没有版本契约和导入方。
- 服务在导出时重新读取权威会话对象，避免信任客户端随请求上传的历史内容；代价是不存在“当前页面选区”或现场渲染口径。
- 部分失败不阻断已成功记录，适合批量交付；但失败详情不随结果返回，外部消费者难以完整核对。
- 全量备份 ZIP 与会话 JSONL 分离，前者涵盖整个运行数据，后者保持为轻量会话交换；两者不能相互替代。

## 6. 未验证事项

- Dashboard 中选择会话、触发下载和错误提示的实际 UI 行为；本次只确认 API 客户端 Blob 接收封装。
- data scope 的签发、用户与 UMO 的授权关系，以及旧路由的 dashboard user 权限在真实部署中的边界。
- history 中 Markdown、富媒体、平台消息组件、工具结果、reasoning、system 内容和附件引用的实际 JSON 形态与第三方消费者兼容性。
- 大量或超长会话导出时的内存、响应时间、客户端取消和网络中断行为；本次未运行服务。
- 全量备份 ZIP 的实际恢复流程、校验失败和它与会话 JSONL 的数据覆盖差异。

## 7. 关键源码索引

- `astrbot/dashboard/schemas.py:401-424`：会话引用与导出请求契约。
- `astrbot/dashboard/api/conversations.py:63-84,113-145,287-293`：下载响应、新旧导出入口与鉴权。
- `astrbot/dashboard/services/conversation_service.py:184-243`：持久化会话读取、JSONL 组装与部分失败处理。
- `astrbot/dashboard/api/router.py:37-59`：v1 路由聚合。
- `dashboard/src/api/v1.ts:1707-1764`：Dashboard API 封装和 Blob 响应。
- `astrbot/core/backup/exporter.py:39-104`：与会话导出区分的全量备份范围。

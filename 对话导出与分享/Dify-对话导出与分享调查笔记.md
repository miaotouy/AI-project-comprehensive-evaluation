# Dify 对话导出与分享调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态搜索聊天页、Web/API conversation 路由、留存导出服务与 DSL 导入导出；未运行浏览器、CLI、对象存储或 API
>
> 调查范围：终端用户聊天记录的导出与分享；另记录管理员留存命令作为边界。明确排除应用/工作流 DSL、workflow run 归档和普通文件下载
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

本次未找到 Dify 为终端用户提供的“会话或消息 -> 文件、公开链接、分享稿”的产品主链。公开 WebChat 的聊天侧栏和消息操作围绕读取、删除、停止、重新生成、建议问题、引用与文件展开；没有确认到会话级下载、单消息导出、可访问分享快照或分享管理页面。因此不能将发布应用的公开 URL、嵌入脚本或 service API 误称为聊天记录分享。

仓内确有 `flask export-app-messages` 管理员命令：它按应用及时间窗口扫描持久化消息，生成 JSONL.GZ，并可写本地或对象存储。这是留存/运维式数据抽取，不在公开聊天 UI、普通 service API 或逐会话菜单中暴露；输出也不包含面向阅读的编排、选择器、访问链接、撤销或重新导入主链。应用 DSL 的导入导出则迁移作者配置，不能当成对话导出。

## 系统边界与已确认链路

```text
管理员留存导出（不是终端用户分享）：
flask export-app-messages --app-id ... [时间窗口]
  -> AppMessageExportService 批量读取应用的 Conversation / Message
  -> 逐行序列化 query、answer、inputs、引用资源等字段
  -> gzip JSONL
  -> 本地输出或配置的归档对象存储
```

命令定义在 `api/commands/retention.py:1591-1661`，服务实现为 `api/services/retention/conversation/message_export_service.py:74-190`。文件顶部明确列出了结果字段，且服务按应用和时间而非当前浏览器的活动分支取数。它应被理解为管理员可触发的应用消息留存工具，未确认有 UI 权限模型、访客访问语义或用户自助下载入口。

## 1. 终端聊天入口、范围与内容口径

在 `web/app/components/base/chat/` 及公开路由的静态搜索范围内，未找到由会话菜单、消息菜单或聊天页触发的 export/download/share 业务调用；已确认的聊天主链见[Chat](../Chat/Dify-Chat调查笔记.md)和[Chat UI](../Chat%20UI/Dify-ChatUI调查笔记.md)。这只能说明当前快照未确认该入口，不能推出部署版或外部客户端永远没有导出能力。

留存命令的源是一个 App 下满足时间过滤的持久化消息，而非单条消息、用户选区、活动 sibling 分支或整个工作区。输出为面向机器处理的 JSONL.GZ；字段包含查询、回答、inputs 和检索资源等消息数据。没有看到针对 system prompt、reasoning、工具 observation、文件本体、隐藏分支或敏感内容的面向分享过滤策略，故也不能把它宣称为已脱敏的数据集导出。

## 2. 格式、资源与往返

确认的格式仅是 gzip 压缩的 JSONL。服务将数据写到本地文件或归档存储的能力取决于运行配置；实际对象存储桶、下载地址、保留期和访问策略未运行确认。文件、引用与外部资源以消息记录可提供的字段表达，不构成附件打包或离线阅读包。

本轮未找到配套的“导入该 JSONL.GZ 并恢复 Conversation/Message 树”路径。Dify 有应用 DSL、Agent DSL 与 RAG Pipeline DSL 的导入导出，但它们传递应用定义、依赖和经过处理的配置数据，属于作者资产迁移；workflow run 的归档也属于运行记录，不是聊天稿。三者都不应填入本类目的格式往返能力。

## 3. 分享稿、公开访问与治理

发布应用的 WebChat、Chatbot、嵌入组件和 service API 是让他人**运行同一应用**的入口，而非把某次 Conversation 快照交给阅读者。它们各自以应用 token 或发布设置认证并创建/读取其运行数据；未找到 `conversation_id -> share token -> read-only snapshot` 的 Dify 自有链路。

因此本次没有确认独立分享稿、内容选区、Markdown/HTML/PDF/图片导出、生成历史、链接更新、撤销、过期、访问名单或克隆/重新导入。浏览器的复制操作、下载消息附件或第三方反向代理产生的 URL 均不属于已确认的对话分享对象。

## 设计取舍与已确认边界

- Dify 将“部署和调用应用”与“传播一次对话记录”分开：前者是产品核心，后者在当前快照没有形成终端用户工作流。
- 管理员导出按应用与留存窗口取数，适合保留/迁移/离线处理，不等于访问者可控制范围和隐私的阅读交付物。
- DSL 导出默认清理跨租户敏感配置的规则，不能外推给消息留存导出；两条服务的对象和威胁模型不同。

## 未验证事项

- `export-app-messages` 的实际 JSONL 字段、分页、异常收口、对象存储上传和大规模消息表现未运行。
- Cloud 或 Enterprise 控制台是否在本仓库外提供聊天导出、审计下载或分享页面未确认。
- 消息管理 API 的权限、数据删除后对留存导出的影响，以及导出文件的保留和访问控制未追到部署层。

## 关键源码索引

- `api/commands/retention.py:1591-1661`：`export-app-messages` CLI 入口及参数交接。
- `api/services/retention/conversation/message_export_service.py:1-190`：JSONL.GZ 记录格式、查询和本地/归档输出。
- `web/app/components/base/chat/`、`web/app/(shareLayout)/`：公开聊天/嵌入相关界面搜索范围。
- `api/services/app_dsl_service.py`、`api/services/agent/dsl_service.py`：作者定义迁移，与消息导出区分。
- `api/core/workflow/`：workflow run 与归档边界，非会话分享。

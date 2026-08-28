# Dify 会话与消息管理调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态阅读 ORM 模型、会话/消息服务、service API、WebChat 历史组件、父消息回溯和异步删除任务；未连接数据库或执行迁移
>
> 调查范围：已发布聊天应用的 conversation、message、变量、附件和消息链；工作流运行日志只说明交界
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 的对话事实源是 API 侧数据库对象，不是浏览器中的消息数组。`Conversation` 与 `Message` 分别保存会话和每轮问答，查询时同时按 application 和 user 限定归属。公开 WebChat 的 chat tree 是服务端列表/详情的 UI 投影，首次发送时才可能由生成器创建持久化对象。`MessageChain` 表仍保存 `input/output` 链式记录，但本轮未找到当前聊天重试或 sibling 将其写成树指针的执行路径；分支事实应以 `Message.parent_message_id` 为准。

## 系统边界与数据主链

```text
终端用户 -> conversations 分页列表 -> 选择 conversation -> messages 分页
  -> 发送时取得已有对象或初始化 conversation + user message
  -> worker/运行时写入 answer、thought、附件与关联运行对象
  -> 浏览器的 SSE 临时树与 API 重取共同恢复界面
```

`ConversationService.get_conversation` 显式接收 app、conversation ID、user 和 session（170-189 行）；`delete` 的契约也要求对象属于给定 app 和 user（192-250 行）。conversation ID 因此不能作为跨应用、跨终端用户的独立访问令牌。

## 1. 会话、消息与链路模型

Conversation 表示某终端用户在某应用下的会话状态，Message 为独立表记录；它的 `query`、`answer`、inputs、模型引用、调用来源、状态、错误、价格、workflow run 与 `parent_message_id` 同行持久化。模型文件还定义消息文件、feedback、annotation 等关联对象，service API 另有消息详情、文件、分页与 conversation variable 的响应 schema。一个可见回答可能关联文件、feedback、annotation、Agent thought 或 workflow run，不能约化为 role/content 文本。

分支由 Message 的 parent pointer 表达，而非由 `MessageChain` 负责。每次消息型生成初始化都会新建 Message 并写入请求携带的 `parent_message_id`；WebChat 正常发送取当前末尾回答，重新生成则改取被重新生成问题之前的回答。前端据消息列表重建 question/answer tree，并以本地 target message 选择可见 sibling；切换按钮本身不改写服务器记录。上下文辅助函数再沿 parent ID 回溯一条 thread，因此重新生成保留旧回答、以新 Message 形成可选择的候选分支，而非覆盖原行。

## 2. 创建、读取、分页与持久化

会话列表由 `ConversationService.pagination_by_last_id` 提供（36 行起），消息历史由 `MessageService.pagination_by_last_id` 提供（164 行起）。服务返回 infinite-scroll 类型，确认公开路径采用基于最后 ID 的分页，而不是一次传输全部历史。`WebConversationService` 复用会话服务，使公开网页与 API 侧不拥有不同的数据存储。

创建时机在运行链，而非仅由侧栏新建按钮决定。`MessageBasedAppGenerator._init_generate_records` 是消息型生成器的共同记录初始化入口（118 行起）；Chat/Agent worker 会在真正执行前重新按 ID 取得 conversation/message。前端“新建会话”可只是清空当前选择和输入，不能据此认为数据库已插入空 Conversation。

## 3. 生命周期、列表与用户操作

公开 service API 覆盖会话列表、详情、删除、改名及 variables；`ConversationService.delete` 完成归属校验后先把会话标为 deleted，提交后投递清理任务。带历史的 WebChat context 暴露新建、切换、置顶、取消置顶、删除和重命名动作（`chat-with-history/context.ts:24-42`），侧栏再把这些动作落实到 API。

物理删除在异步任务中进行：它先删除工具文件的存储对象，再删除 MessageAgentThought、MessageChain、消息文件、保存消息、annotation、feedback、变量、human-input 表单、Message、置顶和 Agent 调试会话等关联行，最后删除已软删 Conversation。任务失败会按指数退避重试；定时 sweep 会重新投递仍标记 deleted 的会话，弥补首次 dispatch 丢失。这确认删除具有“先不可见、后清理”的恢复语义，但没有运行验证存储删除和数据库事务崩溃窗口。

静态存在 pin 操作不能证明其字段、排序或多端同步已验证。本次未找到足够证据来确认全文搜索、归档、回收站、会话复制或手动导入导出，应保持未确认，不能按常见聊天产品补全。

## 4. 消息操作与分支边界

重新生成创建新行，不会更新被替换的 answer；新行的 parent 指向该问题之前的有效回答，前端 sibling 控件据相同父 ID 下的候选轮换显示。切到含未提交 human-input 的 workflow 分支时，前端会据其 message/workflow run ID 触发恢复。MessageChain 虽会在会话删除和保留清理中一起删除，但当前 Agent thought 创建路径将其 ID 留空；本轮不能将该表解释为聊天分支或模型候选的现行权威结构。

未找到对已持久化单条 Message 的编辑或删除 API，不能从“重新生成”推断存在原地编辑、续写或任意回退。请求执行和流式最终化见 [对话请求与上下文](../对话请求与上下文/Dify-对话请求与上下文调查笔记.md)，本处只记录数据边界。

## 5. 变量、附件与外部对象绑定

conversation variable 有独立服务入口（`ConversationService.get_conversational_variable:253`）和 API 路由；它是随 conversation 保存的运行变量，不等于浏览器输入表单。请求包含 inputs/files，文件先由应用上传配置转换，消息再关联实际附件。模型、工具、知识库和 workflow 配置主要来自应用配置或运行实体；本次未确认是否完整快照到每个 Message。

workflow run 有自身 repository、详情和归档机制，不能因结果出现在聊天里就归入 Message 的生命周期。详见 [生成式输出与运行时](../生成式输出与运行时/Dify-生成式输出与运行时调查笔记.md)。

## 6. 一致性、恢复与迁移

浏览器 hook 在流中维护 conversation ID、task ID 和 chat tree，完成后可重取完整消息（`chat/hooks.ts:616-765`）；数据库是刷新后的权威来源。静态代码不能证明 UI chunk 更新与持久化频率一致，也不能替代多标签并发、事务回滚、服务器重启或网络中断验证。

仓库存在 migrations 和清理服务，但本次未把版本迁移、导入导出、保留清理与异步删除任务逐项贯通。因此不能从部署能力推断聊天记录具备可用的备份恢复。

## 7. 会话数据的能力边界

会话变量是独立于消息正文的服务端对象，service API 提供 variables 的读取和更新接口；文件、feedback、annotation、Agent thought 与 workflow run 也分别关联到消息或运行记录。这使一条可见回答可以由多个表和事件共同构成，不能用前端 answer 文本替代完整的持久化语义。应用、用户与会话共同限定读取范围，模型/Provider/工具的运行时解析则不应从 Conversation 字段反推为永久快照。

本轮确认分页、归属校验、惰性创建、会话操作与父消息引用，但没有找到并走通会话全文搜索、归档/回收站、复制、对话导入导出或备份恢复的完整路径。消息历史 API 的存在也不能证明断线中的临时树、半截回复、并发写入和服务端重启会怎样最终合并；这些需要数据库和真实生成任务验证。

## 未验证事项

- `MessageChain` 在当前版本是否仍有其他非聊天 writer，以及其 `input/output` 的产品语义。
- 置顶、删除、空会话清理在真实数据库、对象存储失败与多实例竞争下的事务和恢复效果。
- 消息搜索、跨会话检索、归档、导入导出、保留期限与多端并发写入。
- workflow 输出、Agent thought、工具结果和附件在删除会话后的级联保留关系。

## 关键源码索引

- `api/models/model.py:1540-1660,2520-2540`：Message 的 parent pointer、运行引用与 MessageChain 结构
- `api/core/app/apps/message_based_app_generator.py:118-235`、`api/core/prompt/utils/extract_thread_messages.py`：Message 创建、parent 写入和 thread 回溯
- `web/app/components/base/chat/chat-with-history/chat-wrapper.tsx:203-277`、`web/app/components/base/chat/chat/hooks.ts:1901-1939`：重新生成、sibling 选择和 human-input 恢复入口
- `api/services/conversation_service.py:36-283`、`api/tasks/delete_conversation_task.py`：分页、归属校验、软删、异步清理和补扫
- `api/services/message_service.py:164-323`：消息分页与详情
- `api/services/web_conversation_service.py`：公开 Web 封装
- `api/controllers/service_api/app/conversation.py`：会话 API
- `web/app/components/base/chat/chat-with-history/`：历史会话与侧栏动作

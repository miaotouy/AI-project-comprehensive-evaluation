# Dify Chat 调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态阅读公开 WebChat、service API、应用生成服务、ORM 模型和共享聊天组件；未启动部署、未发送真实模型请求
>
> 调查范围：已发布应用面对终端用户或外部调用者的聊天/工作流运行表面；控制台内完整编辑工作流、知识库运营和所有 Agent v2 表面不在本篇范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 的 Chat 是“已发布应用的调用表面”，而非一个由用户自由配置所有模型和工具的通用客户端。应用作者先在租户工作区定义并发布 chat、agent chat、advanced chat、workflow 或 completion 应用；终端用户再通过带历史的 WebChat、轻量 Chatbot、嵌入式组件或 service API 提交输入。服务端按应用模式创建或读取运行对象并派发给相应 generator，浏览器只把事件流投影为临时消息树和交互状态。

因此 Dify 的聊天结论必须区分“公开聊天的体验”和“应用运行平台的能力”。公开页可输入 query、变量和文件，处理会话、流、停止、重新生成、候选回答与 workflow 人工输入；模型、Provider、工具、知识和大部分运行策略仍由发布者预设。工作流也可被 API 直接运行，未必拥有普通聊天的线性历史语义。

## 产品表面与系统边界

| 表面 | 主要用户 | 已确认用途 | 边界 |
| --- | --- | --- | --- |
| 控制台 | 工作区成员/应用作者 | 配置应用、资源、工作流与调试 | 本篇不把它等同于公开聊天 |
| `/chat/[token]` | 已发布应用的终端用户 | 带会话历史的 WebChat | 只暴露已发布应用允许的输入，不直接管理租户资源 |
| `/chatbot/[token]` 和嵌入式组件 | 终端用户/嵌入宿主 | 较轻的 Chatbot 运行面 | 与历史页复用发送与事件协议，但没有同等导航结构 |
| service API/SDK | 外部业务系统 | 以 API 调用已发布应用或 workflow | 不拥有控制台草稿与配置权限 |
| workflow API | 外部业务系统或集成 | 运行/停止 workflow | 结果为 workflow run 与事件，不可由 WebChat 行为反推完整语义 |

这一区分源于页面和后端的责任边界：`web/app/(shareLayout)/` 与 `components/base/chat/` 组装终端用户输入并消费 SSE；`api/controllers/service_api/`、`AppGenerateService` 和模式专属 generator 才处理应用身份、配置、运行记录与实际执行。公开页不能从浏览器读取 Provider 凭据，也不提供逐回合任意改模型/工具的通用设置器。

## 端到端聊天主链

```text
发布应用的 WebChat/嵌入式 Chatbot
  -> 加载站点配置、输入字段与已有 conversation（历史模式）
  -> 输入 query、inputs、files、当前 conversation 和 parent message
  -> useChat 先建立本地 question/answer 占位并以 streaming 发送
  -> service API 校验调用上下文，AppGenerateService 按 AppMode 分派
  -> 消息型 generator 创建/读取 conversation、message 与应用配置；
     workflow generator 创建 workflow run/repository 并启动图执行
  -> 后端把文本、thought、文件、任务或 workflow node 事件转为 SSE
  -> useChat 回填 conversation/message/task/run ID，合并当前树；结束后按需重取服务端消息
```

共享 hook 的发送体包含 query、处理后的 files、inputs、conversation ID 与 `parent_message_id`。它先向本地 chat tree 插入 question/answer 占位，所以用户在服务端分配 ID 前就能看到输入和加载状态；当数据事件带回 conversation/message/task ID 后，前端才将临时节点与服务端身份衔接。`web/app/components/base/chat/chat/hooks.ts` 是浏览器侧的主链入口，`api/services/app_generate_service.py:88-318` 是服务端分派入口。

## 核心对象与状态权威

| 对象/状态 | 主要所有者 | 在 Chat 中的作用 | 不能据此推断的内容 |
| --- | --- | --- | --- |
| Application 与 app mode | API 数据与应用配置层 | 决定可调用能力及 generator | 前端 URL token 不是全部配置 |
| Conversation、Message、MessageChain | API 数据库模型与服务 | 历史、分页、父引用和可恢复消息 | 浏览器数组不是持久化事实源 |
| task ID、workflow run、node events | 应用运行/工作流运行时 | 流、停止、暂停和过程反馈 | 不等同普通 message 的线性状态 |
| chat tree、responding、当前 ID、订阅 | React hook/context | 流式显示、局部交互与 URL/会话切换 | 刷新、并发和崩溃恢复尚未运行验证 |

`Conversation`、`Message`、`MessageChain` 及文件、feedback、annotation 等关联对象位于 `api/models/model.py`。会话和消息服务按 application 与 user 限定读取，表明 conversation ID 不是跨应用或跨用户的通用访问令牌。首次发送才可能在服务端初始化 Conversation/Message；公开页的“新建”首先是清理当前 UI 选择和输入，不能单靠按钮认定数据库已经插入空会话。

## 应用模式与运行交接

`AppGenerateService` 在统一入口后按模式选择 completion、chat、agent chat、agent、advanced chat 或 workflow generator；带 session 的 Agent 应用在服务层改按 Agent Chat 处理。其共同点是都能由应用层转换成对调用者可消费的响应，差异则决定在各自 generator/runtime 中。

普通 chat 与 Agent Chat 使用 conversation/message 为中心的记录和 worker 链。advanced chat 读取会话后进入 workflow 运行，同时仍需处理对话型输出；workflow 应用将 inputs/files 转换为 workflow 应用配置和图运行对象，可选择 streaming 或 blocking。故“有聊天页面”不能证明任一 workflow 都保存同样的历史、能重试为同样的父消息树，或支持同样的停止路径。模式分流、上下文和事件细节见[对话请求与上下文](../对话请求与上下文/Dify-对话请求与上下文调查笔记.md)。

## 专项导航

| 问题 | 详细笔记 | 本篇的交接结论 |
| --- | --- | --- |
| 会话、消息、父链、分页和删除 | [会话与消息管理](../会话与消息管理/Dify-会话与消息管理调查笔记.md) | 浏览器历史是 API 数据的投影，首次发送可能惰性创建对象 |
| 请求、上下文、SSE、停止与 workflow 事件 | [对话请求与上下文](../对话请求与上下文/Dify-对话请求与上下文调查笔记.md) | App mode 决定生成器与事件/运行记录语义 |
| 会话侧栏、输入、停止、暂停恢复和消息操作入口 | [Chat UI](../Chat%20UI/Dify-ChatUI调查笔记.md) | 历史页和嵌入页复用 hook，但导航能力不同 |
| Markdown、引用、reasoning、文件与 workflow 内容块 | [消息渲染器](../消息渲染器/Dify-消息渲染器调查笔记.md) | 事件先转为前端消息模型，再按内容类型交给组件 |
| 工具、MCP、插件与 workflow 工具 | [Agent 工具](../Agent工具/Dify-Agent工具调查笔记.md) | 工具由应用/节点配置决定，不是公开聊天的自由选择器 |
| Provider、模型、凭据与负载均衡 | [LLM 渠道管理](../LLM渠道管理/Dify-LLM渠道管理调查笔记.md) | 公开请求在后端解析租户模型配置，不携带原始凭据 |
| 输出对象/图运行与外部协作候选 | [生成式输出与运行时](../生成式输出与运行时/Dify-生成式输出与运行时调查笔记.md)、[外部执行体与应用协作](../外部执行体与应用协作/Dify-外部执行体与应用协作调查笔记.md) | workflow run 可产出独立运行记录；外部协作还未达到完整准入链 |

## 关键能力与已确认边界

### 会话与候选回答

历史页面提供会话列表、创建、选择、置顶、取消置顶、删除和重命名入口；发送请求中的 `parent_message_id` 与 hook 的 sibling 切换证明当前聊天需要表达父回答和同级候选。现有证据只足以确认“父引用参与重试/候选切换”的链路，不将其扩展成任意消息编辑、完整树可视化或全局版本控制的结论。

### 流、停止、重新生成与暂停

SSE 不只传文本：前端还接收 Agent thought、文件、message/conversation/task ID 与 workflow run/节点事件。`handleStop` 先将本地 responding 置为 false，再在 task ID 存在且非暂停时请求 stop API；restart 会先调用停止逻辑再清理本地树和建议问题。其含义是 UI 给出即时反馈，不是服务端或模型已完成真实取消的证明。workflow 暂停后可建立 run 订阅并提交人工输入恢复，但后台持续运行、离页恢复和多会话并行尚未验证。

### 搜索、导出与跨端范围

本次明确找到会话/消息的分页与历史重取路径，没有将“存在会话列表”推为全文搜索、归档、回收站、跨设备草稿同步或对话导出。当前 Dify 笔记没有为对话导出与分享建立单项目专项，故也不从消息组件或 API 列表外推可用的分享链接、PDF/图片导出或撤销机制。

## 未验证事项

- 未创建真实应用或调用真实模型，未验证应用发布、匿名/认证终端用户、SSE 断线、限流和错误反馈。
- 未验证多标签页或多用户同时操作一条 conversation 时的合并、重复消息、置顶/删除回滚与恢复。
- 未验证停止对模型、插件、MCP、队列 worker 和 workflow 节点的实际传播；只确认 API/hook 入口。
- 未运行移动布局、键盘、焦点、屏幕阅读器、长会话性能、嵌入宿主跨域和浏览器通知。

## 关键源码索引

- `web/app/(shareLayout)/{chat,chatbot}/[token]/page.tsx`：发布聊天页面入口。
- `web/app/components/base/chat/chat/hooks.ts:527-1926`：发送、流、停止、workflow 暂停与恢复状态。
- `web/app/components/base/chat/{chat-with-history,embedded-chatbot}/`：历史导航与嵌入式调用表面。
- `web/service/share.ts`：浏览器的聊天 SSE 与 stop 调用。
- `api/services/app_generate_service.py:88-318`：应用模式分派和运行响应回收。
- `api/core/app/apps/`：消息型、Agent、advanced chat 与 workflow generator。
- `api/models/model.py`、`api/services/{conversation_service.py,message_service.py}`：聊天数据的服务端事实源。

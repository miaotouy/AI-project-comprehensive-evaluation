# AstrBot 会话与消息管理调查笔记

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`a9bb8a64ca69657e6262e3ca06541ecaf3a6d1ca`（分支：`master`）
>
> 调查方式：2026-08-06 从 [`../Chat/AstrBot-Chat调查笔记.md`](../Chat/AstrBot-Chat调查笔记.md) 迁移现有段落与证据；按提交范围增量核对 WebChat 会话持久化（chat_service / migra_webchat_session）
>
> 调查范围：两级会话概念、会话标识、对话持久化与 ConversationManager、群历史持久化；事件调度、流水线与并发执行进入对话请求与上下文，界面进入 Chat UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 是面向 IM 平台（QQ/Telegram/Discord/微信等）的**消息驱动异步聊天框架**，会话与消息以"平台会话 → 子对话"两级结构持久化：

- **两级会话概念**：会话（session）= 聊天窗口（如一个群），以 `unified_msg_origin`（`platform_id:message_type:session_id`，message_session.py:19）标识；对话（conversation）= 会话内的子对话，可新建/切换/删除（conversation_mgr.py:1-5 docstring）。
- **持久化双轨**：对话历史存 SQLite `conversations` 表（`ConversationV2.content` = OpenAI 格式 JSON 列表，po.py:83）；当前对话 ID 经 SharedPreferences `sel_conv_id`（scope=umo）持久化。
- **两级缓存**：`ConversationManager` 内存缓存 `session_conversations`（UMO → 当前对话 ID）60 秒防抖保存，进程崩溃可能丢 60 秒内的切换/新建（静态推断，未实测）。
- 群历史可选持久化到 `PlatformMessageHistory` 表（上限 700 条），并暴露 `get_group_message_history` 工具。

## 系统边界与数据主链

```text
平台适配器收到消息 -> 构造 unified_msg_origin（platform:message_type:session_id）
  -> ConversationManager.get_curr_conversation_id（内存 -> SharedPreferences -> None）
  -> 流水线处理后（执行语义在对话请求与上下文）
  -> add_message_pair 以 user+assistant 对追加历史
  -> 60 秒防抖写 SharedPreferences（sel_conv_id）
```

边界：事件总线、流水线调度、并发锁与上下文构建属于对话请求与上下文；消息发送后的结果装饰与 UI 属于 Chat UI；`PlatformMessageHistory` 的注入与工具语义属于请求侧。

## 1. 会话、消息与分支数据模型

### 1.1 两级概念（conversation_mgr.py:1-5 docstring）

- **会话**：聊天窗口（群聊/私聊），`unified_msg_origin` 标识；
- **对话**：会话内的子对话，可切换（`switch_conversation` :126-137）、删除（:139-158）、新建（`new_conversation` :92-124，`/new` 继承当前 persona 与模型，builtin_commands/commands/conversation.py:239-244）。

### 1.2 会话标识（message_session.py:6-27）

```text
unified_msg_origin = f"{platform_id}:{message_type.value}:{session_id}"
```

- `MessageSession.from_str` 用 `split(":", 2)` 解析（:24-27）——session_id 本身可含冒号；
- `platform_id` 与 `platform_name` 在 v4 起统一（:13-16，`__post_init__` 自动取等值）。

### 1.3 对话表（po.py:67-109）

| 字段 | 说明 |
|---|---|
| `inner_conversation_id` | int 自增主键 |
| `conversation_id` | str UUID（:75-80） |
| `platform_id` / `user_id` | user_id = UMO（:82） |
| `content` | OpenAI 格式历史 JSON 列表（:83） |
| `persona_id` | 对话级角色绑定（:86） |
| `token_usage` | 累计 token，0 时用估计器（:87-91） |

### 1.4 ConversationManager（conversation_mgr.py:19-443）

- 内存缓存 `session_conversations: dict[str, str]`（UMO → 当前对话 ID，:23），`save_interval = 60` 秒（:25）——保存走 SharedPreferences `sel_conv_id`（`sp.session_put` :123、:137）；
- `get_curr_conversation_id` 三级回退：内存 → SP → None（:174-188）；
- **v2→v1 兼容转换** `_convert_conv_from_v2_to_v1`（:62-90）：`Conversation` 是 v3 时代的内存模型（history=JSON 字符串），`get_conversation` 统一返回 v1 形态（:190-214）；
- 删除会话触发级联回调 `register_on_session_deleted`（:30-43），用于知识库配置等清理（:171-172）；
- `add_message_pair`（:357-390）以 user+assistant 对追加历史；`get_human_readable_context`（:392-443）把历史转成 "User:/Assistant:" 可读文本（tool_calls 转 JSON，:423-428）。

## 2. 群聊/私聊差异（数据侧）

| 维度 | 行为 | 位置 |
|---|---|---|
| 会话 ID 构造 | QQ 群 = group_id、私聊 = 用户 ID；webchat = `webchat!用户名!会话ID` | aiocqhttp_platform_adapter.py:222-226、webchat_adapter.py |
| 群历史持久化 | `PlatformMessageHistory` 表（po.py:239-269），`group_message_history_enable` 开启后存储平台无关表示，上限 `group_message_history_max_cnt: 700`，暴露 `get_group_message_history` 工具 | platform_message_history_mgr.py:32-106 |
| webchat 会话行 | `PlatformSession`（webchat）由 ChatService 在首次发送消息时惰性补齐（chat_service.py:1118-1135，#9607）；WebChat 会话迁移脚本移除一次性标记、可重复执行（migra_webchat_session.py），配合会话列表恢复缺失会话 | chat_service.py:1118-1135、migra_webchat_session.py |
| 群隔离 | 默认群内共享同一对话；`unique_session` 开启后按发送者构建独立会话 | waking_check/stage.py:81-85 |

群上下文的**内存环形缓冲注入**（1000 条原始消息 → `<system_reminder>` 块）与图像 caption 属于请求侧的上下文构建，见对话请求与上下文笔记。

## 3. 设计取舍与已确认边界

- **崩溃丢最近对话**：`session_conversations` 内存缓存 60s 防抖 + SP 持久化，进程崩溃可能丢 60s 内的切换/新建（静态推断，未实测）。
- **Conversation v1 兼容层**：内部统一返回 v3 时代内存模型，历史 API 零改动（1.4）。
- **persona 是对话级绑定**：`/new` 继承当前 persona 与模型；`persona_id` 存在对话行上（1.3）。
- **类目边界**：会话与消息的持久化语义在本笔记；每条入站消息的任务化、流水线调度、并发锁与上下文压缩在对话请求与上下文笔记。

## 4. 未验证事项

- 崩溃恢复（60s 防抖窗口内状态）未实测。
- `unique_session` 开启后按发送者构建独立会话的实际行为未运行验证。
- 群历史持久化开关下的存储行为未运行验证。

## 5. 关键源码索引

- 会话管理：`astrbot/core/conversation_mgr.py`（:19-443）、`astrbot/core/platform/message_session.py`（:6-27）
- 持久化：`astrbot/core/db/po.py`（ConversationV2 :67-109、PlatformMessageHistory :239-269）、`astrbot/core/db/sqlite.py`、`utils/shared_preferences.py`
- 群历史：`astrbot/core/platform_message_history_mgr.py`（:32-106）
- 平台适配：`astrbot/core/platform/sources/aiocqhttp/aiocqhttp_platform_adapter.py`（:222-226）、`webchat/webchat_adapter.py`

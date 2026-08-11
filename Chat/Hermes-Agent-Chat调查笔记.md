# Hermes-Agent Chat 概览

> 调查对象：`E:\works\git\hermes-agent`（git 仓库）
>
> 调查更新日期：2026-08-10
>
> 代码快照：`01a1037d1e6d7b6eb96a786ef282c3aea4818194`（分支：`main`）
>
> 调查方式：静态阅读 Python（tui_gateway / agent / run_agent / hermes_state）与 TypeScript（apps/desktop、apps/shared、ui-tui）源码；以函数行号精确引用；未运行任何组件。
>
> 调查范围：以桌面端（Electron + React）为观察界面，追踪一条消息从输入到持久化的主链路；覆盖会话/消息数据模型、生命周期、发送与流式、上下文构建与压缩、消息操作、列表检索、Agent/工具绑定、UI 交互与中断语义。本次未调查 CLI 交互模式细节、gateway 消息平台接入、cron/kanban/插件体系、Web 端。运行行为（视觉效果、时序、性能）以静态推断标注，未验证。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

> 迁移状态（2026-08-11）：本文件是迁移期保留的旧版长文，内容已按新类目边界迁移：
>
> 2026-08-11 本文件已压缩为概览
>
> - 会话与消息管理：[`../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md`](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)（数据模型、生命周期与持久化、列表检索、一致性）
> - 对话请求与上下文：[`../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md`](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)（提交入口、上下文拼装与压缩、流式事件链、中断与回写）
> - Chat UI：[`../Chat UI/Hermes-Agent-ChatUI调查笔记.md`](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)（工作台、Composer、生成反馈、消息操作、UI 状态所有权）
> - 消息渲染：[`../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md`](../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md)（已有独立笔记，内容渲染类段落不再重复）

## 结论摘要

Hermes-Agent 是跨 CLI / TUI / 桌面 / 消息网关复用同一套 Python agent 核心的个人 AI 助手：

1. 桌面端不运行 agent，而是自 spawn 一个无头 `hermes serve` 后端进程，renderer 经 WebSocket 发起 `prompt.submit` 等 JSON-RPC 调用，后端在独立线程运行 `AIAgent.run_conversation`，流式增量以 `message.delta`/`message.complete` 事件推回 UI。
2. **后端 SQLite 是唯一事实源**：会话、消息全部落在 profile 作用域下单一 `state.db`；每会话 JSONL 消息日志已在 spec 002 移除（`gateway/session.py:3383-3385`）。桌面端所有会话原子只是后端真相的缓存，遵循"合并而非覆盖、先乐观后诚实、拒绝乱序回写"的更新原则。
3. **身份有两层**：进程内 UI 句柄 `sid` 与持久化 `session_key`；压缩轮转生成新 `session_key`，经 `parent_session_id` + `end_reason='compression'` 连成轮转链，跨轮转不变标识是 `list_sessions_rich` 派生的只读字段 `_lineage_root_id`（`hermes_state.py:6150`），桌面端 pin、路由匹配都基于它。
4. 每条消息同时是历史里的事件，也是数据库里的行；落盘用"单事务批量 + 内存 marker 去重"的原子配对契约（`run_agent.py:2257-2281`），崩溃中途不写库，痕迹只在 `turn_marker.py` 中断标记文件，恢复会话时按标记自动重放。
5. 子代理是真实会话：`delegate_task` 创建占 DB 行的子会话（`_delegate_from` 标记），继承同一套创建与持久化语义，删除时沿标记级联。

## 产品表面与系统边界

三界面一核心，后端是同一个 `tui_gateway/server.py` + `AIAgent` 核心：

| 界面 | 进程模型 | 与后端传输 |
|---|---|---|
| 桌面端 Electron | renderer 进程 → WebSocket → 后端 | JSON-RPC over WS（`apps/desktop/src/hermes.ts` + `apps/shared`） |
| TUI（`hermes --tui`，Node/Ink） | Node 前端进程 → stdio → 后端 | 换行分隔 JSON-RPC over stdio |
| gateway / CLI | 同进程 | 直接调用 |

- 桌面端 spawn 参数为 `['serve','--host','127.0.0.1','--port','0']`（`electron/backend-command.ts:18-22`）；`HERMES_SERVE_HEADLESS=1` 下 `mount_spa()` 只挂 JSON-RPC/WS/API 面（`hermes_cli/web_server.py:16054`）。
- 边界：gateway 消息平台接入、cron/kanban/插件体系、Web 端、CLI 交互模式细节本次未调查。

## 端到端聊天主链

一条 text 调用链：桌面 composer → `prompt.submit`（WS）→ `methods_prompt.py` 校验/busy 门控/truncate → `_run_prompt_submit`（`server.py:9352`：记录 turn marker、注册 `_stream` 回调、启动 run 线程）→ `agent.run_conversation`（`conversation_loop.py:1233`：`build_turn_context` 组装上下文、循环调用 Provider，每 token 增量经 `_stream` 回发 `message.delta`）→ `finalize_turn` 持久化 → `message.complete`（含 status/text/usage）。桌面端 delta 进入自适应节流队列（33ms 起、上限 250ms），complete 后合并终态并触发会话列表刷新（300ms 合并）。

## 核心对象与状态权威

- **后端权威**（`state.db`）：`sessions` 表（`hermes_state_common.py:207-263`）——`id` 主键即持久 `session_key`、`source`、`parent_session_id`（血缘/轮转链唯一关联字段）、`model_config`（内含 `_branched_from`/`_delegate_from` 标记）、`system_prompt_hash`、`archived`/`pinned`、`compression_failure_*` 冷却字段；`messages` 表（:265-289）一行一条消息——`role`、`content`、`tool_call_id`/`tool_calls`、`reasoning_*`、`active`（软删/归档）、`compacted`（压缩归档仍可搜索）、`display_kind`/`display_metadata`、`api_content`（发 API 的字节保真 sidecar，恢复时原样返回）。
- **桌面端权威**：仅原生/OS 性、窗口、流式渲染缓冲、发送前的乐观向量；后端事件投影进本地状态，不做本地合成。状态原子 `$sessions`/`$messages`/`$activeSessionId`/`$busy`（`apps/desktop/src/store/session.ts`），per-session 真实状态在 `sessionStateByRuntimeIdRef`。
- **渲染投影**：后端 `SessionMessage` 经 `toChatMessages` 转为 assistant-ui part 数组（reasoning 是 part 而非顶层字段），工具行折叠、`@image:` 行提取回 attachmentRefs（`lib/chat-messages.ts`）。

## 专项导航

- 会话与消息管理：[`../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md`](../会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md)
- 对话请求与上下文：[`../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md`](../对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md)
- Chat UI：[`<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>`](<../Chat UI/Hermes-Agent-ChatUI调查笔记.md>)
- 消息渲染：[`../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md`](../消息渲染器/Hermes-Agent-消息渲染器调查笔记.md)
- 横向对比：[`../会话与消息管理/会话与消息管理横向对比.md`](../会话与消息管理/会话与消息管理横向对比.md)、[`../对话请求与上下文/对话请求与上下文横向对比.md`](../对话请求与上下文/对话请求与上下文横向对比.md)、[`<../Chat UI/ChatUI横向对比.md>`](<../Chat UI/ChatUI横向对比.md>)；跨层综合结论见 [`../Chat/Chat横向对比.md`](../Chat/Chat横向对比.md)

## 关键能力与已确认边界

- **lineage root 跨压缩轮转**：`get_compression_lineage`/`get_compression_tip`（`hermes_state.py:7951/:5719`）只沿 compression 边遍历（上限 100 层）；轮转 `publish_compression_child` 单事务插入子行并写压缩后消息（`conversation_compression.py:3265-3329`），原地压缩 `archive_and_compact` 同 ID 软归档；`_lineage_root_id` 是桌面端 pin/路由匹配的键（`session.ts:243-252`）。
- **编辑 = 截断 + 重发**：无 `session.edit`/`message.edit` RPC（检查范围：方法注册表），编辑经 `prompt.submit` + `truncate_before_user_ordinal`（服务端先 `db.replace_messages` 再改内存历史，压缩已结束会话抛错）；无单消息删除，`rewind_to_message` 软删只服务 `/rewind`。
- **steer/redirect 分层中断**：`steer` 把文本追加到最后一条 tool 消息 content 尾部（不新增消息、不破坏角色交替），无 tool 可挂时回存为下一轮用户消息（`agent_runtime_helpers.py:3921-3982`）；`redirect` 只打断 model request，不扩散到工具/子代理；每轮开头 `clear_interrupt`。
- **崩溃安全**：`_flush_messages_to_session_db_unlocked`（`run_agent.py:1999-2281`）单事务批量 + `_db_persisted` marker 去重，失败不盖章、下轮全量重扫；`interrupted_turns.json` 是唯一中途痕迹，resume 时按标记自动重跑（attempts 防崩溃循环）。
- **压缩触发**：无 token 级截断原语；`should_compress` 阈值由 context_length 比例算出；preflight 多 pass（至多 3 轮，要求行数减少或 token 降幅 >5%）+ idle 压缩（墙上时间门）。
- **搜索边界**：FTS 索引矩阵（unicode61/bigram/trigram + LIKE 兜底），cjk/trigram 明确跳过 `role='tool'` 行（约 90% 字节是机器噪声）；rewind 行默认隐藏、压缩归档行默认可见。

## 未验证事项

- 运行行为（视觉效果、时序、性能、真实 Provider 上的流式）全部为静态推断，未运行验证。
- `display.busy_input_mode` 各模式（steer/redirect/queue）在真实 provider 上的行为未验证。
- FTS 实际线上布局、触发重建与 trigram 命中效果未验证。
- 桌面端断网中断、快速切换会话、多窗口并发等事件时序未实测。
- 工具执行增量 flush 在工具杀死进程场景下的实际持久化结果未验证。

## 关键源码索引

- 后端入口：`tui_gateway/server.py`——`_run_prompt_submit`（:9352）、`_handle_busy_submit`（:7395）、`_emit`/事件帧（:1511-1540）；`methods_prompt.py:67-333`；`methods_session.py`——resume（:306）、branch（:2672）、interrupt（:2824）、steer（:3055）。
- 主循环与上下文：`agent/conversation_loop.py:1233`、`agent/turn_context.py:337`、`agent/turn_finalizer.py:69`。
- 压缩：`agent/context_compressor.py:2588`、`agent/conversation_compression.py:2129`、`hermes_state.py`——`publish_compression_child`（:3488）、`archive_and_compact`（:6938）。
- 运行与持久化：`run_agent.py`——`_flush_messages_to_session_db_unlocked`（:1999）、`interrupt`/`clear_interrupt`/`redirect`（:3024/:3170/:3261）；`hermes_state.py`——`_lineage_root_id`（:6150）、`append_messages_batch`（:6454）、`replace_messages`（:6866）、`list_sessions_rich`（:5790）、`get_resume_conversations`（:7464）。
- 桌面端：`apps/desktop/src/hermes.ts`、`store/session.ts`（mergeSessionPage :334、sessionPinId :243）、`use-message-stream/index.ts`（completeAssistantMessage :538）、`use-prompt-actions/submit.ts`（:112）、`rewind.ts`、`lib/chat-messages.ts`（:13）。
- 崩溃标记：`tui_gateway/turn_marker.py`；子代理：`tools/delegate_tool.py` `_build_child_agent`（:1512）。

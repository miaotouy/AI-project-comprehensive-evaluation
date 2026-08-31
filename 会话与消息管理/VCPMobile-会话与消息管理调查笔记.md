# VCPMobile 会话与消息管理调查笔记

> 调查对象：`VCPMobile`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`cecdbe432feda57821938bba7625a272113d21c1`（分支：`main`）
>
> 调查方式：静态阅读 Pinia store、Tauri 命令、SQLite 查询/事务与相关测试
>
> 调查范围：Topic、消息、附件、索引、渲染缓存与活动生成的本地生命周期；不展开远端同步协议
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 的会话单位是归属于 Agent 或 Group 的 Topic，而非通用的消息树。Topic 和消息都以 SQLite 为权威源，Pinia 仅保存当前选择、分页窗口和本地 UI 投影。消息按时间戳和 ID 线性排序；编辑或重新生成通过截断后续历史实现，没有发现分支版本或活动路径字段。

## 系统边界与数据主链

选中 owner 时，前端优先恢复持久化的最近 Topic ID，缺失时从本地 Topic 列表取最新项；`sessionEpoch` 使慢请求无法覆盖后来的选择，见 `src/core/stores/chatSessionStore.ts:25-68, 174-227`。创建或打开 Topic 后，历史 store 用键集游标读取消息，随后把消息窗口渲染为列表；写入、删除和流终结均回到 SQLite。

## 1. 会话、消息与分支数据模型

Topic 保存 owner ID/type、名称、创建时间、锁定、未读及消息计数；创建时按 owner 类型生成 `topic_` 或 `group_topic_` 前缀的时间型 ID，见 `src-tauri/src/vcp_modules/chat/topic_service.rs:148-188`。前端保存 `currentSelectedItem`、`currentTopicId` 与每个 owner 的最后活动 Topic；其中前两者和映射使用 Pinia 持久化，见 `src/core/stores/chatSessionStore.ts:230-252`。

`ChatMessage` 是线性记录，包含 role、正文、名称、时间、Agent/Group 归属、附件、完成原因、预渲染 blocks 与展示 shell；流式临时字段只存在内存类型中，见 `src/core/types/chat.ts:88-157`。助手流启动时会先写入空 pending 消息和相应活动记录，终结后才改写内容及完成原因，因此崩溃恢复有可寻址的持久化锚点。

## 2. 事实源、索引与持久化

本地 SQLite 的 `topics` 与 `messages` 是会话和正文事实源。历史查询先验证 Topic 确属请求 owner，再 LEFT JOIN `render_cache`，按 `(timestamp, msg_id)` 倒序取页；前端收到后再升序显示，见 `src-tauri/src/vcp_modules/chat/message_service.rs:282-361` 与 `src/core/stores/chatHistoryStore.ts:23-40`。

渲染缓存、附件关联表、FTS 表与 `active_generations` 是派生或辅助事实：终结事务会更新缓存与 FTS、删除活动行；删除或截断同步清理这些关联数据，见 `src-tauri/src/vcp_modules/chat/message_service.rs:1060-1171, 1210-1289, 1450-1530`。这表明渲染块可重建，但可恢复生成依赖活动记录尚在。

## 3. 创建、切换、删除与恢复

Topic 列表按创建时间倒序读取，创建、改名、锁定、未读标记和删除均有 Tauri 命令。前端加载话题列表时按 owner 与加载代次过滤 Channel 回包，避免 A-B-A 切换的旧结果写入，见 `src/core/stores/topicListManager.ts:95-168`。当前范围内未找到置顶、归档或回收站语义。

删除 Topic 会删除其历史；删除单条消息为软删除并清理其渲染、附件和索引投影。编辑用户消息或重新生成助手消息并不生成分支，而是从指定时间截断后续记录，再把保留的用户消息作为下一轮起点，见 `src/core/stores/chatHistoryStore.ts:407-515, 538-643`。

## 4. 列表、分页、搜索与定位

首次进入仅加载最新 5 条，向上翻页每次取 10 条，前端最多保留 500 条；加载旧页后按 ID 去重并排序，若窗口为保留旧页而逐出最新端，则需显式回到最新端重载，见 `src/core/stores/chatHistoryStore.ts:21-40, 292-326`。后端已维护 FTS 索引，但本次在聊天工作台中只确认到 Topic 名称和日期过滤，未找到把消息 FTS 查询接入 Chat UI 的入口。

## 5. 一致性、恢复与外部绑定

前端先乐观插入用户消息，随后在异步命令前冻结 `ConversationKey`；返回后仅在 key 仍有效时落入当前窗口。历史重新加载会以活动流对象替换同 ID 的数据库骨架，避免正在生成的内容被旧快照覆盖，见 `src/core/stores/chatHistoryStore.ts:180-255`。

启动恢复会扫描本地活动生成记录，先向当前话题注入“重连中”对象，再由 Rust 查询磁盘缓存或 Android helper 续接；恢复结果仍经正常终结事务收口，见 `src/core/stores/chatStreamStore.ts:664-904`。Agent/Group 在 Topic 级绑定，消息上保留实际发言 Agent ID 与附件快照；模型与规则来自执行时 Agent 配置，本笔记未确认其是否另行快照。

## 设计取舍与已确认边界

设计以线性可截断历史和本地恢复为中心，代价是没有发现聊天树、助手版本切换、跨 Topic 全文搜索表面或会话归档工作流。SQLite WAL、同步合并和多设备冲突虽与数据一致性有关，但不在本次 Chat 范围内展开。

## 未验证事项

未通过真实数据验证 500 条窗口后的阅读体验、FTS 搜索命令的调用方、异常退出后 helper 仍存活时的续流，以及多端同时编辑的最终合并结果。

## 关键源码索引

- `src/core/stores/chatSessionStore.ts:25-68, 174-252`
- `src/core/stores/topicListManager.ts:95-305`
- `src-tauri/src/vcp_modules/chat/topic_service.rs:61-188`
- `src-tauri/src/vcp_modules/chat/message_service.rs:282-361, 1060-1289, 1450-1530`
- `src/core/stores/chatHistoryStore.ts:180-326, 407-643`

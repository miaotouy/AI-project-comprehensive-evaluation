# VCPMobile 会话与消息管理调查笔记

> 调查对象：`VCPMobile`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`5fa2eb09e4f4dfab299cbb609a8b904b3485b5a5`（分支：`main`）
>
> 调查方式：静态阅读 Pinia store、Tauri 命令、SQLite 查询/事务与相关测试
>
> 调查范围：Topic、消息、附件、索引、渲染缓存与活动生成的本地生命周期；不展开远端同步协议
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 的会话单位是归属于 Agent 或 Group 的 Topic，而非通用的消息树。Topic 和消息都以 SQLite 为权威源，Pinia 仅保存当前选择、分页窗口和本地 UI 投影。消息按时间戳和 ID 线性排序；编辑或重新生成通过截断后续历史实现，没有发现分支版本或活动路径字段。

## 系统边界与数据主链

选择 owner 或 Topic 先向 Rust 注册导航意图，再由后端读取同一 SQLite 快照确认目标。后端与语音通话共享准入锁，提交时复核页面代次、导航序号和删除范围，获准后发布焦点及窗口版本。前端只原子接受更新的焦点投影；跨会话 epoch 保护仍保留，但选择权威已在 Rust。见 [导航提交](../../VCPMobile/src-tauri/src/vcp_modules/chat/chat_navigation.rs#L190-L220)、[前端投影](../../VCPMobile/src/core/stores/chatSessionStore.ts#L126-L204)。

冷启动持久化的是最近 owner/Topic 的提示和各 owner 最近 Topic 映射。WebView 重载可重新接入进程中的权威焦点及有界窗口成员；进程重启则验证冷提示，失效目标回退到 owner 或欢迎页。前端提示本身不能绕过通话或删除仲裁。见 [恢复路径](../../VCPMobile/src-tauri/src/vcp_modules/chat/chat_navigation.rs#L224-L280)、[偏好序列化](../../VCPMobile/src/core/stores/chatSessionStore.ts#L266-L299)。

## 1. 会话、消息与分支数据模型

Topic 保存 owner ID/type、名称、创建时间、锁定、未读及消息计数；创建时按 owner 类型生成 `topic_` 或 `group_topic_` 前缀的时间型 ID，见 `src-tauri/src/vcp_modules/chat/topic_service.rs:195-246`。当前 owner、Topic 和窗口是 Rust 焦点的前端投影，浏览器持久化保存冷启动提示及每个 owner 的最后活动 Topic 映射，见 [会话状态](../../VCPMobile/src/core/stores/chatSessionStore.ts#L40-L75)。

`ChatMessage` 是线性记录，包含 role、正文、名称、时间、Agent/Group 归属、附件、完成原因、预渲染 blocks 与展示 shell；流式临时字段只存在内存类型中，见 `src/core/types/chat.ts:193-486`。助手流启动时会先写入空 pending 消息和相应活动记录，终结后才改写内容及完成原因，因此崩溃恢复有可寻址的持久化锚点。

## 2. 事实源、索引与持久化

本地 SQLite 的 `topics` 与 `messages` 是会话和正文事实源。历史查询先验证 Topic 确属请求 owner，再 LEFT JOIN `render_cache`，按 `(timestamp, msg_id)` 倒序取页；前端收到后再升序显示，见 `src-tauri/src/vcp_modules/chat/message_service.rs:69-195` 与 `src/core/stores/chatHistoryStore.ts:1-120,120-350`。

渲染缓存、附件关联表、FTS 表与 `active_generations` 是派生或辅助事实：终结事务会更新缓存与 FTS、删除活动行；删除或截断同步清理这些关联数据，见 `src-tauri/src/vcp_modules/chat/message_service.rs:923-1560,1692-1860`。这表明渲染块可重建，但可恢复生成依赖活动记录尚在；写库操作另有队列串行化，避免并发事务互相阻塞。

## 3. 创建、切换、删除与恢复

Topic 列表按创建时间倒序读取，创建、改名、锁定、未读标记、置顶和删除均有 Tauri 命令。前端加载话题列表时按 owner 与加载代次过滤 Channel 回包，避免 A-B-A 切换的旧结果写入，见 `src/core/stores/topicListManager.ts:62-260`。置顶是前端偏好而非服务端字段；当前范围内未找到归档或回收站语义。

删除 Topic 会删除其历史；删除单条消息为软删除并清理其渲染、附件和索引投影。编辑用户消息或重新生成助手消息时，会从指定时间截断后续记录，再把保留的用户消息作为下一轮起点，会话历史保持单条链，见 `src/core/stores/chatHistoryStore.ts:390-530,685-760`。

## 4. 列表、分页、搜索与定位

默认首次加载最新 5 条，向上每页取 10 条，窗口容量为 500 条。搜索锚点另取目标及前 12、后 8 条。Rust 保留窗口成员身份，在同一 SQLite 快照读取成员、删除状态、渲染和附件；前端依据内容 hash、完成原因与更新时间接收必要差量。上翻或定位后的固定窗口保留阅读区，新回复只提示存在更新；显式返回最新端才重新接受尾部。见 [前端窗口读取](../../VCPMobile/src/core/stores/chatWindow.ts#L90-L204)、[Rust 成员与锚点投影](../../VCPMobile/src-tauri/src/vcp_modules/chat/chat_window.rs#L285-L378)。

全局搜索页通过本地 `search_messages_fts` 跨 Topic 检索，支持 owner/Topic、发言 Agent、角色和时间过滤。至少两字才执行，长词走 trigram FTS，双字等短词走参数化子串匹配；时间排序使用完整消息身份游标分页，相关度排序不提供游标翻页。结果点击经导航仲裁确认目标消息仍存在，再打开锚点窗口。见 [搜索 Store](../../VCPMobile/src/features/globalsearch/globalSearchStore.ts#L101-L190)、[SQLite 查询](../../VCPMobile/src-tauri/src/vcp_modules/persistence/db_manager.rs#L854-L982)、[跳转入口](../../VCPMobile/src/features/globalsearch/GlobalSearchView.vue#L277-L301)。

## 5. 一致性、恢复与外部绑定

前端先乐观插入用户消息，随后在异步命令前冻结 `ConversationKey`；返回后仅在 key 仍有效时落入当前窗口。历史重新加载会以活动流对象替换同 ID 的数据库骨架，避免正在生成的内容被旧快照覆盖，见 `src/core/stores/chatHistoryStore.ts:120-260`。

启动恢复会扫描本地活动生成记录，先向当前话题注入“重连中”对象，再由 Rust 查询磁盘缓存、离线完成文件或 Android helper 续接；恢复结果仍经正常终结事务收口，见 `src/core/stores/chatStreamStore.ts:1600-1750` 与 `src-tauri/src/vcp_modules/infra/vcp_client.rs:3544-3600`。Agent/Group 在 Topic 级绑定，消息上保留实际发言 Agent ID 与附件快照；模型与规则来自执行时 Agent 配置，本笔记未确认其是否另行快照。

## 设计取舍与已确认边界

设计以线性可截断历史、本地全文搜索和有界阅读窗口恢复为中心；检查消息模型、菜单与 Topic 管理后，本次未找到聊天树、助手版本切换或会话归档工作流。SQLite WAL、同步合并和多设备冲突虽与数据一致性有关，但不在本次 Chat 范围内展开。

## 未验证事项

未通过真实数据验证 500 条窗口后的阅读体验、搜索相关度与跳转滚动效果、异常退出后 helper 仍存活时的续流、离线完成文件的补交顺序，以及多端同时编辑的最终合并结果。

## 关键源码索引

- `src/core/stores/chatSessionStore.ts:15-120,128-260`
- `src/core/stores/topicListManager.ts:62-260`
- `src-tauri/src/vcp_modules/chat/topic_service.rs:137-246,772-800`
- `src-tauri/src/vcp_modules/chat/message_service.rs:69-195,923-1560,1692-1860`
- `src/core/stores/chatHistoryStore.ts:1-120,120-390,685-760`
